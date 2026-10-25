import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import YaosnapCore

/// P1 验收 harness。编译真实 SnipController / OverlayView 源码，
/// 用真实通知链路驱动 start / 拖拽 / 按键 / 复制 / 保存，并截图留证。
@MainActor
final class ObserverWiring {
    let controller = SnipController()
    /// 记录通知是否真的被接线，防止 AppDelegate 与 harness 同时漏注册同一类事件。
    private(set) var textRecognizeRequests = 0
    private(set) var barcodeScanRequests = 0

    init() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(escape(_:)), name: .snipEscapePressed, object: nil)
        center.addObserver(self, selector: #selector(committed(_:)), name: .snipCommitted, object: nil)
        center.addObserver(self, selector: #selector(copyRequested(_:)), name: .snipCopyRequested, object: nil)
        center.addObserver(self, selector: #selector(saveRequested(_:)), name: .snipSaveRequested, object: nil)
        center.addObserver(
            self, selector: #selector(textRecognizeRequested(_:)), name: .snipTextRecognizeRequested, object: nil)
        center.addObserver(
            self, selector: #selector(barcodeScanRequested(_:)), name: .snipBarcodeScanRequested, object: nil)
    }

    @objc private func escape(_ notification: Notification) { controller.cancel() }
    @objc private func committed(_ notification: Notification) { controller.commitSelection(notification) }
    @objc private func copyRequested(_ notification: Notification) { controller.copyPendingImage(notification) }
    @objc private func saveRequested(_ notification: Notification) { controller.savePendingImage(notification) }
    @objc private func textRecognizeRequested(_ notification: Notification) { textRecognizeRequests += 1 }
    @objc private func barcodeScanRequested(_ notification: Notification) { barcodeScanRequests += 1 }
}

@MainActor
final class Harness {
    private let wiring = ObserverWiring()
    private var controller: SnipController { wiring.controller }
    private let evidenceDir: URL
    private var passes = 0
    private var failures = 0

    init(evidenceDir: URL) {
        self.evidenceDir = evidenceDir
    }

    // MARK: - 记录

    private func pass(_ id: String, _ detail: String) {
        passes += 1
        print("PASS \(id) \(detail)")
    }

    private func fail(_ id: String, _ detail: String) {
        failures += 1
        print("FAIL \(id) \(detail)")
    }

    private func info(_ id: String, _ detail: String) {
        print("INFO \(id) \(detail)")
    }

    // MARK: - 基础工具

    private func pump(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private var overlayWindows: [SnipOverlayWindow] {
        NSApp.windows.compactMap { $0 as? SnipOverlayWindow }
    }

    private var visibleOverlayWindows: [SnipOverlayWindow] {
        overlayWindows.filter(\.isVisible)
    }

    private func beginSession(_ id: String) -> (SnipOverlayWindow, OverlayView)? {
        controller.start()
        pump(0.4)
        guard let window = visibleOverlayWindows.first,
              let view = window.contentView as? OverlayView else {
            fail(id, "start 后没有可见覆盖窗口")
            return nil
        }
        return (window, view)
    }

    private func endSession() {
        controller.cancel()
        NSPasteboard.general.clearContents()
        pump(0.15)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        in window: NSWindow,
        clickCount: Int = 1
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: type == .leftMouseUp ? 0 : 1
        )
    }

    private func drag(_ view: OverlayView, window: NSWindow, from: CGPoint, to: CGPoint) {
        guard let down = mouseEvent(.leftMouseDown, at: from, in: window),
              let dragged = mouseEvent(.leftMouseDragged, at: to, in: window),
              let up = mouseEvent(.leftMouseUp, at: to, in: window) else {
            fail("DRAG", "无法构造鼠标事件")
            return
        }
        view.mouseDown(with: down)
        view.mouseDragged(with: dragged)
        view.mouseUp(with: up)
        pump(0.2)
    }

    private func keyDown(
        _ keyCode: UInt16,
        characters: String,
        flags: NSEvent.ModifierFlags = [],
        in window: NSWindow,
        view: OverlayView
    ) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fail("KEY", "无法构造键盘事件 keyCode=\(keyCode)")
            return
        }
        view.keyDown(with: event)
        pump(0.25)
    }

    private func pasteboardImage() -> CGImage? {
        guard let tiff = NSPasteboard.general.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.cgImage
    }

    /// 期望裁剪：直接从冻结帧按像素矩形裁一块，不复用 ImageOutput，避免自证。
    private func expectedCrop(from shot: DisplayShot, imageRect: CGRect) -> CGImage? {
        let integral = imageRect.integral.intersection(
            CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height)
        )
        guard !integral.isNull, integral.width >= 1, integral.height >= 1 else { return nil }
        return shot.image.cropping(to: integral)
    }

    /// 把图像画进 sRGB RGBA8 缓冲区，统一色彩空间后再比较。
    private func srgbBytes(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = context.data else { return nil }
        return Array(UnsafeBufferPointer(
            start: base.assumingMemoryBound(to: UInt8.self),
            count: width * height * 4
        ))
    }

    /// 与冻结帧裁剪逐像素比对。阈值：通道均差 <= 2，单通道差 > 8 的像素占比 <= 0.5%。
    private func verifyClipboardPixels(_ id: String, expected: CGImage?) {
        guard let expected else {
            fail(id, "无法从冻结帧生成期望裁剪")
            return
        }
        guard let actual = pasteboardImage() else {
            fail(id, "剪贴板没有可读取的图像")
            return
        }
        guard actual.width == expected.width, actual.height == expected.height else {
            fail(id, "剪贴板 \(actual.width)x\(actual.height) 期望 \(expected.width)x\(expected.height)")
            return
        }
        guard let a = srgbBytes(actual, width: expected.width, height: expected.height),
              let e = srgbBytes(expected, width: expected.width, height: expected.height) else {
            fail(id, "像素读取失败")
            return
        }
        let pixelCount = expected.width * expected.height
        var totalDiff = 0
        var maxDiff = 0
        var mismatchedPixels = 0
        for pixel in 0..<pixelCount {
            let offset = pixel * 4
            var mismatch = false
            for channel in 0..<4 {
                let diff = abs(Int(a[offset + channel]) - Int(e[offset + channel]))
                totalDiff += diff
                if diff > maxDiff { maxDiff = diff }
                if diff > 8 { mismatch = true }
            }
            if mismatch { mismatchedPixels += 1 }
        }
        let mean = Double(totalDiff) / Double(pixelCount * 4)
        let ratio = Double(mismatchedPixels) / Double(pixelCount)
        let detail = String(
            format: "尺寸 %dx%d，通道均差 %.2f，最大差 %d，超阈值像素 %.3f%%",
            actual.width, actual.height, mean, maxDiff, ratio * 100
        )
        if mean <= 2.0, ratio <= 0.005 {
            pass(id, "与冻结帧裁剪逐像素一致（\(detail)）")
        } else {
            fail(id, "像素不一致（\(detail)）")
        }
    }

    private func capture(_ name: String) -> CGImage? {
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
            info("CAPTURE", "CGDisplayCreateImage 返回 nil: \(name)")
            return nil
        }
        let url = evidenceDir.appendingPathComponent(name)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return image }
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) {
            try? (data as Data).write(to: url)
            info("CAPTURE", "\(name) -> \(url.path) \(image.width)x\(image.height)")
        }
        return image
    }

    /// 全屏平均亮度（0...1）。用于证明覆盖层消失：遮罩会把画面压暗。
    private func averageLuminance(_ image: CGImage) -> Double {
        let rep = NSBitmapImageRep(cgImage: image)
        let steps = 24
        var total = 0.0
        var count = 0.0
        for i in 0..<steps {
            for j in 0..<steps {
                let x = rep.pixelsWide * (i * 2 + 1) / (steps * 2)
                let y = rep.pixelsHigh * (j * 2 + 1) / (steps * 2)
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 0.2126 * Double(color.redComponent)
                    + 0.7152 * Double(color.greenComponent)
                    + 0.0722 * Double(color.blueComponent)
                count += 1
            }
        }
        return count > 0 ? total / count : 0
    }

    // MARK: - 性能基准

    func runPerformance() {
        var samples: [Double] = []
        for run in 1...5 {
            let t0 = CFAbsoluteTimeGetCurrent()
            controller.start()
            let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            samples.append(elapsed)
            print(String(format: "[perf] hotkey→overlay: %.1f ms (run %d)", elapsed, run))
            pump(0.25)
            if run == 1 {
                _ = capture("01-overlay-fullscreen.png")
            }
            if visibleOverlayWindows.count != 1 {
                fail("PERF", "第 \(run) 次 start 后可见覆盖窗口数=\(visibleOverlayWindows.count)，期望 1")
            }
            controller.cancel()
            pump(0.12)
            if !visibleOverlayWindows.isEmpty {
                fail("PERF", "第 \(run) 次 cancel 后仍有可见覆盖窗口")
            }
        }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let minValue = samples.min() ?? 0
        let maxValue = samples.max() ?? 0
        let detail = String(
            format: "runs=[%@] mean=%.1fms min=%.1fms max=%.1fms 目标<100ms",
            samples.map { String(format: "%.1f", $0) }.joined(separator: ", "),
            mean, minValue, maxValue
        )
        if mean < 100 {
            pass("PERF", detail)
        } else {
            fail("PERF", detail)
        }
    }

    // MARK: - 覆盖层全屏

    func runOverlayCoverage() {
        guard let (window, view) = beginSession("OVERLAY") else { return }
        let screenFrame = NSScreen.screens.first?.frame ?? .zero
        if window.frame == screenFrame, view.bounds.size == screenFrame.size {
            pass("OVERLAY", "覆盖窗口 frame=\(window.frame) 与屏幕一致，冻结图 \(view.shot.image.width)x\(view.shot.image.height)")
        } else {
            fail("OVERLAY", "窗口 frame=\(window.frame) 屏幕=\(screenFrame) 视图=\(view.bounds)")
        }
        _ = capture("02-overlay-session.png")
        keyDown(53, characters: "\u{1b}", in: window, view: view)
        if visibleOverlayWindows.isEmpty {
            pass("OVERLAY-ESC", "Esc 后可见覆盖窗口为 0")
        } else {
            fail("OVERLAY-ESC", "Esc 后仍有 \(visibleOverlayWindows.count) 个可见覆盖窗口")
        }
    }

    // MARK: - 拖拽选区 + Enter 复制

    func runForwardDragCopy() {
        guard let (window, view) = beginSession("DRAG-FWD") else { return }
        drag(view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 300))
        let rect = view.selectionRect
        if abs(rect.origin.x - 100) <= 1, abs(rect.origin.y - 100) <= 1,
           abs(rect.width - 300) <= 1, abs(rect.height - 200) <= 1 {
            pass("DRAG-FWD", "selectionRect=\(rect) 符合 100,100 300x200")
        } else {
            fail("DRAG-FWD", "selectionRect=\(rect) 期望 100,100 300x200")
        }
        _ = capture("03-drag-forward-label.png")

        let imageRect = RectMath.imageRect(
            fromViewRect: rect, viewHeight: view.bounds.height, scale: view.shot.scale
        )
        let expected = expectedCrop(from: view.shot, imageRect: imageRect)
        NSPasteboard.general.clearContents()
        keyDown(36, characters: "\r", in: window, view: view)
        verifyClipboardPixels("COPY-ENTER", expected: expected)
        let pastedSize = NSImage(pasteboard: NSPasteboard.general)?.size
        if let pastedSize, abs(pastedSize.width - rect.width) <= 1, abs(pastedSize.height - rect.height) <= 1 {
            pass("COPY-POINT-SIZE", "剪贴板图像点尺寸 \(pastedSize) 与选区 \(rect.size) 一致")
        } else {
            fail("COPY-POINT-SIZE", "剪贴板图像点尺寸 \(String(describing: pastedSize)) 期望 \(rect.size)")
        }
        if visibleOverlayWindows.isEmpty {
            pass("COPY-ENTER-CLOSE", "复制后覆盖层全部消失")
        } else {
            fail("COPY-ENTER-CLOSE", "复制后仍有 \(visibleOverlayWindows.count) 个可见覆盖窗口")
        }
        endSession()
    }

    // MARK: - 反向拖拽 + 双击复制

    func runReverseDragDoubleClickCopy() {
        guard let (window, view) = beginSession("DRAG-REV") else { return }
        drag(view, window: window, from: CGPoint(x: 400, y: 300), to: CGPoint(x: 100, y: 100))
        let rect = view.selectionRect
        if abs(rect.origin.x - 100) <= 1, abs(rect.origin.y - 100) <= 1,
           abs(rect.width - 300) <= 1, abs(rect.height - 200) <= 1 {
            pass("DRAG-REV", "反向拖拽归一化 selectionRect=\(rect)")
        } else {
            fail("DRAG-REV", "反向拖拽 selectionRect=\(rect) 期望 100,100 300x200")
        }

        let imageRect = RectMath.imageRect(
            fromViewRect: rect, viewHeight: view.bounds.height, scale: view.shot.scale
        )
        let expected = expectedCrop(from: view.shot, imageRect: imageRect)
        NSPasteboard.general.clearContents()
        if let doubleClick = mouseEvent(.leftMouseDown, at: CGPoint(x: 200, y: 200), in: window, clickCount: 2) {
            view.mouseDown(with: doubleClick)
            pump(0.25)
        } else {
            fail("COPY-DBLCLICK", "无法构造双击事件")
        }
        verifyClipboardPixels("COPY-DBLCLICK", expected: expected)
        if visibleOverlayWindows.isEmpty {
            pass("COPY-DBLCLICK-CLOSE", "双击复制后覆盖层全部消失")
        } else {
            fail("COPY-DBLCLICK-CLOSE", "双击复制后仍有可见覆盖窗口")
        }
        endSession()
    }

    // MARK: - 窗口悬停与吸附

    func runWindowSnap() {
        let all = WindowDetector.onScreenWindows(ownPID: getpid())
        let candidates = WindowDetector.snapCandidates(from: all, ownPID: getpid())
        guard let target = candidates.first else {
            fail("SNAP", "屏幕上没有可吸附窗口")
            return
        }
        // 选一个只被最顶层窗口覆盖的点，确保 hover 命中预期窗口。
        let probe = CGPoint(x: target.bounds.minX + 200, y: target.bounds.minY + 700)
        guard let hit = WindowDetector.window(at: probe, in: candidates), hit == target else {
            fail("SNAP", "探测点 \(probe) 命中的窗口不是预期窗口 \(target.ownerName)")
            return
        }

        guard let (window, view) = beginSession("SNAP") else { return }
        let viewPoint = CGPoint(
            x: probe.x - view.shot.bounds.minX,
            y: view.bounds.height - (probe.y - view.shot.bounds.minY)
        )
        if let move = mouseEvent(.mouseMoved, at: viewPoint, in: window) {
            view.mouseMoved(with: move)
            pump(0.3)
        }
        _ = capture("04-window-hover.png")

        let expectedViewRect = RectMath.clamp(
            RectMath.toViewRect(
                globalRect: target.bounds,
                displayBounds: view.shot.bounds,
                viewHeight: view.bounds.height
            ),
            to: view.bounds
        )
        if let down = mouseEvent(.leftMouseDown, at: viewPoint, in: window) {
            view.mouseDown(with: down)
            pump(0.25)
        }
        let snapped = view.selectionRect
        if abs(snapped.minX - expectedViewRect.minX) <= 1,
           abs(snapped.minY - expectedViewRect.minY) <= 1,
           abs(snapped.width - expectedViewRect.width) <= 1,
           abs(snapped.height - expectedViewRect.height) <= 1 {
            pass("SNAP", "点击窗口后吸附 selectionRect=\(snapped) 与窗口 \(target.ownerName) \(target.bounds) 一致")
        } else {
            fail("SNAP", "吸附 selectionRect=\(snapped) 期望 \(expectedViewRect)（\(target.ownerName)）")
        }
        _ = capture("05-window-snap-label.png")

        if let up = mouseEvent(.leftMouseUp, at: viewPoint, in: window) {
            view.mouseUp(with: up)
            pump(0.15)
        }
        let imageRect = RectMath.imageRect(
            fromViewRect: snapped, viewHeight: view.bounds.height, scale: view.shot.scale
        )
        let expected = expectedCrop(from: view.shot, imageRect: imageRect)
        NSPasteboard.general.clearContents()
        keyDown(36, characters: "\r", in: window, view: view)
        verifyClipboardPixels("SNAP-COPY", expected: expected)
        endSession()
    }

    // MARK: - ⌘S 保存

    func runSave() {
        guard let (window, view) = beginSession("SAVE") else { return }
        drag(view, window: window, from: CGPoint(x: 200, y: 150), to: CGPoint(x: 500, y: 350))

        keyDown(1, characters: "s", flags: .command, in: window, view: view)
        pump(0.8)

        var panel = visibleOverlayWindows.compactMap { $0.attachedSheet as? NSSavePanel }.first
        if panel == nil {
            panel = NSApp.windows.compactMap { $0 as? NSSavePanel }.first
        }
        guard let panel else {
            fail("SAVE", "⌘S 后没有出现保存面板")
            endSession()
            return
        }
        let defaultName = panel.nameFieldStringValue
        let namePattern = try! NSRegularExpression(pattern: #"^Yaosnap_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.png$"#)
        let nameRange = NSRange(defaultName.startIndex..., in: defaultName)
        if namePattern.firstMatch(in: defaultName, range: nameRange) != nil {
            pass("SAVE-DEFAULTNAME", "默认文件名 \(defaultName) 符合命名规则")
        } else {
            fail("SAVE-DEFAULTNAME", "默认文件名 \(defaultName) 不符合 Yaosnap_yyyy-MM-dd_HH-mm-ss.png")
        }

        // 面板显示后改 directoryURL / nameFieldStringValue 会被忽略（实测），
        // 直接验证生产代码给的默认落点（桌面 + Yaosnap_时间戳.png）。
        let predictedURL = panel.url
        let existedBefore = predictedURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        info("SAVE-PREDICTED", "panel.url=\(predictedURL?.path ?? "nil") existedBefore=\(existedBefore)")
        if let parent = visibleOverlayWindows.first {
            parent.endSheet(panel, returnCode: .OK)
        } else {
            fail("SAVE", "找不到保存面板的父窗口")
        }
        pump(1.0)

        guard let savedURL = panel.url,
              FileManager.default.fileExists(atPath: savedURL.path) else {
            fail("SAVE", "endSheet 后文件不存在: \(panel.url?.path ?? "url=nil")")
            endSession()
            return
        }
        info("SAVE-URL-AFTER", "panel.url=\(savedURL.path)")
        let imageRect = RectMath.imageRect(
            fromViewRect: view.selectionRect, viewHeight: view.bounds.height, scale: view.shot.scale
        )
        if let source = CGImageSourceCreateWithURL(savedURL as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            if image.width == Int(imageRect.width), image.height == Int(imageRect.height) {
                pass("SAVE", "\(savedURL.lastPathComponent) \(image.width)x\(image.height) 与选区裁剪一致，写入 \(savedURL.path)")
            } else {
                fail("SAVE", "文件 \(image.width)x\(image.height) 期望 \(Int(imageRect.width))x\(Int(imageRect.height))")
            }
        } else {
            fail("SAVE", "无法读取保存的 PNG: \(savedURL.path)")
        }
        let evidenceCopy = evidenceDir.appendingPathComponent("P1-save-verify.png")
        try? FileManager.default.removeItem(at: evidenceCopy)
        try? FileManager.default.copyItem(at: savedURL, to: evidenceCopy)
        if !existedBefore {
            try? FileManager.default.removeItem(at: savedURL)
        }
        if visibleOverlayWindows.isEmpty {
            pass("SAVE-CLOSE", "保存成功后覆盖层全部消失")
        } else {
            fail("SAVE-CLOSE", "保存成功后仍有可见覆盖窗口")
        }
        endSession()
    }

    // MARK: - Esc 取消 + 光标

    func runEscape() {
        guard let (window, view) = beginSession("ESC") else { return }
        let duringCursor = NSCursor.current
        if duringCursor === NSCursor.crosshair, view.showsCrosshair {
            pass("CURSOR", "会话中为十字光标且 cursor rect 生效（不再隐藏光标）")
        } else {
            fail("CURSOR", "会话中 cursor=\(duringCursor) showsCrosshair=\(view.showsCrosshair)")
        }
        guard let during = capture("06-before-esc.png") else {
            fail("ESC", "截图失败")
            endSession()
            return
        }
        let duringLuminance = averageLuminance(during)

        keyDown(53, characters: "\u{1b}", in: window, view: view)
        pump(0.3)
        let afterCursor = NSCursor.current
        if afterCursor === NSCursor.arrow, !view.showsCrosshair {
            pass("CURSOR-RESTORE", "取消后恢复箭头光标")
        } else {
            fail("CURSOR-RESTORE", "取消后 cursor=\(afterCursor) showsCrosshair=\(view.showsCrosshair)")
        }
        guard let after = capture("07-after-esc.png") else {
            fail("ESC", "取消后截图失败")
            endSession()
            return
        }
        let afterLuminance = averageLuminance(after)

        if visibleOverlayWindows.isEmpty {
            pass("ESC", "Esc 后可见覆盖窗口为 0")
        } else {
            fail("ESC", "Esc 后仍有 \(visibleOverlayWindows.count) 个可见覆盖窗口")
        }
        if afterLuminance - duringLuminance > 0.03 {
            pass(
                "ESC-VISUAL",
                String(format: "取消后全屏亮度 %.3f > 取消中 %.3f，遮罩确已消失", afterLuminance, duringLuminance)
            )
        } else {
            fail(
                "ESC-VISUAL",
                String(format: "亮度差不足: during=%.3f after=%.3f", duringLuminance, afterLuminance)
            )
        }
        endSession()
    }

    // MARK: - P2：选区操作工具条

    func runActionBar() {
        guard let (window, view) = beginSession("ACTIONBAR") else { return }
        guard let bar = view.subviews.compactMap({ $0 as? AnnotateToolbar }).first else {
            fail("ACTIONBAR", "覆盖视图里没有 AnnotateToolbar")
            endSession()
            return
        }
        if bar.isHidden {
            pass("ACTIONBAR-IDLE", "未选区时工具条隐藏")
        } else {
            fail("ACTIONBAR-IDLE", "未选区时工具条应隐藏")
        }

        // 选区要宽过 450pt 工具条，右对齐才不被屏幕边界钳制
        drag(view, window: window, from: CGPoint(x: 50, y: 150), to: CGPoint(x: 980, y: 700))
        let rect = view.selectionRect
        if !bar.isHidden {
            pass("ACTIONBAR-SHOW", "选区确定后工具条显示 frame=\(bar.frame)")
        } else {
            fail("ACTIONBAR-SHOW", "选区确定后工具条仍隐藏")
        }
        let expectedY = rect.minY - bar.frame.height - 6
        if abs(bar.frame.minY - expectedY) <= 1, abs(bar.frame.maxX - rect.maxX) <= 1 {
            pass("ACTIONBAR-POS", "工具条贴在选区右下角外侧")
        } else {
            fail("ACTIONBAR-POS", "工具条 frame=\(bar.frame) 期望右下角外侧 y=\(expectedY) maxX=\(rect.maxX)")
        }
        _ = capture("09-actionbar.png")

        let buttons = bar.subviews.compactMap { $0 as? NSButton }
        // 按内容推导：选择 + 形状目录 + 颜色/笔尖/线型 + 输出动作，不写死总数。
        let expectedTitles = ["选择"]
            + ShapeCatalog.p2.map(\.title)
            + ["颜色", "笔尖", "线型", "背景", "箭头", "复制", "提取文字", "识别码", "保存", "分享", "取消"]
        let actualTitles = buttons.compactMap(\.toolTip)
        guard actualTitles.count == expectedTitles.count,
              Set(actualTitles) == Set(expectedTitles) else {
            let missing = Set(expectedTitles).subtracting(actualTitles).sorted()
            let extra = Set(actualTitles).subtracting(expectedTitles).sorted()
            fail("ACTIONBAR-BUTTONS", "按钮内容不符 缺=\(missing) 多=\(extra)")
            endSession()
            return
        }
        let imageRect = RectMath.imageRect(
            fromViewRect: rect, viewHeight: view.bounds.height, scale: view.shot.scale
        )
        let expected = expectedCrop(from: view.shot, imageRect: imageRect)
        NSPasteboard.general.clearContents()
        guard let copyButton = buttons.first(where: { $0.toolTip == "复制" }) else {
            fail("ACTIONBAR-COPY", "工具条上找不到复制按钮")
            endSession()
            return
        }
        copyButton.performClick(nil)
        pump(0.3)
        verifyClipboardPixels("ACTIONBAR-COPY", expected: expected)
        if visibleOverlayWindows.isEmpty {
            pass("ACTIONBAR-COPY-CLOSE", "点击复制按钮后覆盖层消失")
        } else {
            fail("ACTIONBAR-COPY-CLOSE", "点击复制按钮后仍有 \(visibleOverlayWindows.count) 个覆盖窗口")
        }
        endSession()

        // 取消按钮：同一选区上点 ✕ 应直接结束会话
        guard let (window2, view2) = beginSession("ACTIONBAR-X") else { return }
        drag(view2, window: window2, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 500, y: 400))
        guard let bar2 = view2.subviews.compactMap({ $0 as? AnnotateToolbar }).first,
              let cancelButton = bar2.subviews.compactMap({ $0 as? NSButton }).last else {
            fail("ACTIONBAR-X", "找不到取消按钮")
            endSession()
            return
        }
        cancelButton.performClick(nil)
        pump(0.25)
        if visibleOverlayWindows.isEmpty {
            pass("ACTIONBAR-X", "点击取消按钮后覆盖层消失")
        } else {
            fail("ACTIONBAR-X", "点击取消按钮后仍有 \(visibleOverlayWindows.count) 个覆盖窗口")
        }
        endSession()
    }

    // MARK: - P2：遮罩强度与悬停提亮

    /// 单点物理像素亮度（0...1）
    private func luminance(_ image: CGImage, atPhysical point: CGPoint) -> Double? {
        let rep = NSBitmapImageRep(cgImage: image)
        let scaleX = CGFloat(rep.pixelsWide) / CGFloat(image.width)
        let x = Int(point.x * scaleX)
        let y = Int(point.y * scaleX)
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh,
              let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
        return 0.2126 * Double(color.redComponent)
            + 0.7152 * Double(color.greenComponent)
            + 0.0722 * Double(color.blueComponent)
    }

    func runMaskAndHover() {
        guard let (window, view) = beginSession("MASK") else { return }
        guard let live = capture("10-mask-alpha.png") else {
            fail("MASK", "会话中截图失败")
            endSession()
            return
        }
        let frozenLuminance = averageLuminance(view.shot.image)
        let ratio = averageLuminance(live) / max(frozenLuminance, 0.0001)
        // 遮罩 alpha=0.32 → 亮度约为原图 0.68
        if ratio > 0.58, ratio < 0.80 {
            pass("MASK-ALPHA", String(format: "会话亮度比 %.3f，接近 1-0.32", ratio))
        } else {
            fail("MASK-ALPHA", String(format: "会话亮度比 %.3f，期望 0.58~0.80", ratio))
        }

        let all = WindowDetector.onScreenWindows(ownPID: getpid())
        let candidates = WindowDetector.snapCandidates(from: all, ownPID: getpid())
        if let target = candidates.first {
            let probe = CGPoint(x: target.bounds.minX + 200, y: target.bounds.minY + 700)
            if WindowDetector.window(at: probe, in: candidates) == target {
                let viewPoint = CGPoint(
                    x: probe.x - view.shot.bounds.minX,
                    y: view.bounds.height - (probe.y - view.shot.bounds.minY)
                )
                if let move = mouseEvent(.mouseMoved, at: viewPoint, in: window) {
                    view.mouseMoved(with: move)
                    pump(0.25)
                }
                if let hovered = capture("11-window-hover-bright.png"),
                   let hoverLuminance = luminance(hovered, atPhysical: probe),
                   let originalLuminance = luminance(view.shot.image, atPhysical: probe),
                   originalLuminance > 0.02 {
                    let hoverRatio = hoverLuminance / originalLuminance
                    if hoverRatio > 0.9 {
                        pass("HOVER-BRIGHT", String(format: "悬停窗口亮度比 %.3f，遮罩已挖空", hoverRatio))
                    } else {
                        fail("HOVER-BRIGHT", String(format: "悬停窗口亮度比 %.3f，期望 >0.9", hoverRatio))
                    }
                } else {
                    fail("HOVER-BRIGHT", "悬停区域亮度采样失败")
                }
            } else {
                info("HOVER-BRIGHT", "探测点未命中候选窗口，跳过")
            }
        } else {
            info("HOVER-BRIGHT", "屏幕上没有可吸附窗口，跳过")
        }

        keyDown(53, characters: "\u{1b}", in: window, view: view)
        endSession()
    }

    // MARK: - 白板与历史菜单

    func runWhiteboardExport() {
        let wiring = ObserverWiring()
        let board = wiring.controller
        let suite = "yaosnap.p1.whiteboard"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fail("WHITEBOARD-EXPORT", "无法创建测试 UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        var settings = Settings.standard
        settings.whiteboard.enabled = true
        settings.whiteboard.background = .solid(.white)
        board.settingsStore = SettingsStore(defaults: defaults)
        board.settingsStore.save(settings)

        board.start()
        pump(0.4)
        guard let window = visibleOverlayWindows.first,
              let view = window.contentView as? OverlayView else {
            fail("WHITEBOARD-EXPORT", "start 后没有可见覆盖窗口")
            board.cancel()
            return
        }
        drag(view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200))
        NSPasteboard.general.clearContents()
        keyDown(36, characters: "\r", in: window, view: view)

        guard let image = pasteboardImage(),
              let bytes = srgbBytes(image, width: image.width, height: image.height) else {
            fail("WHITEBOARD-EXPORT", "剪贴板没有可读取的图像")
            board.cancel()
            return
        }
        let samples = [
            (0, 0),
            (image.width - 1, 0),
            (0, image.height - 1),
            (image.width - 1, image.height - 1),
            (image.width / 2, image.height / 2),
        ]
        let allWhite = samples.allSatisfy { point in
            let offset = (point.1 * image.width + point.0) * 4
            return abs(Int(bytes[offset]) - 255) <= 2
                && abs(Int(bytes[offset + 1]) - 255) <= 2
                && abs(Int(bytes[offset + 2]) - 255) <= 2
        }
        if allWhite {
            pass("WHITEBOARD-EXPORT", "\(image.width)x\(image.height) 采样点为纯白")
        } else {
            fail("WHITEBOARD-EXPORT", "导出图背景不是纯白")
        }
        if board.historyCount == 1 {
            pass("WHITEBOARD-HISTORY", "白板导出进入同一份历史")
        } else {
            fail("WHITEBOARD-HISTORY", "historyCount=\(board.historyCount)，期望 1")
        }

        board.cancel()
        NSPasteboard.general.clearContents()
        pump(0.15)
    }

    /// 透明白板：窗口透明、底图 alpha 全 0，导出后采样点 alpha 必须全为 0。
    func runTransparentWhiteboardExport() {
        let wiring = ObserverWiring()
        let board = wiring.controller
        let suite = "yaosnap.p1.whiteboard-transparent"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fail("WHITEBOARD-TRANSPARENT", "无法创建测试 UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        board.settingsStore = SettingsStore(defaults: defaults)
        board.startWhiteboard(background: .transparent, activeScreen: false)
        pump(0.4)
        guard let window = visibleOverlayWindows.first,
              let view = window.contentView as? OverlayView else {
            fail("WHITEBOARD-TRANSPARENT", "start 后没有可见覆盖窗口")
            board.cancel()
            return
        }
        guard window.isOpaque == false, window.backgroundColor == .clear else {
            fail("WHITEBOARD-TRANSPARENT", "覆盖窗口未切换为透明")
            board.cancel()
            return
        }
        drag(view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200))
        NSPasteboard.general.clearContents()
        keyDown(36, characters: "\r", in: window, view: view)

        guard let image = pasteboardImage(),
              let bytes = srgbBytes(image, width: image.width, height: image.height) else {
            fail("WHITEBOARD-TRANSPARENT", "剪贴板没有可读取的图像")
            board.cancel()
            return
        }
        let samples = [
            (0, 0),
            (image.width - 1, 0),
            (0, image.height - 1),
            (image.width - 1, image.height - 1),
            (image.width / 2, image.height / 2),
        ]
        let allTransparent = samples.allSatisfy { point in
            let offset = (point.1 * image.width + point.0) * 4
            return bytes[offset + 3] == 0
        }
        if allTransparent {
            pass("WHITEBOARD-TRANSPARENT", "\(image.width)x\(image.height) 四角与中心 alpha 均为 0")
        } else {
            fail("WHITEBOARD-TRANSPARENT", "导出图存在非透明采样点")
        }

        board.cancel()
        NSPasteboard.general.clearContents()
        pump(0.15)
    }

    func runHistoryMenu() {
        let expected = min(controller.historyCount, CaptureHistoryMenu.limit)
        let status = makeStatusController(reading: { self.controller.historySnapshot })
        status.menuNeedsUpdate(status.menu)
        guard let historyItem = status.menu.items.first(where: { $0.title == "截图历史" }),
              let submenu = historyItem.submenu else {
            fail("HISTORY-MENU", "菜单里没有截图历史子菜单")
            return
        }
        if submenu.items.count == expected,
           submenu.items.count == controller.historyCount,
           historyItem.isEnabled == (expected > 0) {
            pass("HISTORY-MENU", "\(submenu.items.count) 条与 historyCount=\(controller.historyCount) 一致")
        } else {
            fail("HISTORY-MENU", "子菜单 \(submenu.items.count) 条，期望 \(expected)，historyCount=\(controller.historyCount)")
        }

        let empty = SnipController()
        let emptyStatus = makeStatusController(reading: { empty.historySnapshot })
        emptyStatus.menuNeedsUpdate(emptyStatus.menu)
        if let item = emptyStatus.menu.items.first(where: { $0.title == "截图历史" }),
           item.submenu?.items.isEmpty == true,
           !item.isEnabled {
            pass("HISTORY-MENU-EMPTY", "历史为空时菜单项禁用")
        } else {
            fail("HISTORY-MENU-EMPTY", "历史为空时菜单项未禁用")
        }

        controller.startReplayingHistory(at: 0)
        pump(0.4)
        guard let window = visibleOverlayWindows.first,
              let view = window.contentView as? OverlayView else {
            fail("HISTORY-REPLAY", "startReplayingHistory 后没有可见覆盖窗口")
            return
        }
        if view.historyIndex == 1 {
            pass("HISTORY-REPLAY", "会话直接停在最新历史 historyIndex=1")
        } else {
            fail("HISTORY-REPLAY", "historyIndex=\(view.historyIndex)，期望 1")
        }
        endSession()
    }

    private func makeStatusController(
        reading history: @escaping @MainActor () -> [CaptureHistoryEntry]
    ) -> StatusItemController {
        StatusItemController(
            onSnip: {},
            onPin: {},
            onTogglePassthrough: {},
            historyItems: {
                CaptureHistoryMenu.items(from: history())
            },
            onReplayHistory: { _ in },
            pinGroupState: {
                PinGroupMenuState(
                    groups: [],
                    activeID: 0,
                    soloActive: false,
                    selectedCount: 0,
                    visibleCount: 0
                )
            },
            onSelectPinGroup: { _ in },
            onCreatePinGroup: { _ in true },
            onRenamePinGroup: { _, _ in true },
            onDeletePinGroup: { _ in true },
            onToggleSolo: {},
            onOpenSettings: {}
        )
    }

    // MARK: - 主流程

    /// 工具条的提取文字与识别码走通知派发，接线漏注册时按钮点击毫无反应。
    /// 这里只验证通知有接收者，识别本身由 TextRecognizer / BarcodeScanner 单测覆盖。
    func runToolbarNotificationWiring() {
        let wiring = ObserverWiring()
        NotificationCenter.default.post(name: .snipTextRecognizeRequested, object: nil)
        NotificationCenter.default.post(name: .snipBarcodeScanRequested, object: nil)
        pump(0.1)
        if wiring.textRecognizeRequests == 1, wiring.barcodeScanRequests == 1 {
            pass("TOOLBAR-WIRING", "提取文字与识别码通知都有接收者")
        } else {
            fail(
                "TOOLBAR-WIRING",
                "通知未被接线 text=\(wiring.textRecognizeRequests) barcode=\(wiring.barcodeScanRequests)")
        }
    }

    func runAll() {
        if !ScreenCaptureService.hasPermission() {
            print("FATAL 屏幕录制权限缺失，无法执行验收")
            exit(2)
        }
        print("INFO ENV permission=true displays=\(NSScreen.screens.count) screen=\(NSScreen.screens.first?.frame ?? .zero)")

        runPerformance()
        runOverlayCoverage()
        runForwardDragCopy()
        runReverseDragDoubleClickCopy()
        runWindowSnap()
        runSave()
        runEscape()
        runActionBar()
        runToolbarNotificationWiring()
        runMaskAndHover()
        runWhiteboardExport()
        runTransparentWhiteboardExport()
        runHistoryMenu()

        print("SUMMARY passes=\(passes) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}

@main
struct P1E2EMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)

            let base = URL(fileURLWithPath: "/tmp/yaosnap-verify", isDirectory: true)
            let evidence = base.appendingPathComponent("evidence", isDirectory: true)
            try? FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)

            let harness = Harness(evidenceDir: evidence)
            harness.runAll()
        }
    }
}
