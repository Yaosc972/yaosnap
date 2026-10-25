import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import YaosnapCore

/// P2 标注第一批验收 harness。驱动真实 SnipController / OverlayView，
/// 验证画矩形 → 复制 → 剪贴板与参考渲染一致、方向正确、状态机行为正确。
@MainActor
final class AnnotateObserverWiring {
    let controller = SnipController()

    init() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(escape(_:)), name: .snipEscapePressed, object: nil)
        center.addObserver(self, selector: #selector(committed(_:)), name: .snipCommitted, object: nil)
        center.addObserver(self, selector: #selector(copyRequested(_:)), name: .snipCopyRequested, object: nil)
        center.addObserver(self, selector: #selector(textRequested(_:)), name: .snipTextRecognizeRequested, object: nil)
        center.addObserver(self, selector: #selector(barcodeRequested(_:)), name: .snipBarcodeScanRequested, object: nil)
        center.addObserver(self, selector: #selector(saveRequested(_:)), name: .snipSaveRequested, object: nil)
    }

    @objc private func escape(_ notification: Notification) { controller.cancel() }
    @objc private func committed(_ notification: Notification) { controller.commitSelection(notification) }
    @objc private func copyRequested(_ notification: Notification) { controller.copyPendingImage(notification) }
    @objc private func textRequested(_ notification: Notification) { controller.recognizeTextPending(notification) }
    @objc private func barcodeRequested(_ notification: Notification) { controller.scanBarcodePending(notification) }
    @objc private func saveRequested(_ notification: Notification) { controller.savePendingImage(notification) }
}

@MainActor
final class AnnotateHarness {
    private let wiring = AnnotateObserverWiring()
    private var controller: SnipController { wiring.controller }
    private let evidenceDir: URL
    private var passes = 0
    private var failures = 0

    init(evidenceDir: URL) {
        self.evidenceDir = evidenceDir
    }

    // MARK: - 基础设施

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

    private func pump(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private var visibleOverlayWindows: [SnipOverlayWindow] {
        NSApp.windows.compactMap { $0 as? SnipOverlayWindow }.filter(\.isVisible)
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
        clickCount: Int = 1,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: type == .leftMouseUp ? 0 : 1
        )
    }

    /// 发送一次完整按压序列。
    private func press(
        _ view: OverlayView,
        window: NSWindow,
        path: [CGPoint],
        modifierFlags: NSEvent.ModifierFlags = []
    ) {
        guard let first = path.first else { return }
        if let down = mouseEvent(.leftMouseDown, at: first, in: window, modifierFlags: modifierFlags) {
            view.mouseDown(with: down)
        }
        for point in path.dropFirst() {
            if let dragged = mouseEvent(.leftMouseDragged, at: point, in: window, modifierFlags: modifierFlags) {
                view.mouseDragged(with: dragged)
            }
        }
        let last = path.last ?? first
        if let up = mouseEvent(.leftMouseUp, at: last, in: window, modifierFlags: modifierFlags) {
            view.mouseUp(with: up)
        }
        pump(0.15)
    }

    private func drag(_ view: OverlayView, window: NSWindow, from: CGPoint, to: CGPoint) {
        press(view, window: window, path: [from, to])
        pump(0.2)
    }

    private func rightClick(_ view: OverlayView, window: NSWindow, at point: CGPoint) {
        guard let event = mouseEvent(.rightMouseDown, at: point, in: window) else { return }
        view.rightMouseDown(with: event)
        pump(0.2)
    }

    private func keyDown(
        _ keyCode: UInt16,
        characters: String,
        in window: NSWindow,
        view: OverlayView,
        modifierFlags: NSEvent.ModifierFlags = []
    ) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
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

    /// 发送修饰键变化。keyCode 只影响事件来源，行为由 modifierFlags 决定。
    private func flagsChanged(
        _ flags: NSEvent.ModifierFlags,
        in window: NSWindow,
        view: OverlayView
    ) {
        guard let event = NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: flags.contains(.option) ? 58 : 56
        ) else {
            fail("MAGNIFIER-FLAGS", "无法构造修饰键事件")
            return
        }
        view.flagsChanged(with: event)
        pump(0.1)
    }

    /// 直接驱动文字编辑器。编辑期间它是 first responder，按键不会经过 OverlayView.keyDown。
    private func sendKey(        _ keyCode: UInt16,
        characters: String,
        to editor: NSTextView,
        in window: NSWindow,
        modifierFlags: NSEvent.ModifierFlags = []
    ) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fail("TEXT-KEY", "无法构造键盘事件 keyCode=\(keyCode)")
            return
        }
        editor.keyDown(with: event)
        pump(0.2)
    }

    /// 工具条按钮点击入口。找不到按钮直接判失败。
    @discardableResult
    private func tapTool(_ view: OverlayView, _ kind: ShapeKind, id: String) -> Bool {
        guard let bar = view.subviews.compactMap({ $0 as? AnnotateToolbar }).first,
              let button = bar.toolButtons[kind] else {
            fail(id, "工具条上找不到 \(kind.rawValue) 按钮")
            return false
        }
        button.performClick(nil)
        pump(0.1)
        return true
    }

    /// 工具条选择按钮点击入口。
    @discardableResult
    private func tapSelect(_ view: OverlayView, id: String) -> Bool {
        guard let bar = view.subviews.compactMap({ $0 as? AnnotateToolbar }).first,
              let button = bar.selectButton else {
            fail(id, "工具条上找不到选择按钮")
            return false
        }
        button.performClick(nil)
        pump(0.1)
        return true
    }

    /// 工具条线型按钮点击入口。
    @discardableResult
    private func tapLineStyle(_ view: OverlayView, id: String) -> Bool {
        guard let bar = view.subviews.compactMap({ $0 as? AnnotateToolbar }).first,
              let button = bar.lineStyleButton else {
            fail(id, "工具条上找不到线型按钮")
            return false
        }
        button.performClick(nil)
        pump(0.1)
        return true
    }

    /// 打开颜色弹层并点选第 index 个色块。
    private func pickColor(_ view: OverlayView, _ index: Int, id: String) -> Bool {
        guard let bar = view.subviews.compactMap({ $0 as? AnnotateToolbar }).first else {
            fail(id, "找不到工具条")
            return false
        }
        bar.colorButton.performClick(nil)
        pump(0.2)
        guard let palette = bar.colorPopover?.contentViewController?.view as? ColorPaletteView,
              index < palette.swatches.count else {
            fail(id, "颜色弹层未弹出或色块不足")
            return false
        }
        palette.swatches[index].performClick(nil)
        pump(0.2)
        return true
    }

    /// 打开笔尖弹层并点选第 index 档（0 起）。
    private func pickPen(_ view: OverlayView, _ index: Int, id: String) -> Bool {
        guard let bar = view.subviews.compactMap({ $0 as? AnnotateToolbar }).first else {
            fail(id, "找不到工具条")
            return false
        }
        bar.penButton.performClick(nil)
        pump(0.2)
        guard let sizes = bar.penPopover?.contentViewController?.view as? PenSizeView,
              index < sizes.swatches.count else {
            fail(id, "笔尖弹层未弹出")
            return false
        }
        sizes.swatches[index].performClick(nil)
        pump(0.2)
        return true
    }

    /// 打开颜色弹层并点选第 index 个透明度档位。
    private func pickAlpha(_ view: OverlayView, _ index: Int, id: String) -> Bool {
        guard let bar = view.subviews.compactMap({ $0 as? AnnotateToolbar }).first else {
            fail(id, "找不到工具条")
            return false
        }
        bar.colorButton.performClick(nil)
        pump(0.2)
        guard let palette = bar.colorPopover?.contentViewController?.view as? ColorPaletteView,
              index < palette.alphaSwatches.count else {
            fail(id, "颜色弹层未弹出或透明度档位不足")
            return false
        }
        palette.alphaSwatches[index].performClick(nil)
        pump(0.2)
        return true
    }

    /// 发送一次滚轮事件。正 wheel1 表示向上滚。
    private func scroll(_ view: NSView, wheel1: Int32) {
        guard let cg = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: wheel1,
            wheel2: 0,
            wheel3: 0
        ), let event = NSEvent(cgEvent: cg) else {
            fail("SCROLL", "无法构造滚轮事件")
            return
        }
        view.scrollWheel(with: event)
        pump(0.15)
    }

    private func pasteboardImage() -> CGImage? {
        guard let tiff = NSPasteboard.general.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.cgImage
    }

    /// 走与复制 / 保存相同的导出路径，但不结束会话，便于同一次会话内前后对比。
    private func exportedBytes(_ view: OverlayView) -> [UInt8]? {
        let cropRectPx = RectMath.imageRect(
            fromViewRect: view.selectionRect,
            viewHeight: view.bounds.height,
            scale: view.shot.scale
        )
        guard let image = AnnotationExport.flatten(
            base: view.shot.image,
            cropRectPx: cropRectPx,
            annotations: view.annotations,
            scale: view.shot.scale
        ) else { return nil }
        return srgbBytes(image, width: image.width, height: image.height)
    }

    private func srgbBytes(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
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

    private func pixelColor(_ bytes: [UInt8], x: Int, y: Int, width: Int) -> (r: Int, g: Int, b: Int) {
        let offset = (y * width + x) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    private func capture(_ name: String) {
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else { return }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) {
            try? (data as Data).write(to: evidenceDir.appendingPathComponent(name))
        }
    }

    // MARK: - 用例

    /// 画矩形 → Enter 复制，剪贴板与参考渲染逐像素一致，方向与颜色独立验证。
    private func runDrawAndCopy() {
        guard let (window, view) = beginSession("ANNOTATE") else { return }
        let selectionOrigin = CGPoint(x: 200, y: 200)
        let selectionEnd = CGPoint(x: 600, y: 500)
        drag(view, window: window, from: selectionOrigin, to: selectionEnd)
        let selection = view.selectionRect
        guard !selection.isEmpty, verifyIntegral(selection) else {
            fail("ANNOTATE-SELECT", "selectionRect=\(selection) 不是整点非空矩形")
            endSession()
            return
        }
        pass("ANNOTATE-SELECT", "选区已确定并取整 \(selection)")

        // 选区内画矩形：画布目标 (50,180)-(250,250)
        let canvasStart = CGPoint(x: 50, y: 180)
        let canvasEnd = CGPoint(x: 250, y: 250)
        let viewStart = CGPoint(x: selection.minX + canvasStart.x, y: selection.minY + canvasStart.y)
        let viewMid = CGPoint(x: selection.minX + 150, y: selection.minY + 220)
        let viewEnd = CGPoint(x: selection.minX + canvasEnd.x, y: selection.minY + canvasEnd.y)
        press(view, window: window, path: [viewStart, viewMid, viewEnd])

        guard view.annotations.count == 1,
              case .rect(let rect) = view.annotations[0].shape,
              rect == CGRect(x: 50, y: 180, width: 200, height: 70) else {
            fail("ANNOTATE-DRAW", "annotations=\(view.annotations) 期望 1 条矩形 (50,180 200x70)")
            capture("p2-annotate-draw-fail.png")
            endSession()
            return
        }
        pass("ANNOTATE-DRAW", "画布坐标矩形 \(rect) 已入列")

        let annotations = view.annotations
        let scale = view.shot.scale
        let imageRect = RectMath.imageRect(
            fromViewRect: selection, viewHeight: view.bounds.height, scale: scale
        )
        capture("p2-annotate-preview.png")

        NSPasteboard.general.clearContents()
        keyDown(36, characters: "\r", in: window, view: view)

        guard let actual = pasteboardImage() else {
            fail("ANNOTATE-COPY", "剪贴板没有图像")
            endSession()
            return
        }
        let expectedPxW = Int(imageRect.width)
        let expectedPxH = Int(imageRect.height)
        guard actual.width == expectedPxW, actual.height == expectedPxH else {
            fail("ANNOTATE-COPY", "剪贴板 \(actual.width)x\(actual.height) 期望 \(expectedPxW)x\(expectedPxH)")
            endSession()
            return
        }

        // 参考渲染：同一选区 + 同一标注数据
        guard let reference = AnnotationExport.flatten(
            base: view.shot.image,
            cropRectPx: imageRect,
            annotations: annotations,
            scale: scale
        ), let actualBytes = srgbBytes(actual, width: expectedPxW, height: expectedPxH),
            let referenceBytes = srgbBytes(reference, width: expectedPxW, height: expectedPxH) else {
            fail("ANNOTATE-COPY", "参考渲染或像素读取失败")
            endSession()
            return
        }
        if actualBytes == referenceBytes {
            pass("ANNOTATE-COPY", "剪贴板与参考渲染逐字节一致 \(expectedPxW)x\(expectedPxH)")
        } else {
            var mismatched = 0
            for index in 0..<actualBytes.count where actualBytes[index] != referenceBytes[index] {
                mismatched += 1
            }
            fail("ANNOTATE-COPY", "与参考渲染不一致，差异字节 \(mismatched)")
        }

        // 独立验证：不依赖 flatten 的正确性
        let pxScale = Int(scale)
        // 矩形 (50,180,200,70) 空心描边、线宽 5pt：左边缘 x 50..55，取 52 落在边框上
        let border = pixelColor(actualBytes, x: 52 * pxScale, y: expectedPxH - 1 - 215 * pxScale, width: expectedPxW)
        let annotationColor = annotations[0].style.color
        let target = (r: Int(annotationColor.r * 255), g: Int(annotationColor.g * 255), b: Int(annotationColor.b * 255))
        if abs(border.r - target.r) < 30, abs(border.g - target.g) < 30, abs(border.b - target.b) < 30 {
            pass("ANNOTATE-COLOR", "矩形边框像素 \(border) ≈ 标注色 \(target)")
        } else {
            fail("ANNOTATE-COLOR", "矩形边框像素 \(border) 偏离标注色 \(target)")
        }
        // 空心：矩形内部保留底图，不与冻结帧裁剪产生差异
        let inner = pixelColor(actualBytes, x: 150 * pxScale, y: expectedPxH - 1 - 215 * pxScale, width: expectedPxW)
        let innerFrozen = pixelColor(
            srgbBytes(view.shot.image, width: view.shot.image.width, height: view.shot.image.height) ?? [],
            x: Int(imageRect.minX) + 150 * pxScale,
            y: Int(imageRect.minY) + (expectedPxH - 1 - 215 * pxScale),
            width: view.shot.image.width
        )
        if abs(inner.r - innerFrozen.r) <= 8, abs(inner.g - innerFrozen.g) <= 8, abs(inner.b - innerFrozen.b) <= 8 {
            pass("ANNOTATE-HOLLOW", "矩形内部为底图 \(inner)，标注未填充")
        } else {
            fail("ANNOTATE-HOLLOW", "矩形内部被填充 inner=\(inner) frozen=\(innerFrozen)")
        }
        // 画布 (150,247) 在矩形上边框（y 245..250）→ 应落在图像上半（y 翻转会落到下半）
        let topProbe = pixelColor(actualBytes, x: 150 * pxScale, y: expectedPxH - 1 - 247 * pxScale, width: expectedPxW)
        if topProbe.r > 200, expectedPxH - 1 - 247 * pxScale < expectedPxH / 2 {
            pass("ANNOTATE-ORIENTATION", "画布上部的矩形落在图像上半部 \(topProbe)")
        } else {
            fail("ANNOTATE-ORIENTATION", "矩形方向错误 topProbe=\(topProbe)")
        }
        // 矩形外 10 个采样点必须与冻结帧裁剪一致
        var outsideMismatch = 0
        for sample in 0..<10 {
            let canvasX = 300 + sample * 9        // 画布 (300..381, 20..) 矩形右侧
            let canvasY = 20 + sample * 5
            let px = canvasX * pxScale
            let py = expectedPxH - 1 - canvasY * pxScale
            let actualPixel = pixelColor(actualBytes, x: px, y: py, width: expectedPxW)
            // 剪贴板与冻结帧都按顶部行号，帧行 = cropRect 顶行 + py
            let frozen = pixelColor(
                srgbBytes(view.shot.image, width: view.shot.image.width, height: view.shot.image.height) ?? [],
                x: Int(imageRect.minX) + px,
                y: Int(imageRect.minY) + py,
                width: view.shot.image.width
            )
            if abs(actualPixel.r - frozen.r) > 8 || abs(actualPixel.g - frozen.g) > 8 || abs(actualPixel.b - frozen.b) > 8 {
                outsideMismatch += 1
            }
        }
        if outsideMismatch == 0 {
            pass("ANNOTATE-BASE", "矩形外采样点与冻结帧裁剪一致")
        } else {
            fail("ANNOTATE-BASE", "\(outsideMismatch)/10 个底图采样点不一致")
        }

        if visibleOverlayWindows.isEmpty {
            pass("ANNOTATE-CLOSE", "复制后覆盖层消失")
        } else {
            fail("ANNOTATE-CLOSE", "复制后仍有 \(visibleOverlayWindows.count) 个覆盖窗口")
        }
        endSession()
    }

    /// ready 选区内单击不产生形状；微小拖动被丢弃。
    private func runClickAndTinyStroke() {
        guard let (window, view) = beginSession("ANNOTATE-CLICK") else { return }
        drag(view, window: window, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 600, y: 500))

        // 单击选区内，不拖动
        press(view, window: window, path: [CGPoint(x: 300, y: 300)])
        guard view.annotations.isEmpty else {
            fail("ANNOTATE-CLICK", "单击后产生 \(view.annotations.count) 条标注")
            endSession()
            return
        }
        pass("ANNOTATE-CLICK", "ready 下单击未产生形状")

        // 位移 3x1：进入 drawing 但高度不足被丢弃
        press(view, window: window, path: [
            CGPoint(x: 300, y: 300),
            CGPoint(x: 303, y: 301),
        ])
        guard view.annotations.isEmpty else {
            fail("ANNOTATE-DISCARD", "3x1 拖动后残留 \(view.annotations.count) 条标注")
            endSession()
            return
        }
        pass("ANNOTATE-DISCARD", "不足 2pt 边长的拖动被丢弃")

        // 正常笔画仍可用（状态机回到 ready）
        press(view, window: window, path: [
            CGPoint(x: 250, y: 250),
            CGPoint(x: 400, y: 350),
        ])
        if view.annotations.count == 1 {
            pass("ANNOTATE-RECOVER", "丢弃后继续画矩形正常")
        } else {
            fail("ANNOTATE-RECOVER", "丢弃后画矩形失败 annotations=\(view.annotations)")
        }
        endSession()
    }

    /// 选区外按下清空标注并重画选区。
    private func runReselectClears() {
        guard let (window, view) = beginSession("ANNOTATE-RESELECT") else { return }
        drag(view, window: window, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 600, y: 500))
        press(view, window: window, path: [
            CGPoint(x: 250, y: 250),
            CGPoint(x: 400, y: 350),
        ])
        guard view.annotations.count == 1 else {
            fail("ANNOTATE-RESELECT", "前置画矩形失败")
            endSession()
            return
        }
        // 选区外按下重画
        drag(view, window: window, from: CGPoint(x: 700, y: 100), to: CGPoint(x: 900, y: 300))
        if view.annotations.isEmpty {
            pass("ANNOTATE-RESELECT", "选区外重画后标注已清空，新选区 \(view.selectionRect)")
        } else {
            fail("ANNOTATE-RESELECT", "选区外重画后残留 \(view.annotations.count) 条标注")
        }
        endSession()
    }

    /// P1 行为回归：无标注时复制结果与冻结帧裁剪逐像素一致。
    private func runPlainCopyUnchanged() {
        guard let (window, view) = beginSession("ANNOTATE-PLAIN") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 450, y: 350))
        let rect = view.selectionRect
        let imageRect = RectMath.imageRect(
            fromViewRect: rect, viewHeight: view.bounds.height, scale: view.shot.scale
        )
        let integral = imageRect.integral.intersection(
            CGRect(x: 0, y: 0, width: view.shot.image.width, height: view.shot.image.height)
        )
        let expected = view.shot.image.cropping(to: integral)
        NSPasteboard.general.clearContents()
        keyDown(36, characters: "\r", in: window, view: view)
        guard let actual = pasteboardImage() else {
            fail("ANNOTATE-PLAIN", "剪贴板没有图像")
            endSession()
            return
        }
        guard let expected,
              let a = srgbBytes(actual, width: Int(imageRect.width), height: Int(imageRect.height)),
              let e = srgbBytes(expected, width: Int(imageRect.width), height: Int(imageRect.height)) else {
            fail("ANNOTATE-PLAIN", "像素读取失败")
            endSession()
            return
        }
        if a == e {
            pass("ANNOTATE-PLAIN", "无标注复制与冻结帧裁剪逐字节一致")
        } else {
            var mismatched = 0
            for index in 0..<a.count where a[index] != e[index] { mismatched += 1 }
            fail("ANNOTATE-PLAIN", "无标注复制有 \(mismatched) 字节差异")
        }
        endSession()
    }

    /// 选区是否整点（integral 后预览与导出位图尺寸才一致）。
    private func verifyIntegral(_ rect: CGRect) -> Bool {
        rect.origin.x.rounded() == rect.origin.x
            && rect.origin.y.rounded() == rect.origin.y
            && rect.width.rounded() == rect.width
            && rect.height.rounded() == rect.height
    }

    // MARK: - 第二批：形状 / 样式记忆 / ⌘Z

    /// 切换工具画形状 → 复制，独立验证剪贴板中该形状的特征像素。
    private func runShapeCopy(_ id: String, tool: ShapeKind, drawPath: [CGPoint], verify: @escaping (CGImage, OverlayView, CGRect, [Annotation]) -> Void) {
        guard let (window, view) = beginSession(id) else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 600))
        let selection = view.selectionRect
        guard !selection.isEmpty else {
            fail(id, "选区未确定")
            endSession()
            return
        }
        guard tapTool(view, tool, id: id) else {
            endSession()
            return
        }
        // 画布点 = 视图点 - 选区原点
        let viewPath = drawPath.map { CGPoint(x: selection.minX + $0.x, y: selection.minY + $0.y) }
        press(view, window: window, path: viewPath)
        guard let annotation = view.annotations.last,
              annotation.shape.kind == tool else {
            fail(id, "最后一条标注不是 \(tool.rawValue)：\(view.annotations.map(\.shape.kind.rawValue))")
            endSession()
            return
        }
        let annotations = view.annotations
        NSPasteboard.general.clearContents()
        keyDown(36, characters: "\r", in: window, view: view)
        guard let image = pasteboardImage() else {
            fail(id, "剪贴板没有图像")
            endSession()
            return
        }
        verify(image, view, selection, annotations)
        endSession()
    }

    private func runShapeCopies() {
        // 椭圆：中线有色、中心与四角保留底图
        runShapeCopy("SHAPE-ELLIPSE", tool: .ellipse, drawPath: [
            CGPoint(x: 40, y: 80), CGPoint(x: 240, y: 180),
        ]) { image, view, selection, annotations in
            guard case .ellipse(let rect) = annotations.last?.shape else {
                self.fail("SHAPE-ELLIPSE", "形状不是椭圆")
                return
            }
            guard let bytes = self.srgbBytes(image, width: image.width, height: image.height) else {
                self.fail("SHAPE-ELLIPSE", "像素读取失败")
                return
            }
            let px = Int(view.shot.scale)
            let width = image.width
            let height = image.height
            func pixel(atCanvasX x: Int, canvasY y: Int) -> (r: Int, g: Int, b: Int) {
                let offset = ((height - 1 - y * px) * width + x * px) * 4
                return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
            }
            let isAnnotationColor = { (p: (r: Int, g: Int, b: Int)) in
                p.r > 180 && p.g < 130 && p.b < 130
            }
            // 内缩后椭圆：中心 (cx, cy)，半轴 (rx, ry)；下边框中点与左边框中点着色
            let cx = Int(rect.midX), cy = Int(rect.midY)
            let ry = Int(rect.height / 2 - 1.25)
            let rx = Int(rect.width / 2 - 1.25)
            if isAnnotationColor(pixel(atCanvasX: cx, canvasY: cy - ry)),
               isAnnotationColor(pixel(atCanvasX: cx - rx, canvasY: cy)) {
                self.pass("SHAPE-ELLIPSE", "椭圆中线着色 rect=\(rect)")
            } else {
                self.fail("SHAPE-ELLIPSE", "椭圆中线未着色 bottom=\(pixel(atCanvasX: cx, canvasY: cy - ry)) left=\(pixel(atCanvasX: cx - rx, canvasY: cy))")
            }
            let center = pixel(atCanvasX: cx, canvasY: cy)
            let frozen = self.frozenPixel(view, selection: selection, canvasX: cx, canvasY: cy, scale: view.shot.scale)
            if self.closeEnough(center, frozen) {
                self.pass("SHAPE-ELLIPSE-HOLLOW", "椭圆中心保留底图 \(center)")
            } else {
                self.fail("SHAPE-ELLIPSE-HOLLOW", "椭圆中心被填色 \(center) 底图 \(frozen)")
            }
        }

        // 箭头：tip 附近头部填充、线体中段有色、线外留白
        runShapeCopy("SHAPE-ARROW", tool: .arrow, drawPath: [
            CGPoint(x: 60, y: 250), CGPoint(x: 380, y: 250),
        ]) { image, view, _, annotations in
            guard case .arrow(let from, let to) = annotations.last?.shape else {
                self.fail("SHAPE-ARROW", "形状不是箭头")
                return
            }
            guard let bytes = self.srgbBytes(image, width: image.width, height: image.height) else {
                self.fail("SHAPE-ARROW", "像素读取失败")
                return
            }
            let px = Int(view.shot.scale)
            let width = image.width
            let height = image.height
            func pixel(atCanvasX x: Int, canvasY y: Int) -> (r: Int, g: Int, b: Int) {
                let offset = ((height - 1 - y * px) * width + x * px) * 4
                return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
            }
            let isAnnotationColor = { (p: (r: Int, g: Int, b: Int)) in
                p.r > 180 && p.g < 130 && p.b < 130
            }
            // 线宽 5 → 头长 22.5，tip 在 to；头部中段与线体中点都应着色
            let headInside = Int(to.x - 8)
            let midLine = Int((from.x + to.x) / 2)
            if isAnnotationColor(pixel(atCanvasX: headInside, canvasY: Int(to.y))),
               isAnnotationColor(pixel(atCanvasX: midLine, canvasY: Int(from.y))) {
                self.pass("SHAPE-ARROW", "箭头头部填充且线体着色 from=\(from) to=\(to)")
            } else {
                self.fail("SHAPE-ARROW", "箭头特征缺失 head=\(pixel(atCanvasX: headInside, canvasY: Int(to.y))) mid=\(pixel(atCanvasX: midLine, canvasY: Int(from.y)))")
            }
            let outside = pixel(atCanvasX: midLine, canvasY: Int(from.y) + 12)
            if !isAnnotationColor(outside) {
                self.pass("SHAPE-ARROW-OFFLINE", "箭头线外保留底图 \(outside)")
            } else {
                self.fail("SHAPE-ARROW-OFFLINE", "线外被着色 \(outside)")
            }
        }

        // 马赛克：块内均匀 + 与冻结帧存在差异
        runShapeCopy("SHAPE-MOSAIC", tool: .mosaic, drawPath: [
            CGPoint(x: 30, y: 150), CGPoint(x: 90, y: 150), CGPoint(x: 370, y: 150),
        ]) { image, view, selection, annotations in
            guard annotations.last?.shape.kind == .mosaic else {
                self.fail("SHAPE-MOSAIC", "形状不是马赛克")
                return
            }
            guard let bytes = self.srgbBytes(image, width: image.width, height: image.height) else {
                self.fail("SHAPE-MOSAIC", "像素读取失败")
                return
            }
            let px = Int(view.shot.scale)
            let width = image.width
            let height = image.height
            func pixel(atCanvasX x: Int, canvasY y: Int) -> (r: Int, g: Int, b: Int) {
                let offset = ((height - 1 - y * px) * width + x * px) * 4
                return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
            }
            // 块内均匀：p3 块 16pt，region.minX ≈ 30-7.5 → 22；(30,32) (100,102) 同块
            var uneven = 0
            for pair in [(30, 32), (100, 102), (200, 202)] {
                let a = pixel(atCanvasX: pair.0, canvasY: 150)
                let b = pixel(atCanvasX: pair.1, canvasY: 150)
                if abs(a.r - b.r) > 6 || abs(a.g - b.g) > 6 || abs(a.b - b.b) > 6 {
                    uneven += 1
                }
            }
            if uneven == 0 {
                self.pass("SHAPE-MOSAIC-UNIFORM", "块内采样对颜色一致")
            } else {
                self.fail("SHAPE-MOSAIC-UNIFORM", "\(uneven)/3 组块内采样对不一致")
            }
            // 与冻结帧差异只能作参考：屏幕该区域本身均匀时，块平均与原图相同，无法区分。
            // 量化正确性由 AnnotationRendererTests.mosaicQuantizesBasePixels 用条纹底图确定性验证。
            var diff = 0
            var total = 0
            for x in stride(from: 40, through: 360, by: 10) {
                let actual = pixel(atCanvasX: x, canvasY: 150)
                let frozen = self.frozenPixel(view, selection: selection, canvasX: x, canvasY: 150, scale: view.shot.scale)
                total += 1
                if abs(actual.r - frozen.r) > 12 || abs(actual.g - frozen.g) > 12 || abs(actual.b - frozen.b) > 12 {
                    diff += 1
                }
            }
            self.info("SHAPE-MOSAIC-PIXELS", "\(diff)/\(total) 个采样点与冻结帧不同（屏幕均匀时可为 0）")
        }
    }

    /// 冻结帧在画布 (canvasX, canvasY) 处的像素。canvas 原点在选区左下（y 向上），
    /// 帧像素 y 向下：帧行 = cropOrigin.y + (viewHeight - selection.minY - canvasY) * scale。
    private func frozenPixel(
        _ view: OverlayView,
        selection: CGRect,
        canvasX: Int,
        canvasY: Int,
        scale: CGFloat
    ) -> (r: Int, g: Int, b: Int) {
        guard let bytes = srgbBytes(
            view.shot.image, width: view.shot.image.width, height: view.shot.image.height
        ) else { return (-1, -1, -1) }
        let px = Int(view.shot.scale)
        let imageRect = RectMath.imageRect(
            fromViewRect: selection, viewHeight: view.bounds.height, scale: scale
        )
        let x = Int(imageRect.minX) + canvasX * px
        let y = Int(imageRect.minY) + Int((selection.height - CGFloat(canvasY))) * px
        let offset = (y * view.shot.image.width + x) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    private func closeEnough(
        _ a: (r: Int, g: Int, b: Int),
        _ b: (r: Int, g: Int, b: Int)
    ) -> Bool {
        abs(a.r - b.r) <= 8 && abs(a.g - b.g) <= 8 && abs(a.b - b.b) <= 8
    }

    /// 切工具读回各自记忆的色与笔尖：椭圆改蓝后，矩形仍是红、笔尖互不串。
    private func runToolStyleMemory() {
        guard let (window, view) = beginSession("TOOL-MEMORY") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 600))
        let selection = view.selectionRect

        guard tapTool(view, .ellipse, id: "TOOL-MEMORY"),
              pickColor(view, 5, id: "TOOL-MEMORY") else {
            endSession()
            return
        }
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 30, y: selection.minY + 60),
            CGPoint(x: selection.minX + 180, y: selection.minY + 150),
        ])
        guard let ellipseStroke = view.annotations.last,
              ellipseStroke.shape.kind == .ellipse,
              ellipseStroke.style.color == RGBAColor.palette[5] else {
            fail("TOOL-MEMORY", "椭圆应为蓝色，实际 \(String(describing: view.annotations.last?.style.color))")
            endSession()
            return
        }
        pass("TOOL-MEMORY", "椭圆工具 + 蓝色已写入")

        guard tapTool(view, .rect, id: "TOOL-MEMORY") else {
            endSession()
            return
        }
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 260, y: selection.minY + 60),
            CGPoint(x: selection.minX + 400, y: selection.minY + 140),
        ])
        guard let rectStroke = view.annotations.last,
              rectStroke.shape.kind == .rect,
              rectStroke.style.color == RGBAColor.palette[0] else {
            fail("TOOL-MEMORY", "矩形应保持默认红色，实际 \(String(describing: view.annotations.last?.style.color))")
            endSession()
            return
        }
        pass("TOOL-MEMORY", "切回矩形读回红色，两工具颜色互不串")

        // 笔尖记忆：画笔改 p5，椭圆笔尖仍应是默认 p3
        guard tapTool(view, .brush, id: "TOOL-MEMORY"),
              pickPen(view, 4, id: "TOOL-MEMORY") else {
            endSession()
            return
        }
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 40, y: selection.minY + 260),
            CGPoint(x: selection.minX + 300, y: selection.minY + 260),
            CGPoint(x: selection.minX + 310, y: selection.minY + 262),
        ])
        guard let brushStroke = view.annotations.last,
              brushStroke.shape.kind == .brush,
              brushStroke.style.pen == .p5 else {
            fail("TOOL-MEMORY", "画笔应为 p5，实际 \(String(describing: view.annotations.last?.style.pen))")
            endSession()
            return
        }
        pass("TOOL-MEMORY", "画笔工具 + p5 已写入")

        guard tapTool(view, .ellipse, id: "TOOL-MEMORY") else {
            endSession()
            return
        }
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 420, y: selection.minY + 60),
            CGPoint(x: selection.minX + 520, y: selection.minY + 130),
        ])
        guard let secondEllipse = view.annotations.last,
              secondEllipse.shape.kind == .ellipse,
              secondEllipse.style.pen == .p3,
              secondEllipse.style.color == RGBAColor.palette[5] else {
            fail("TOOL-MEMORY", "椭圆应读回自己的蓝 + p3，实际 \(String(describing: view.annotations.last?.style))")
            endSession()
            return
        }
        pass("TOOL-MEMORY", "椭圆读回自己的颜色与笔尖，画笔的 p5 不串")
        endSession()
    }

    /// ⌘Z 撤销最后一笔；空栈时 beep 不崩溃。
    private func runUndo() {
        guard let (window, view) = beginSession("UNDO") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 600))
        let selection = view.selectionRect
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 40, y: selection.minY + 40),
            CGPoint(x: selection.minX + 200, y: selection.minY + 120),
        ])
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 240, y: selection.minY + 40),
            CGPoint(x: selection.minX + 400, y: selection.minY + 120),
        ])
        guard view.annotations.count == 2 else {
            fail("UNDO", "前置画两笔失败：\(view.annotations.count)")
            endSession()
            return
        }
        keyDown(6, characters: "z", in: window, view: view, modifierFlags: .command)
        guard view.annotations.count == 1 else {
            fail("UNDO", "⌘Z 后应剩 1 笔，实际 \(view.annotations.count)")
            endSession()
            return
        }
        keyDown(6, characters: "z", in: window, view: view, modifierFlags: .command)
        guard view.annotations.isEmpty else {
            fail("UNDO", "⌘Z 后应清空，实际 \(view.annotations.count)")
            endSession()
            return
        }
        // 空栈再按：beep（无法断言声音），只验证不崩溃且状态不变
        keyDown(6, characters: "z", in: window, view: view, modifierFlags: .command)
        if view.annotations.isEmpty, !view.selectionRect.isEmpty {
            pass("UNDO", "⌘Z 撤销两笔生效，空栈再按不崩溃")
        } else {
            fail("UNDO", "空栈 ⌘Z 后状态异常 selection=\(view.selectionRect)")
        }
        endSession()
    }

    /// 文字工具：选区内单击进入编辑 → Enter 只换行 → ⌘Enter 提交 → 复制后剪贴板出现标注色文字像素。
    private func runTextAnnotation() {
        guard let (window, view) = beginSession("TEXT") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 600))
        let selection = view.selectionRect
        guard tapTool(view, .text, id: "TEXT") else {
            endSession()
            return
        }
        let click = CGPoint(x: selection.minX + 60, y: selection.minY + 220)
        press(view, window: window, path: [click])
        guard let editor = view.subviews.compactMap({ $0 as? NSTextView }).first else {
            fail("TEXT-COMMIT", "单击后没有出现文字编辑器")
            endSession()
            return
        }
        editor.string = "Hello"
        sendKey(36, characters: "\r", to: editor, in: window)
        guard view.annotations.isEmpty, editor.superview != nil else {
            fail("TEXT-COMMIT", "Enter 不应提交 annotations=\(view.annotations)")
            endSession()
            return
        }
        sendKey(53, characters: "\u{1b}", to: editor, in: window)
        guard view.annotations.isEmpty, editor.superview == nil else {
            fail("TEXT-COMMIT", "Esc 应取消编辑 annotations=\(view.annotations)")
            endSession()
            return
        }
        press(view, window: window, path: [click])
        guard let reopened = view.subviews.compactMap({ $0 as? NSTextView }).first else {
            fail("TEXT-COMMIT", "取消后无法重新进入编辑")
            endSession()
            return
        }
        reopened.string = "Hello"
        sendKey(36, characters: "\r", to: reopened, in: window, modifierFlags: .command)

        guard view.annotations.count == 1,
              case .text(let text, let origin, let fontSize, let rotation) = view.annotations[0].shape,
              text == "Hello",
              origin == CGPoint(x: 60, y: 220),
              fontSize == PenSize.p3.textFontSize,
              rotation == 0 else {
            fail("TEXT-COMMIT", "提交结果异常 annotations=\(view.annotations)")
            endSession()
            return
        }
        pass("TEXT-COMMIT", "Enter 不提交、Esc 取消、⌘Enter 提交；文字已入列 origin=\(origin) fontSize=\(fontSize)")

        NSPasteboard.general.clearContents()
        keyDown(36, characters: "\r", in: window, view: view)
        guard let image = pasteboardImage(),
              let bytes = srgbBytes(image, width: image.width, height: image.height) else {
            fail("TEXT-PIXELS", "剪贴板没有图像")
            endSession()
            return
        }
        let px = Int(view.shot.scale)
        let box = TextMetrics.boundingRect(text, fontSize: fontSize, origin: origin)
        var colored = 0
        for canvasY in Int(box.minY.rounded(.down))...Int(box.maxY.rounded(.up)) {
            for canvasX in Int(box.minX.rounded(.down))...Int(box.maxX.rounded(.up))
                where canvasX >= 0 && canvasY >= 0
                    && canvasX * px < image.width && canvasY * px < image.height {
                let offset = ((image.height - 1 - canvasY * px) * image.width + canvasX * px) * 4
                if Int(bytes[offset]) > 180,
                   Int(bytes[offset + 1]) < 130,
                   Int(bytes[offset + 2]) < 130 {
                    colored += 1
                }
            }
        }
        if colored > 0 {
            pass("TEXT-PIXELS", "剪贴板文字区域有 \(colored) 个标注色像素")
        } else {
            fail("TEXT-PIXELS", "文字区域没有标注色像素 box=\(box)")
        }
        endSession()
    }

    /// 多行文字：两行中文，断言行数、换行保留与包围盒高度。
    private func runMultilineText() {
        guard let (window, view) = beginSession("TEXT-MULTILINE") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 640))
        let selection = view.selectionRect
        guard tapTool(view, .text, id: "TEXT-MULTILINE") else {
            endSession()
            return
        }
        let click = CGPoint(x: selection.minX + 60, y: selection.minY + 280)
        press(view, window: window, path: [click])
        guard let editor = view.subviews.compactMap({ $0 as? NSTextView }).first else {
            fail("TEXT-MULTILINE", "单击后没有出现文字编辑器")
            endSession()
            return
        }
        editor.string = "测试文字\n测试文字"
        sendKey(36, characters: "\r", to: editor, in: window, modifierFlags: .command)

        guard view.annotations.count == 1,
              case .text(let text, let origin, let fontSize, _) = view.annotations[0].shape,
              text == "测试文字\n测试文字" else {
            fail("TEXT-MULTILINE", "多行提交异常 annotations=\(view.annotations)")
            endSession()
            return
        }
        let layout = TextMetrics.multiline(text, fontSize: fontSize, origin: origin)
        // 单行实测高度：行距不小于它才不重叠，包围盒要盖住两行叠起来的高度。
        let lineHeight = TextMetrics.boundingRect("测试文字", fontSize: fontSize, origin: origin).height
        let step = layout.lines[0].baseline.y - layout.lines[1].baseline.y
        guard layout.lines.count == 2,
              step >= lineHeight - 0.01,
              layout.rect.height >= step + lineHeight - 0.5,
              layout.lines[1].baseline.y < origin.y else {
            fail("TEXT-MULTILINE", "行布局异常 lines=\(layout.lines.count) rect=\(layout.rect) 行距=\(step) 单行高=\(lineHeight)")
            endSession()
            return
        }
        pass("TEXT-MULTILINE", "两行已入列 lines=\(layout.lines.count) rect.height=\(layout.rect.height) 行距=\(step) 单行高=\(lineHeight)")
        endSession()
    }

    /// 文字控制点：拖角缩放、拖顶部圆点旋转、Shift 拖角回正，导出像素随旋转变化。
    private func runTextTransform() {
        guard let (window, view) = beginSession("TEXT-TRANSFORM") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 650))
        let selection = view.selectionRect
        guard tapTool(view, .text, id: "TEXT-RESIZE") else {
            endSession()
            return
        }
        let click = CGPoint(x: selection.minX + 60, y: selection.minY + 260)
        press(view, window: window, path: [click])
        guard let editor = view.subviews.compactMap({ $0 as? NSTextView }).first else {
            fail("TEXT-RESIZE", "单击后没有出现文字编辑器")
            endSession()
            return
        }
        editor.string = "Hi"
        sendKey(36, characters: "\r", to: editor, in: window, modifierFlags: .command)

        func viewPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: selection.minX + point.x, y: selection.minY + point.y)
        }
        func scaledFromCenter(_ point: CGPoint, around center: CGPoint, by scale: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + (point.x - center.x) * scale,
                y: center.y + (point.y - center.y) * scale
            )
        }

        guard view.annotations.count == 1,
              let geometry = view.annotations[0].shape.textGeometry,
              case .text(_, _, let fontSize0, let rotation0) = view.annotations[0].shape,
              rotation0 == 0 else {
            fail("TEXT-RESIZE", "前置文字标注缺失 annotations=\(view.annotations.count)")
            endSession()
            return
        }
        let center = viewPoint(geometry.center)

        let corner = viewPoint(geometry.point(for: .bottomRight))
        press(
            view,
            window: window,
            path: [corner, scaledFromCenter(corner, around: center, by: 1.6)]
        )
        guard case .text(_, _, let fontSize1, let rotation1) = view.annotations[0].shape,
              rotation1 == 0,
              fontSize1 > fontSize0 * 1.4 else {
            fail("TEXT-RESIZE", "拖右下角应放大字号 fontSize \(fontSize0) → \(view.annotations[0].shape)")
            endSession()
            return
        }
        pass("TEXT-RESIZE", "拖右下角字号 \(fontSize0) → \(fontSize1)，旋转保持 0")

        guard let beforeBytes = exportedBytes(view) else {
            fail("TEXT-ROTATE-PIXELS", "旋转前导出没有图像")
            endSession()
            return
        }

        guard let rotateGeometry = view.annotations[0].shape.textGeometry else {
            fail("TEXT-ROTATE", "缩放后丢失文字形状")
            endSession()
            return
        }
        press(view, window: window, path: [
            viewPoint(rotateGeometry.point(for: .rotate)),
            CGPoint(x: center.x + 120, y: center.y),
        ])
        guard case .text(_, _, let fontSize2, let rotation2) = view.annotations[0].shape,
              abs(rotation2) > 0.01,
              abs(fontSize2 - fontSize1) < 0.001 else {
            fail("TEXT-ROTATE", "拖顶部圆点应只改旋转 shape=\(view.annotations[0].shape)")
            endSession()
            return
        }
        pass("TEXT-ROTATE", "拖顶部圆点旋转 \(rotation2) 弧度，字号不变")

        guard let afterBytes = exportedBytes(view) else {
            fail("TEXT-ROTATE-PIXELS", "旋转后导出没有图像")
            endSession()
            return
        }
        guard beforeBytes != afterBytes else {
            fail("TEXT-ROTATE-PIXELS", "旋转前后导出像素完全一致")
            endSession()
            return
        }
        pass("TEXT-ROTATE-PIXELS", "旋转后导出像素与旋转前不同")

        guard let shiftGeometry = view.annotations[0].shape.textGeometry else {
            fail("TEXT-UNROTATE", "旋转后丢失文字形状")
            endSession()
            return
        }
        let shiftCorner = viewPoint(shiftGeometry.point(for: .topRight))
        press(
            view,
            window: window,
            path: [shiftCorner, scaledFromCenter(shiftCorner, around: center, by: 1.3)],
            modifierFlags: .shift
        )
        guard case .text(_, _, let fontSize3, let rotation3) = view.annotations[0].shape,
              abs(rotation3) < 1e-9,
              fontSize3 > fontSize2 * 1.1 else {
            fail("TEXT-UNROTATE", "Shift 拖角应回正并放大 shape=\(view.annotations[0].shape)")
            endSession()
            return
        }
        pass("TEXT-UNROTATE", "Shift 拖角 rotation → 0，字号 \(fontSize2) → \(fontSize3)")
        endSession()
    }

    // MARK: - P5 二次编辑

    /// 选择工具点选矩形后拖动：数量不变，包围盒按拖动距离平移。
    private func runSelectDrag() {
        guard let (window, view) = beginSession("SELECT-DRAG") else { return }
        drag(view, window: window, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 700, y: 600))
        let selection = view.selectionRect
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 50, y: selection.minY + 50),
            CGPoint(x: selection.minX + 250, y: selection.minY + 150),
        ])
        guard view.annotations.count == 1, tapSelect(view, id: "SELECT-DRAG") else {
            fail("SELECT-DRAG", "前置画矩形或切选择工具失败 annotations=\(view.annotations.count)")
            endSession()
            return
        }
        press(view, window: window, path: [CGPoint(x: selection.minX + 100, y: selection.minY + 100)])
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 100, y: selection.minY + 100),
            CGPoint(x: selection.minX + 150, y: selection.minY + 120),
        ])
        let expected = CGRect(x: 100, y: 70, width: 200, height: 100)
        guard view.annotations.count == 1,
              case .rect(let rect) = view.annotations[0].shape,
              rect == expected else {
            fail("SELECT-DRAG", "拖动后 annotations=\(view.annotations) 期望 1 条 \(expected)")
            endSession()
            return
        }
        pass("SELECT-DRAG", "选中并拖动 (50,20)，矩形移到 \(rect)，数量保持 1")
        endSession()
    }

    /// 选中后 Delete / Forward Delete 删除。
    private func runDeleteSelection() {
        guard let (window, view) = beginSession("DELETE") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 700, y: 550))
        let selection = view.selectionRect
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 40, y: selection.minY + 40),
            CGPoint(x: selection.minX + 140, y: selection.minY + 120),
        ])
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 180, y: selection.minY + 40),
            CGPoint(x: selection.minX + 280, y: selection.minY + 120),
        ])
        guard view.annotations.count == 2, tapSelect(view, id: "DELETE") else {
            fail("DELETE", "前置画两笔或切选择工具失败 annotations=\(view.annotations.count)")
            endSession()
            return
        }
        press(view, window: window, path: [CGPoint(x: selection.minX + 60, y: selection.minY + 60)])
        let remainingID = view.annotations[1].id
        keyDown(51, characters: "\u{7f}", in: window, view: view)
        guard view.annotations.count == 1, view.annotations[0].id == remainingID else {
            fail("DELETE", "Delete 后应只剩第二笔，实际 \(view.annotations)")
            endSession()
            return
        }
        press(view, window: window, path: [CGPoint(x: selection.minX + 200, y: selection.minY + 60)])
        keyDown(117, characters: "\u{7f}", in: window, view: view)
        guard view.annotations.isEmpty else {
            fail("DELETE", "Forward Delete 后应清空，实际 \(view.annotations.count)")
            endSession()
            return
        }
        pass("DELETE", "Delete 与 Forward Delete 均删除选中，其余标注不受影响")
        endSession()
    }

    /// ⌘⇧C / ⌘⇧V：应用内剪贴板粘贴出偏移 12pt 的新形状。
    private func runCopyPasteSelection() {
        guard let (window, view) = beginSession("COPY-PASTE") else { return }
        drag(view, window: window, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 700, y: 600))
        let selection = view.selectionRect
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 50, y: selection.minY + 50),
            CGPoint(x: selection.minX + 250, y: selection.minY + 150),
        ])
        guard view.annotations.count == 1, tapSelect(view, id: "COPY-PASTE") else {
            fail("COPY-PASTE", "前置画矩形或切选择工具失败 annotations=\(view.annotations.count)")
            endSession()
            return
        }
        press(view, window: window, path: [CGPoint(x: selection.minX + 100, y: selection.minY + 100)])
        let originalID = view.annotations[0].id
        keyDown(8, characters: "c", in: window, view: view, modifierFlags: [.command, .shift])
        keyDown(9, characters: "v", in: window, view: view, modifierFlags: [.command, .shift])
        let expected = CGRect(x: 62, y: 62, width: 200, height: 100)
        guard view.annotations.count == 2,
              view.annotations[0].id == originalID,
              view.annotations[1].id != originalID,
              case .rect(let pasted) = view.annotations[1].shape,
              pasted == expected else {
            fail("COPY-PASTE", "粘贴后 annotations=\(view.annotations) 期望新矩形 \(expected)")
            endSession()
            return
        }
        pass("COPY-PASTE", "⌘⇧C/⌘⇧V 粘贴出新 id 矩形 \(pasted)，原形状不动")
        endSession()
    }

    /// Control 拖动：复制一份再移动副本，原形状留在原位。
    private func runControlDragCopy() {
        guard let (window, view) = beginSession("CTRL-DRAG") else { return }
        drag(view, window: window, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 700, y: 600))
        let selection = view.selectionRect
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 50, y: selection.minY + 50),
            CGPoint(x: selection.minX + 250, y: selection.minY + 150),
        ])
        guard view.annotations.count == 1, tapSelect(view, id: "CTRL-DRAG") else {
            fail("CTRL-DRAG", "前置画矩形或切选择工具失败 annotations=\(view.annotations.count)")
            endSession()
            return
        }
        let originalID = view.annotations[0].id
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 100, y: selection.minY + 100),
            CGPoint(x: selection.minX + 160, y: selection.minY + 130),
        ], modifierFlags: .control)
        let expectedOriginal = CGRect(x: 50, y: 50, width: 200, height: 100)
        let expectedCopy = CGRect(x: 110, y: 80, width: 200, height: 100)
        guard view.annotations.count == 2,
              view.annotations[0].id == originalID,
              case .rect(let original) = view.annotations[0].shape,
              original == expectedOriginal,
              case .rect(let copy) = view.annotations[1].shape,
              copy == expectedCopy else {
            fail("CTRL-DRAG", "Control 拖动后 annotations=\(view.annotations) 期望原 \(expectedOriginal) 副本 \(expectedCopy)")
            endSession()
            return
        }
        pass("CTRL-DRAG", "副本移到 \(copy)，原形状保持 \(original)")
        endSession()
    }

    /// 框选多选、Shift 增删、整组拖动 / 删除 / 一次撤销恢复。
    private func runMultiSelect() {
        guard let (window, view) = beginSession("MULTI-SELECT") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 600))
        let selection = view.selectionRect
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: selection.minX + x, y: selection.minY + y)
        }
        let firstRect = CGRect(x: 40, y: 40, width: 100, height: 80)
        let secondRect = CGRect(x: 250, y: 40, width: 100, height: 80)
        press(view, window: window, path: [point(40, 40), point(140, 120)])
        press(view, window: window, path: [point(250, 40), point(350, 120)])
        guard view.annotations.count == 2,
              tapSelect(view, id: "MULTI-MARQUEE"),
              let canvas = view.subviews.compactMap({ $0 as? AnnotationCanvas }).first else {
            fail("MULTI-MARQUEE", "前置画两个矩形或切选择工具失败 annotations=\(view.annotations.count)")
            endSession()
            return
        }
        let firstID = view.annotations[0].id
        let secondID = view.annotations[1].id

        press(view, window: window, path: [point(20, 20), point(380, 160)])
        guard canvas.selectedIDs == [firstID, secondID] else {
            fail("MULTI-MARQUEE", "框选后 selectedIDs=\(canvas.selectedIDs) 期望两个矩形")
            endSession()
            return
        }
        pass("MULTI-MARQUEE", "框选相交两个矩形，canvas.selectedIDs 数量为 2")

        press(view, window: window, path: [point(90, 80)], modifierFlags: .shift)
        guard canvas.selectedIDs == [secondID] else {
            fail("MULTI-SHIFT-CLICK", "Shift 点第一个后 selectedIDs=\(canvas.selectedIDs)")
            endSession()
            return
        }
        press(view, window: window, path: [point(90, 80)], modifierFlags: .shift)
        guard canvas.selectedIDs == [firstID, secondID] else {
            fail("MULTI-SHIFT-CLICK", "再次 Shift 点第一个后 selectedIDs=\(canvas.selectedIDs)")
            endSession()
            return
        }
        pass("MULTI-SHIFT-CLICK", "Shift 点击可移除与追加单个标注")

        press(view, window: window, path: [point(400, 300)])
        guard canvas.selectedIDs.isEmpty else {
            fail("MULTI-SHIFT-MARQUEE", "空白单击后 selectedIDs=\(canvas.selectedIDs) 应为空")
            endSession()
            return
        }
        press(view, window: window, path: [point(20, 20), point(160, 140)], modifierFlags: .shift)
        guard canvas.selectedIDs == [firstID] else {
            fail("MULTI-SHIFT-MARQUEE", "Shift 框选第一个后 selectedIDs=\(canvas.selectedIDs)")
            endSession()
            return
        }
        press(view, window: window, path: [point(240, 20), point(380, 160)], modifierFlags: .shift)
        guard canvas.selectedIDs == [firstID, secondID] else {
            fail("MULTI-SHIFT-MARQUEE", "Shift 追加框选第二个后 selectedIDs=\(canvas.selectedIDs)")
            endSession()
            return
        }
        pass("MULTI-SHIFT-MARQUEE", "Shift 拖动空白在已有集合上追加框选")

        press(view, window: window, path: [point(90, 80), point(120, 110)])
        let movedFirst = firstRect.offsetBy(dx: 30, dy: 30)
        let movedSecond = secondRect.offsetBy(dx: 30, dy: 30)
        guard case .rect(let firstMoved) = view.annotations[0].shape,
              case .rect(let secondMoved) = view.annotations[1].shape,
              firstMoved == movedFirst,
              secondMoved == movedSecond else {
            fail("MULTI-DRAG", "拖动后 annotations=\(view.annotations) 期望 \(movedFirst) / \(movedSecond)")
            endSession()
            return
        }
        pass("MULTI-DRAG", "拖动任一选中标注，两个矩形同步平移 (30,30)")

        keyDown(6, characters: "z", in: window, view: view, modifierFlags: .command)
        guard case .rect(let undoneFirst) = view.annotations[0].shape,
              case .rect(let undoneSecond) = view.annotations[1].shape,
              undoneFirst == firstRect,
              undoneSecond == secondRect else {
            fail("MULTI-DRAG-UNDO", "一次 ⌘Z 后 annotations=\(view.annotations) 应回到原位")
            endSession()
            return
        }
        keyDown(6, characters: "z", in: window, view: view, modifierFlags: [.command, .shift])
        guard case .rect(let redoneFirst) = view.annotations[0].shape,
              case .rect(let redoneSecond) = view.annotations[1].shape,
              redoneFirst == movedFirst,
              redoneSecond == movedSecond else {
            fail("MULTI-DRAG-UNDO", "⌘⇧Z 后 annotations=\(view.annotations) 应回到平移后")
            endSession()
            return
        }
        pass("MULTI-DRAG-UNDO", "整组一次拖动只占一步撤销，重做同样整组恢复")

        keyDown(51, characters: "\u{7f}", in: window, view: view)
        guard view.annotations.isEmpty else {
            fail("MULTI-DELETE-UNDO", "Delete 后应清空，实际 \(view.annotations.count)")
            endSession()
            return
        }
        keyDown(6, characters: "z", in: window, view: view, modifierFlags: .command)
        guard view.annotations.count == 2,
              case .rect(let restoredFirst) = view.annotations[0].shape,
              case .rect(let restoredSecond) = view.annotations[1].shape,
              restoredFirst == movedFirst,
              restoredSecond == movedSecond else {
            fail("MULTI-DELETE-UNDO", "一次撤销后 annotations=\(view.annotations)")
            endSession()
            return
        }
        pass("MULTI-DELETE-UNDO", "Delete 删除整组，一次 ⌘Z 恢复两个矩形")
        endSession()
    }

    /// 整组复制粘贴与 Control 拖动克隆。
    private func runMultiCopyClone() {
        guard let (window, view) = beginSession("MULTI-COPY") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 600))
        let selection = view.selectionRect
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: selection.minX + x, y: selection.minY + y)
        }
        let firstRect = CGRect(x: 40, y: 40, width: 100, height: 80)
        let secondRect = CGRect(x: 300, y: 40, width: 100, height: 80)
        press(view, window: window, path: [point(40, 40), point(140, 120)])
        press(view, window: window, path: [point(300, 40), point(400, 120)])
        guard view.annotations.count == 2,
              tapSelect(view, id: "MULTI-COPY-PASTE"),
              let canvas = view.subviews.compactMap({ $0 as? AnnotationCanvas }).first else {
            fail("MULTI-COPY-PASTE", "前置画两个矩形或切选择工具失败 annotations=\(view.annotations.count)")
            endSession()
            return
        }
        press(view, window: window, path: [point(20, 20), point(420, 160)])
        guard canvas.selectedIDs.count == 2 else {
            fail("MULTI-COPY-PASTE", "框选后 selectedIDs=\(canvas.selectedIDs)")
            endSession()
            return
        }
        keyDown(8, characters: "c", in: window, view: view, modifierFlags: [.command, .shift])
        keyDown(9, characters: "v", in: window, view: view, modifierFlags: [.command, .shift])
        let pastedFirst = firstRect.offsetBy(dx: 12, dy: 12)
        let pastedSecond = secondRect.offsetBy(dx: 12, dy: 12)
        guard view.annotations.count == 4,
              case .rect(let pastedA) = view.annotations[2].shape,
              case .rect(let pastedB) = view.annotations[3].shape,
              pastedA == pastedFirst,
              pastedB == pastedSecond,
              canvas.selectedIDs == [view.annotations[2].id, view.annotations[3].id] else {
            fail("MULTI-COPY-PASTE", "粘贴后 annotations=\(view.annotations) selectedIDs=\(canvas.selectedIDs)")
            endSession()
            return
        }
        pass("MULTI-COPY-PASTE", "⌘⇧C/⌘⇧V 整组粘贴出两个新矩形，整体偏移 (12,12)")

        press(view, window: window, path: [point(102, 92), point(122, 112)], modifierFlags: .control)
        let cloneFirst = pastedFirst.offsetBy(dx: 20, dy: 20)
        let cloneSecond = pastedSecond.offsetBy(dx: 20, dy: 20)
        guard view.annotations.count == 6,
              case .rect(let keptA) = view.annotations[2].shape,
              case .rect(let keptB) = view.annotations[3].shape,
              case .rect(let cloneA) = view.annotations[4].shape,
              case .rect(let cloneB) = view.annotations[5].shape,
              keptA == pastedFirst,
              keptB == pastedSecond,
              cloneA == cloneFirst,
              cloneB == cloneSecond else {
            fail("MULTI-CTRL-CLONE", "Control 拖动后 annotations=\(view.annotations)")
            endSession()
            return
        }
        pass("MULTI-CTRL-CLONE", "Control 拖动整组克隆，原组不动，副本整体平移 (20,20)")
        endSession()
    }

    // MARK: - Snipaste 节奏（自动选中 / 右键）

    /// 画完形状立即选中，文字提交同样自动选中。
    private func runAutoSelectOnCreate() {
        guard let (window, view) = beginSession("AUTO-SELECT") else { return }
        drag(view, window: window, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 600, y: 500))
        let selection = view.selectionRect
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 50, y: selection.minY + 50),
            CGPoint(x: selection.minX + 250, y: selection.minY + 150),
        ])
        guard view.annotations.count == 1,
              let canvas = view.subviews.compactMap({ $0 as? AnnotationCanvas }).first else {
            fail("AUTO-SELECT", "前置画矩形失败 annotations=\(view.annotations.count)")
            endSession()
            return
        }
        let shapeID = view.annotations[0].id
        if canvas.selectedIDs == [shapeID] {
            pass("AUTO-SELECT", "画完后 canvas.selectedIDs 等于新标注 \(shapeID)")
        } else {
            fail("AUTO-SELECT", "selectedIDs=\(canvas.selectedIDs) 期望 [\(shapeID)]")
        }

        guard tapTool(view, .text, id: "AUTO-SELECT-TEXT") else {
            endSession()
            return
        }
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 60, y: selection.minY + 250),
        ])
        guard let editor = view.subviews.compactMap({ $0 as? NSTextView }).first else {
            fail("AUTO-SELECT-TEXT", "单击后没有出现文字编辑器")
            endSession()
            return
        }
        editor.string = "Auto"
        sendKey(36, characters: "\r", to: editor, in: window, modifierFlags: .command)
        guard view.annotations.count == 2 else {
            fail("AUTO-SELECT-TEXT", "文字未入列 annotations=\(view.annotations.count)")
            endSession()
            return
        }
        let textID = view.annotations[1].id
        if canvas.selectedIDs == [textID] {
            pass("AUTO-SELECT-TEXT", "文字提交后 canvas.selectedIDs 等于新标注 \(textID)")
        } else {
            fail("AUTO-SELECT-TEXT", "selectedIDs=\(canvas.selectedIDs) 期望 [\(textID)]")
        }
        endSession()
    }

    /// 选中态下在选区另一处直接落笔：画出第二条，第一笔留在原位且不再选中。
    private func runDrawAgainAfterAutoSelect() {
        guard let (window, view) = beginSession("AUTO-SELECT-REDRAW") else { return }
        drag(view, window: window, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 700, y: 600))
        let selection = view.selectionRect
        let firstRect = CGRect(x: 50, y: 50, width: 150, height: 100)
        let secondRect = CGRect(x: 250, y: 50, width: 150, height: 100)
        press(view, window: window, path: [
            CGPoint(x: selection.minX + firstRect.minX, y: selection.minY + firstRect.minY),
            CGPoint(x: selection.minX + firstRect.maxX, y: selection.minY + firstRect.maxY),
        ])
        guard view.annotations.count == 1,
              let canvas = view.subviews.compactMap({ $0 as? AnnotationCanvas }).first else {
            fail("AUTO-SELECT-REDRAW", "前置画矩形失败 annotations=\(view.annotations.count)")
            endSession()
            return
        }
        let firstID = view.annotations[0].id
        press(view, window: window, path: [
            CGPoint(x: selection.minX + secondRect.minX, y: selection.minY + secondRect.minY),
            CGPoint(x: selection.minX + secondRect.maxX, y: selection.minY + secondRect.maxY),
        ])
        guard view.annotations.count == 2,
              view.annotations[0].id == firstID,
              case .rect(let kept) = view.annotations[0].shape,
              kept == firstRect,
              canvas.selectedIDs == [view.annotations[1].id] else {
            fail("AUTO-SELECT-REDRAW", "annotations=\(view.annotations.count) 第一条=\(String(describing: view.annotations.first?.shape)) selectedIDs=\(canvas.selectedIDs)")
            endSession()
            return
        }
        pass("AUTO-SELECT-REDRAW", "第二条矩形已画出，第一条保持 \(kept) 且选中已转移")
        endSession()
    }

    /// 右键取消截图：覆盖窗口全部关闭。
    private func runRightClickCancels() {
        guard let (window, view) = beginSession("RIGHT-CLICK-CANCEL") else { return }
        drag(view, window: window, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 600, y: 500))
        rightClick(view, window: window, at: CGPoint(x: 300, y: 300))
        if visibleOverlayWindows.isEmpty {
            pass("RIGHT-CLICK-CANCEL", "选区确定后右键取消，覆盖窗口已全部关闭")
        } else {
            fail("RIGHT-CLICK-CANCEL", "右键后仍有 \(visibleOverlayWindows.count) 个可见覆盖窗口")
        }
    }

    /// 绘制中右键结束当前笔画并提交，截图不取消。
    private func runRightClickFinishesStroke() {
        guard let (window, view) = beginSession("RIGHT-CLICK-DRAW") else { return }
        drag(view, window: window, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 700, y: 600))
        let selection = view.selectionRect
        let start = CGPoint(x: selection.minX + 50, y: selection.minY + 50)
        let end = CGPoint(x: selection.minX + 250, y: selection.minY + 150)
        if let down = mouseEvent(.leftMouseDown, at: start, in: window) {
            view.mouseDown(with: down)
        }
        if let dragged = mouseEvent(.leftMouseDragged, at: end, in: window) {
            view.mouseDragged(with: dragged)
        }
        rightClick(view, window: window, at: end)
        let expected = CGRect(x: 50, y: 50, width: 200, height: 100)
        guard !visibleOverlayWindows.isEmpty,
              view.annotations.count == 1,
              case .rect(let rect) = view.annotations[0].shape,
              rect == expected else {
            fail("RIGHT-CLICK-DRAW", "右键结束笔画后 annotations=\(view.annotations) 窗口数=\(visibleOverlayWindows.count)")
            endSession()
            return
        }
        pass("RIGHT-CLICK-DRAW", "右键提交矩形 \(rect)，截图会话保留")
        endSession()
    }

    // MARK: - 折线 / Tab / 滚轮 / 透明度

    private func runPolylineTool() {
        guard let (window, view) = beginSession("POLYLINE") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 600))
        let selection = view.selectionRect
        guard tapTool(view, .polyline, id: "POLYLINE") else {
            endSession()
            return
        }
        guard let bar = view.subviews.compactMap({ $0 as? AnnotateToolbar }).first else {
            fail("POLYLINE-ICON", "找不到工具条")
            endSession()
            return
        }
        if bar.toolButtons[.polyline]?.image != nil {
            pass("POLYLINE-ICON", "折线按钮有 SF Symbol 图标")
        } else {
            fail("POLYLINE-ICON", "折线按钮 image 为 nil，符号名不存在")
        }

        for point in [CGPoint(x: 60, y: 80), CGPoint(x: 200, y: 220), CGPoint(x: 340, y: 90)] {
            press(view, window: window, path: [
                CGPoint(x: selection.minX + point.x, y: selection.minY + point.y),
            ])
        }
        guard view.annotations.isEmpty else {
            fail("POLYLINE", "点按阶段不应提交，已有 \(view.annotations.count) 条标注")
            endSession()
            return
        }
        keyDown(36, characters: "\r", in: window, view: view)
        guard let last = view.annotations.last,
              case .polyline(let points) = last.shape,
              points.count == 3 else {
            fail("POLYLINE", "提交后应为 3 点折线，实际 \(String(describing: view.annotations.last?.shape))")
            endSession()
            return
        }
        pass("POLYLINE", "三次点按加 Enter 提交为 3 点折线")

        // 拖拽路径：与直线一致，松开即提交
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 400, y: selection.minY + 300),
            CGPoint(x: selection.minX + 520, y: selection.minY + 380),
        ])
        guard let dragged = view.annotations.last,
              case .polyline(let dragPoints) = dragged.shape,
              dragPoints.count >= 2 else {
            fail("POLYLINE", "拖拽后应提交折线，实际 \(String(describing: view.annotations.last?.shape))")
            endSession()
            return
        }
        pass("POLYLINE", "拖拽松开后按折线提交 \(dragPoints.count) 点")
        endSession()
    }

    private func runTabTogglesLineArrow() {
        guard let (window, view) = beginSession("TAB") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 600))
        guard tapTool(view, .line, id: "TAB"),
              let bar = view.subviews.compactMap({ $0 as? AnnotateToolbar }).first else {
            endSession()
            return
        }
        keyDown(48, characters: "\t", in: window, view: view)
        guard bar.selectedKind == .arrow else {
            fail("TAB", "从直线按 Tab 应切到箭头，实际 \(bar.selectedKind.rawValue)")
            endSession()
            return
        }
        pass("TAB", "直线按 Tab 切到箭头，工具条高亮同步")

        keyDown(48, characters: "\t", in: window, view: view)
        guard bar.selectedKind == .line else {
            fail("TAB", "再按 Tab 应切回直线，实际 \(bar.selectedKind.rawValue)")
            endSession()
            return
        }
        pass("TAB", "再按 Tab 切回直线")
        endSession()
    }

    private func runWheelPenSize() {
        guard let (window, view) = beginSession("WHEEL") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 600))
        let selection = view.selectionRect
        guard tapTool(view, .brush, id: "WHEEL"),
              let bar = view.subviews.compactMap({ $0 as? AnnotateToolbar }).first else {
            endSession()
            return
        }
        let before = bar.currentStyle.pen
        scroll(view, wheel1: 10)
        let after = bar.currentStyle.pen
        guard after.rawValue == before.rawValue + 1 else {
            fail("WHEEL", "向上滚应加粗一档，\(before.rawValue) → \(after.rawValue)")
            endSession()
            return
        }
        pass("WHEEL", "滚轮一档 \(before.rawValue) → \(after.rawValue)")

        press(view, window: window, path: [
            CGPoint(x: selection.minX + 60, y: selection.minY + 60),
            CGPoint(x: selection.minX + 240, y: selection.minY + 60),
        ])
        guard view.annotations.last?.style.pen == after else {
            fail("WHEEL", "标注未使用滚轮后的笔宽 \(String(describing: view.annotations.last?.style.pen))")
            endSession()
            return
        }
        pass("WHEEL", "新标注写入滚轮后的笔宽")
        endSession()
    }

    private func runAlphaTransparency() {
        guard let (window, view) = beginSession("ALPHA") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 600))
        let selection = view.selectionRect
        guard tapTool(view, .line, id: "ALPHA") else {
            endSession()
            return
        }
        func drawLine(canvasY: CGFloat) {
            press(view, window: window, path: [
                CGPoint(x: selection.minX + 60, y: selection.minY + canvasY),
                CGPoint(x: selection.minX + 380, y: selection.minY + canvasY),
            ])
        }
        drawLine(canvasY: 200)
        guard pickAlpha(view, 3, id: "ALPHA"),
              let bar = view.subviews.compactMap({ $0 as? AnnotateToolbar }).first else {
            endSession()
            return
        }
        guard abs(bar.currentStyle.color.a - 0.4) < 0.001 else {
            fail("ALPHA", "选 40% 后工具条 alpha 应为 0.4，实际 \(bar.currentStyle.color.a)")
            endSession()
            return
        }
        drawLine(canvasY: 300)

        NSPasteboard.general.clearContents()
        keyDown(36, characters: "\r", in: window, view: view)
        guard let image = pasteboardImage(),
              let bytes = srgbBytes(image, width: image.width, height: image.height) else {
            fail("ALPHA", "剪贴板没有可读图像")
            endSession()
            return
        }
        let px = Int(view.shot.scale)
        func pixel(canvasX: Int, canvasY: Int) -> (r: Int, g: Int, b: Int) {
            let x = canvasX * px
            let y = image.height - 1 - canvasY * px
            let offset = (y * image.width + x) * 4
            return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
        }
        // 导出底图不透明，alpha 在这里表现为与底色的混色差；真实 alpha 通道由单测断言。
        let opaque = pixel(canvasX: 220, canvasY: 200)
        let faded = pixel(canvasX: 220, canvasY: 300)
        let difference = abs(faded.r - opaque.r) + abs(faded.g - opaque.g) + abs(faded.b - opaque.b)
        guard difference > 60 else {
            fail("ALPHA", "40% 与不透明像素几乎一致，混色差 \(difference) opaque=\(opaque) faded=\(faded)")
            endSession()
            return
        }
        pass("ALPHA", "40% 导出像素明显混入底色，混色差 \(difference) opaque=\(opaque) faded=\(faded)")
        endSession()
    }

    private func runDigitPenSize() {
        guard let (window, view) = beginSession("DIGIT-PEN") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 600))
        guard tapTool(view, .rect, id: "DIGIT-PEN"),
              let bar = view.subviews.compactMap({ $0 as? AnnotateToolbar }).first else {
            endSession()
            return
        }
        keyDown(18, characters: "1", in: window, view: view)
        guard bar.currentStyle.pen == .p1 else {
            fail("DIGIT-PEN", "数字键 1 应选 p1，实际 \(bar.currentStyle.pen)")
            endSession()
            return
        }
        keyDown(23, characters: "5", in: window, view: view)
        guard bar.currentStyle.pen == .p5 else {
            fail("DIGIT-PEN", "数字键 5 应选 p5，实际 \(bar.currentStyle.pen)")
            endSession()
            return
        }
        pass("DIGIT-PEN", "数字键 1/5 切换笔尖档位")
        endSession()
    }

    private func runColorWheelAlpha() {
        guard let (window, view) = beginSession("COLOR-WHEEL") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 600))
        guard tapTool(view, .line, id: "COLOR-WHEEL"),
              let bar = view.subviews.compactMap({ $0 as? AnnotateToolbar }).first,
              pickAlpha(view, 3, id: "COLOR-WHEEL") else {
            endSession()
            return
        }
        scroll(bar.colorButton, wheel1: 10)
        guard abs(bar.currentStyle.color.a - 0.6) < 0.001 else {
            fail("COLOR-WHEEL", "上滚应到 60%，实际 \(bar.currentStyle.color.a)")
            endSession()
            return
        }
        pass("COLOR-WHEEL", "颜色按钮上滚一档 40% → 60%")
        endSession()
    }

    private func runPaletteCustomization() {
        guard let (window, view) = beginSession("PALETTE") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 600))
        guard let bar = view.subviews.compactMap({ $0 as? AnnotateToolbar }).first else {
            fail("PALETTE", "找不到工具条")
            endSession()
            return
        }
        // 走真实偏好路径，结束后把原数据放回去，避免测试色留在用户调色板里。
        let defaults = UserDefaults.standard
        let backup = defaults.data(forKey: PaletteStore.defaultsKey)
        defer {
            if let backup {
                defaults.set(backup, forKey: PaletteStore.defaultsKey)
            } else {
                defaults.removeObject(forKey: PaletteStore.defaultsKey)
            }
            endSession()
        }

        bar.colorButton.performClick(nil)
        pump(0.2)
        guard let palette = bar.colorPopover?.contentViewController?.view as? ColorPaletteView else {
            fail("PALETTE", "颜色弹层未弹出")
            return
        }
        guard palette.customButton != nil,
              palette.exportButton != nil,
              palette.importButton != nil,
              palette.resetButton != nil else {
            fail("PALETTE", "弹层缺少自定义 / 导出 / 导入 / 恢复默认入口")
            return
        }
        pass("PALETTE-BUTTONS", "弹层含自定义、导出、导入、恢复默认入口")

        let custom = RGBAColor(r: 0.13, g: 0.42, b: 0.77, a: 0.6)
        palette.addCustomColor(custom)
        pump(0.1)
        guard bar.currentStyle.color == custom else {
            fail("PALETTE-APPLY", "颜色面板选色后应为该自定义色（含 alpha），实际 \(bar.currentStyle.color)")
            return
        }

        guard let customIndex = palette.swatches.indices.first(where: { palette.model.isCustom(at: $0) }) else {
            fail("PALETTE-PICK", "自定义色没有出现在色块网格里")
            return
        }
        palette.swatches[0].performClick(nil)
        pump(0.1)
        guard bar.currentStyle.color != custom else {
            fail("PALETTE-PICK", "点内置色后颜色没有变化")
            return
        }
        palette.swatches[customIndex].performClick(nil)
        pump(0.1)
        guard bar.currentStyle.color == custom else {
            fail("PALETTE-PICK", "点自定义色块后 currentStyle.color 应为该色，实际 \(bar.currentStyle.color)")
            return
        }
        pass("PALETTE-PICK", "点自定义色块后 currentStyle.color 变为该色（含 alpha 0.6）")

        guard PaletteStore().load().customColors.contains(custom) else {
            fail("PALETTE-PERSIST", "自定义色没有写入偏好")
            return
        }
        pass("PALETTE-PERSIST", "自定义色已写入 UserDefaults")
    }

    // MARK: - 主流程

    private func runMagnifierAndColorSampling() {
        guard let (window, view) = beginSession("MAGNIFIER") else { return }
        let probe = CGPoint(x: 300, y: 300)
        if let moved = mouseEvent(.mouseMoved, at: probe, in: window) {
            view.mouseMoved(with: moved)
        }
        flagsChanged([.option], in: window, view: view)
        if view.isMagnifierVisible {
            pass("MAGNIFIER-OPTION", "Option 按下后放大镜可见")
        } else {
            fail("MAGNIFIER-OPTION", "Option 按下后放大镜仍不可见")
        }

        // 拖选区自动召唤：松开 Option 后按压并拖动。
        flagsChanged([], in: window, view: view)
        let dragStart = CGPoint(x: 200, y: 200)
        let dragEnd = CGPoint(x: 400, y: 360)
        if let down = mouseEvent(.leftMouseDown, at: dragStart, in: window) {
            view.mouseDown(with: down)
        }
        if let dragged = mouseEvent(.leftMouseDragged, at: dragEnd, in: window) {
            view.mouseDragged(with: dragged)
        }
        if view.isMagnifierVisible {
            pass("MAGNIFIER-DRAG", "拖动选区时放大镜自动出现")
        } else {
            fail("MAGNIFIER-DRAG", "拖动选区时放大镜没有出现")
        }
        if let up = mouseEvent(.leftMouseUp, at: dragEnd, in: window) {
            view.mouseUp(with: up)
        }
        pump(0.15)
        if view.isMagnifierVisible {
            fail("MAGNIFIER-DRAG", "松开鼠标且未按 Option 时放大镜应隐藏")
        } else {
            pass("MAGNIFIER-DRAG", "松开鼠标后放大镜隐藏")
        }

        // Option 召唤后取色，默认 Hex。
        if let moved = mouseEvent(.mouseMoved, at: probe, in: window) {
            view.mouseMoved(with: moved)
        }
        flagsChanged([.option], in: window, view: view)
        NSPasteboard.general.clearContents()
        keyDown(8, characters: "c", in: window, view: view)
        let hex = NSPasteboard.general.string(forType: .string)
        if let hex, hex.range(of: "^#[0-9A-F]{6}$", options: .regularExpression) != nil {
            pass("MAGNIFIER-COLOR-HEX", "剪贴板 \(hex) 符合 Hex 格式")
        } else {
            fail("MAGNIFIER-COLOR-HEX", "剪贴板内容 \(hex ?? "nil") 不是 Hex")
        }

        // Shift 切换格式后再按 C。
        flagsChanged([.option, .shift], in: window, view: view)
        NSPasteboard.general.clearContents()
        keyDown(8, characters: "c", in: window, view: view, modifierFlags: [.option, .shift])
        let rgb = NSPasteboard.general.string(forType: .string)
        if let rgb, rgb.range(
            of: "^rgb\\(\\d{1,3}, \\d{1,3}, \\d{1,3}\\)$",
            options: .regularExpression
        ) != nil {
            pass("MAGNIFIER-COLOR-RGB", "剪贴板 \(rgb) 符合 rgb() 格式")
        } else {
            fail("MAGNIFIER-COLOR-RGB", "剪贴板内容 \(rgb ?? "nil") 不是 rgb()")
        }

        capture("p2-magnifier.png")
        endSession()
    }

    /// 方向键整体平移，Control 扩大，Shift 缩小。
    private func runArrowNudge() {
        guard let (window, view) = beginSession("ARROW-NUDGE") else { return }
        drag(view, window: window, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 700, y: 600))

        let moved = view.selectionRect
        keyDown(124, characters: "\u{F703}", in: window, view: view)
        let afterMove = view.selectionRect
        guard afterMove == CGRect(
            x: moved.minX + 1, y: moved.minY, width: moved.width, height: moved.height
        ) else {
            fail("ARROW-NUDGE", "右方向键后 \(afterMove)，期望 \(moved) 平移 1pt")
            endSession()
            return
        }

        let beforeExpand = view.selectionRect
        keyDown(126, characters: "\u{F700}", in: window, view: view, modifierFlags: .control)
        let afterExpand = view.selectionRect
        guard afterExpand == CGRect(
            x: beforeExpand.minX,
            y: beforeExpand.minY,
            width: beforeExpand.width,
            height: beforeExpand.height + 1
        ) else {
            fail("ARROW-EXPAND", "Ctrl+上后 \(afterExpand)，期望高度 +1")
            endSession()
            return
        }

        let beforeShrink = view.selectionRect
        keyDown(124, characters: "\u{F703}", in: window, view: view, modifierFlags: .shift)
        let afterShrink = view.selectionRect
        guard afterShrink == CGRect(
            x: beforeShrink.minX,
            y: beforeShrink.minY,
            width: beforeShrink.width - 1,
            height: beforeShrink.height
        ) else {
            fail("ARROW-SHRINK", "Shift+右后 \(afterShrink)，期望宽度 -1")
            endSession()
            return
        }

        pass("ARROW-NUDGE", "方向键平移、Ctrl 扩大、Shift 缩小均按 1pt 生效")
        endSession()
    }

    /// 成功复制写入历史；新会话按 . 切到历史，按 , 翻回当前。
    private func runHistoryReplay() {
        guard let (window, view) = beginSession("HISTORY") else { return }
        drag(view, window: window, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 700, y: 600))
        keyDown(36, characters: "\r", in: window, view: view)
        pump(0.4)
        guard controller.historyCount == 1 else {
            fail("HISTORY-RECORD", "复制后历史数 \(controller.historyCount)，期望 1")
            endSession()
            return
        }

        guard let (replayWindow, replayView) = beginSession("HISTORY-REPLAY") else { return }
        guard replayView.historyIndex == 0 else {
            fail("HISTORY-REPLAY", "新会话直接处于历史 \(replayView.historyIndex)")
            endSession()
            return
        }
        keyDown(47, characters: ".", in: replayWindow, view: replayView)
        guard replayView.historyIndex == 1, replayView.selectionRect.isEmpty else {
            fail(
                "HISTORY-REPLAY",
                "按 . 后 index=\(replayView.historyIndex) selection=\(replayView.selectionRect)"
            )
            endSession()
            return
        }
        capture("p2-history-replay.png")

        keyDown(43, characters: ",", in: replayWindow, view: replayView)
        guard replayView.historyIndex == 0 else {
            fail("HISTORY-BACK", "按 , 后 index=\(replayView.historyIndex)，期望回到 0")
            endSession()
            return
        }

        pass("HISTORY-REPLAY", "复制后历史数 1，. 切到历史并重置选区，, 翻回当前")
        endSession()
    }

    /// 序号工具：连续放置自动递增；删除已放序号后新号不回收，撤销可恢复。
    private func runSerialTool() {
        guard let (window, view) = beginSession("SERIAL") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 600))
        let selection = view.selectionRect
        guard tapTool(view, .serial, id: "SERIAL") else {
            endSession()
            return
        }
        press(view, window: window, path: [CGPoint(x: selection.minX + 80, y: selection.minY + 100)])
        press(view, window: window, path: [CGPoint(x: selection.minX + 240, y: selection.minY + 260)])
        let values = view.annotations.compactMap { annotation -> Int? in
            guard case .serial(let value, _, _) = annotation.shape else { return nil }
            return value
        }
        guard view.annotations.count == 2, values == [1, 2] else {
            fail("SERIAL-COUNT", "两个序号值 \(values)，标注数 \(view.annotations.count)")
            endSession()
            return
        }
        pass("SERIAL-COUNT", "连续放置两个序号，值为 1/2")

        // 选中第一个序号并删除，再放新序号：编号应为 3 而不是复用 1。
        guard tapSelect(view, id: "SERIAL-COUNTER") else { return }
        let firstCenter = CGPoint(x: selection.minX + 80, y: selection.minY + 100)
        press(view, window: window, path: [firstCenter])
        keyDown(51, characters: "\u{7f}", in: window, view: view)
        guard view.annotations.count == 1 else {
            fail("SERIAL-COUNTER", "删除第一个序号后应剩 1 条，实际 \(view.annotations.count)")
            endSession()
            return
        }
        tapTool(view, .serial, id: "SERIAL-COUNTER")
        press(view, window: window, path: [CGPoint(x: selection.minX + 400, y: selection.minY + 220)])
        let afterDelete = view.annotations.compactMap { annotation -> Int? in
            guard case .serial(let value, _, _) = annotation.shape else { return nil }
            return value
        }
        guard afterDelete == [2, 3] else {
            fail("SERIAL-COUNTER", "删除后新序号值 \(afterDelete)，期望 [2, 3]")
            endSession()
            return
        }
        keyDown(6, characters: "z", in: window, view: view, modifierFlags: .command)
        guard view.annotations.count == 1 else {
            fail("SERIAL-COUNTER", "撤销放置后应回到 1 条，实际 \(view.annotations.count)")
            endSession()
            return
        }
        keyDown(6, characters: "z", in: window, view: view, modifierFlags: .command)
        let restored = view.annotations.compactMap { annotation -> Int? in
            guard case .serial(let value, _, _) = annotation.shape else { return nil }
            return value
        }
        guard restored == [1, 2] else {
            fail("SERIAL-COUNTER", "第二次撤销应恢复被删序号，实际 \(restored)")
            endSession()
            return
        }
        pass("SERIAL-COUNTER", "删除不回收编号，撤销放置回退一步，再撤销恢复被删序号")
        endSession()
    }

    /// 模糊工具：导出像素与底图不同、区域内更平滑、区域外完全一致。
    private func runBlurTool() {
        guard let (window, view) = beginSession("BLUR") else { return }
        // 菜单栏是屏幕上固定的高纹理区域，模糊前后方差对比稳定。
        let top = view.bounds.height
        drag(view, window: window, from: CGPoint(x: 100, y: top - 360), to: CGPoint(x: 700, y: top))
        let selection = view.selectionRect
        guard selection.width >= 400, selection.height >= 300 else {
            fail("BLUR", "选区异常 \(selection)")
            endSession()
            return
        }
        guard let before = exportedBytes(view) else {
            fail("BLUR", "底图导出失败")
            endSession()
            return
        }
        guard tapTool(view, .blur, id: "BLUR") else {
            endSession()
            return
        }
        keyDown(23, characters: "5", in: window, view: view)
        let canvasY = Int(selection.height) - 12
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 40, y: selection.minY + CGFloat(canvasY)),
            CGPoint(x: selection.minX + 520, y: selection.minY + CGFloat(canvasY)),
        ])
        guard view.annotations.count == 1, case .blur = view.annotations[0].shape else {
            fail("BLUR", "模糊标注未入列 annotations=\(view.annotations.count)")
            endSession()
            return
        }
        guard let after = exportedBytes(view) else {
            fail("BLUR", "模糊后导出失败")
            endSession()
            return
        }

        let scale = view.shot.scale
        let imageWidth = Int(selection.width * scale)
        let imageHeight = Int(selection.height * scale)
        guard before.count == after.count, imageWidth > 0, imageHeight > 0 else {
            fail("BLUR", "导出尺寸不一致 before=\(before.count) after=\(after.count)")
            endSession()
            return
        }

        func exportedPixel(
            _ bytes: [UInt8], canvasX: Int, canvasY: Int
        ) -> (r: Int, g: Int, b: Int) {
            let x = min(imageWidth - 1, max(0, Int(CGFloat(canvasX) * scale)))
            let y = min(imageHeight - 1, max(0, imageHeight - 1 - Int(CGFloat(canvasY) * scale)))
            return pixelColor(bytes, x: x, y: y, width: imageWidth)
        }

        func luminanceVariance(
            _ bytes: [UInt8], xRange: ClosedRange<Int>, yRange: ClosedRange<Int>
        ) -> Double {
            var values: [Double] = []
            for canvasY in yRange {
                for canvasX in xRange {
                    let p = exportedPixel(bytes, canvasX: canvasX, canvasY: canvasY)
                    values.append(Double(p.r + p.g + p.b) / 3)
                }
            }
            let mean = values.reduce(0, +) / Double(values.count)
            return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        }

        var changed = 0
        for canvasY in (canvasY - 6)...(canvasY + 6) {
            for canvasX in 60...500 where
                exportedPixel(before, canvasX: canvasX, canvasY: canvasY)
                    != exportedPixel(after, canvasX: canvasX, canvasY: canvasY)
            {
                changed += 1
            }
        }

        // 沿笔迹取方差最高的窗口，模糊后应明显下降。
        let yRange = (canvasY - 8)...(canvasY + 8)
        var bestBefore = 0.0
        var bestAfter = 0.0
        for start in stride(from: 60, through: 460, by: 100) {
            let candidateBefore = luminanceVariance(before, xRange: start...(start + 40), yRange: yRange)
            if candidateBefore > bestBefore {
                bestBefore = candidateBefore
                bestAfter = luminanceVariance(after, xRange: start...(start + 40), yRange: yRange)
            }
        }

        // 区域外抽三条横带逐像素比对。
        var outsideMismatch = 0
        for sampleY in [canvasY - 40, canvasY - 30, canvasY - 20] {
            for canvasX in stride(from: 0, to: Int(selection.width), by: 2) where
                exportedPixel(before, canvasX: canvasX, canvasY: sampleY)
                    != exportedPixel(after, canvasX: canvasX, canvasY: sampleY)
            {
                outsideMismatch += 1
            }
        }

        guard changed > 0, bestBefore > 4, bestAfter < bestBefore * 0.8, outsideMismatch == 0 else {
            fail(
                "BLUR",
                "changed=\(changed) variance \(Int(bestBefore))→\(Int(bestAfter)) outsideMismatch=\(outsideMismatch)"
            )
            endSession()
            return
        }
        pass(
            "BLUR",
            "区域内 \(changed) 像素变化，方差 \(Int(bestBefore))→\(Int(bestAfter))，区域外一致"
        )
        endSession()
    }

    /// 橡皮擦：划过两个矩形之一，标注数 2→1；一次撤销恢复被删标注。
    private func runEraserTool() {
        guard let (window, view) = beginSession("ERASER") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 600))
        let selection = view.selectionRect
        func point(_ canvas: CGPoint) -> CGPoint {
            CGPoint(x: selection.minX + canvas.x, y: selection.minY + canvas.y)
        }
        press(view, window: window, path: [
            point(CGPoint(x: 40, y: 60)), point(CGPoint(x: 220, y: 180)),
        ])
        press(view, window: window, path: [
            point(CGPoint(x: 280, y: 60)), point(CGPoint(x: 480, y: 180)),
        ])
        guard view.annotations.count == 2 else {
            fail("ERASER", "前置画两个矩形失败 annotations=\(view.annotations.count)")
            endSession()
            return
        }
        let originalIDs = view.annotations.map(\.id)

        guard tapTool(view, .eraser, id: "ERASER") else {
            endSession()
            return
        }
        press(view, window: window, path: [
            point(CGPoint(x: 10, y: 120)), point(CGPoint(x: 250, y: 120)),
        ])
        guard view.annotations.count == 1, view.annotations[0].id == originalIDs[1] else {
            fail("ERASER", "擦除后应只剩第二个矩形 annotations=\(view.annotations.map(\.id))")
            endSession()
            return
        }

        keyDown(6, characters: "z", in: window, view: view, modifierFlags: .command)
        guard view.annotations.map(\.id) == originalIDs else {
            fail("ERASER", "撤销后应恢复两条 annotations=\(view.annotations.map(\.id))")
            endSession()
            return
        }
        pass("ERASER", "擦除命中矩形 2→1，一次撤销整组恢复为 2")
        endSession()
    }

    /// ⌘⇧Z 重做撤销过的一步；撤销后画新形状则重做栈作废。
    private func runRedo() {
        guard let (window, view) = beginSession("REDO") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 600))
        let selection = view.selectionRect
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 40, y: selection.minY + 40),
            CGPoint(x: selection.minX + 200, y: selection.minY + 120),
        ])
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 240, y: selection.minY + 40),
            CGPoint(x: selection.minX + 400, y: selection.minY + 120),
        ])
        guard view.annotations.count == 2 else {
            fail("REDO", "前置画两笔失败：\(view.annotations.count)")
            endSession()
            return
        }
        let originalIDs = view.annotations.map(\.id)

        keyDown(6, characters: "z", in: window, view: view, modifierFlags: .command)
        guard view.annotations.count == 1 else {
            fail("REDO", "⌘Z 后应剩 1 笔，实际 \(view.annotations.count)")
            endSession()
            return
        }
        keyDown(6, characters: "z", in: window, view: view, modifierFlags: [.command, .shift])
        guard view.annotations.map(\.id) == originalIDs else {
            fail("REDO", "⌘⇧Z 后应恢复两笔，实际 \(view.annotations.map(\.id))")
            endSession()
            return
        }

        keyDown(6, characters: "z", in: window, view: view, modifierFlags: .command)
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 440, y: selection.minY + 40),
            CGPoint(x: selection.minX + 600, y: selection.minY + 120),
        ])
        guard view.annotations.count == 2 else {
            fail("REDO", "撤销后新画一笔应有 2 笔，实际 \(view.annotations.count)")
            endSession()
            return
        }
        let afterNewEdit = view.annotations.map(\.id)
        keyDown(6, characters: "z", in: window, view: view, modifierFlags: [.command, .shift])
        guard view.annotations.map(\.id) == afterNewEdit else {
            fail("REDO", "新编辑后 ⌘⇧Z 不应改变标注，实际 \(view.annotations.map(\.id))")
            endSession()
            return
        }
        pass("REDO", "⌘⇧Z 恢复撤销的标注；新编辑后重做栈清空")
        endSession()
    }

    /// ⌘ + 保存按钮：不弹面板，直接写注入的快捷保存目录。
    private func runQuickSave() {
        guard let (window, view) = beginSession("QUICKSAVE") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 600))
        guard let bar = view.subviews.compactMap({ $0 as? AnnotateToolbar }).first,
              let saveButton = bar.saveButton else {
            fail("QUICKSAVE", "工具条上找不到保存按钮")
            endSession()
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yaosnap-quicksave-\(UUID().uuidString)", isDirectory: true)
        defer {
            controller.quickSaveDirectory = nil
            try? FileManager.default.removeItem(at: directory)
        }
        controller.quickSaveDirectory = directory
        saveButton.currentModifiers = { [.command] }
        saveButton.performClick(nil)
        pump(0.4)

        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let pngs = files.filter { $0.hasSuffix(".png") }
        guard pngs.count == 1 else {
            fail("QUICKSAVE", "快捷保存目录应有 1 个 PNG，实际 \(files)")
            endSession()
            return
        }
        pass("QUICKSAVE", "⌘ 点击保存写入 \(pngs[0])，未弹面板")
        endSession()
    }

    /// 提取文字 / 识别码按钮：存在性 + 二维码结果写入剪贴板。
    private func runRecognition() {
        guard let (window, view) = beginSession("RECOGNIZE-BUTTONS") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 650, y: 500))
        guard let bar = view.subviews.compactMap({ $0 as? AnnotateToolbar }).first,
              let textButton = bar.textButton,
              let barcodeButton = bar.barcodeButton else {
            fail("RECOGNIZE-BUTTONS", "工具条上找不到提取文字 / 识别码按钮")
            endSession()
            return
        }
        guard textButton.toolTip == "提取文字", barcodeButton.toolTip == "识别码",
              textButton.image != nil, barcodeButton.image != nil else {
            fail("RECOGNIZE-BUTTONS", "按钮标识不符：\(textButton.toolTip ?? "nil") / \(barcodeButton.toolTip ?? "nil")")
            endSession()
            return
        }
        pass("RECOGNIZE-BUTTONS", "工具条含提取文字 / 识别码按钮")

        let payload = "yaosnap-e2e-2026"
        guard let qr = Self.makeQRCode(payload) else {
            fail("RECOGNIZE-BARCODE", "生成二维码图像失败")
            endSession()
            return
        }
        // 走历史回放同一条提交路径注入二维码，不依赖真实屏幕内容。
        let full = CGRect(x: 0, y: 0, width: qr.width, height: qr.height)
        NotificationCenter.default.post(
            name: .snipCommitted,
            object: nil,
            userInfo: [
                SnipNotificationKey.viewRect: full,
                SnipNotificationKey.viewHeight: full.height,
                SnipNotificationKey.scale: CGFloat(1),
                SnipNotificationKey.displayID: view.shot.displayID,
                SnipNotificationKey.sourceImage: qr,
                SnipNotificationKey.cropRectPx: full,
            ]
        )
        pump(0.1)
        NSPasteboard.general.clearContents()
        barcodeButton.performClick(nil)

        // 首次 Vision 调用要加载模型，给足等待时间。
        let deadline = Date().addingTimeInterval(30)
        var copied: String?
        while Date() < deadline {
            copied = NSPasteboard.general.string(forType: .string)
            if copied == payload { break }
            pump(0.2)
        }
        if copied == payload {
            pass("RECOGNIZE-BARCODE", "点击识别码后剪贴板为 \(payload)")
        } else {
            fail("RECOGNIZE-BARCODE", "剪贴板期望 \(payload)，实际 \(copied ?? "nil")")
        }
        endSession()
    }

    private static func makeQRCode(_ payload: String) -> CGImage? {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter?.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }

    /// 与基线导出逐像素比较，返回着色像素数。两次导出的底图与选区相同，差异只来自标注。
    private func differingPixels(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        guard lhs.count == rhs.count else { return -1 }
        var count = 0
        for index in stride(from: 0, to: lhs.count, by: 4)
        where lhs[index] != rhs[index]
            || lhs[index + 1] != rhs[index + 1]
            || lhs[index + 2] != rhs[index + 2] {
            count += 1
        }
        return count
    }

    /// 同一条矩形分别用实线和虚线导出，虚线着色像素应明显更少。
    private func runLineStyleDash() {
        guard let (window, view) = beginSession("LINE-STYLE") else { return }
        drag(view, window: window, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 600, y: 500))
        let selection = view.selectionRect
        guard let baseline = exportedBytes(view) else {
            fail("LINE-STYLE", "无法导出基线像素")
            endSession()
            return
        }

        let drawPath = [
            CGPoint(x: selection.minX + 50, y: selection.minY + 50),
            CGPoint(x: selection.minX + 250, y: selection.minY + 150),
        ]
        press(view, window: window, path: drawPath)
        guard view.annotations.count == 1,
              let solid = exportedBytes(view) else {
            fail("LINE-STYLE", "实线矩形未画出或导出失败")
            endSession()
            return
        }
        let solidInk = differingPixels(solid, baseline)

        // 删除实线矩形，把当前工具的线型切到虚线后按同一坐标重画。
        keyDown(51, characters: "\u{7f}", in: window, view: view)
        guard view.annotations.isEmpty, tapLineStyle(view, id: "LINE-STYLE") else {
            fail("LINE-STYLE", "删除实线矩形或切换线型失败")
            endSession()
            return
        }
        press(view, window: window, path: drawPath)
        guard view.annotations.count == 1,
              view.annotations[0].style.lineStyle == .dashed,
              let dashed = exportedBytes(view) else {
            fail("LINE-STYLE", "虚线矩形未画出或线型未写回样式")
            endSession()
            return
        }
        let dashedInk = differingPixels(dashed, baseline)
        guard dashedInk > 0, solidInk > dashedInk else {
            fail("LINE-STYLE", "着色像素 实线 \(solidInk) 虚线 \(dashedInk)，虚线应更少")
            endSession()
            return
        }
        pass("LINE-STYLE", "虚线导出着色 \(dashedInk) 像素，少于实线 \(solidInk)")
        endSession()
    }

    /// 选中矩形拖右上角控制点，包围盒按对角固定放大；一次拖动压一步撤销。
    private func runShapeResizeHandle() {
        guard let (window, view) = beginSession("RESIZE") else { return }
        drag(view, window: window, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 700, y: 600))
        let selection = view.selectionRect
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 50, y: selection.minY + 50),
            CGPoint(x: selection.minX + 250, y: selection.minY + 150),
        ])
        guard view.annotations.count == 1,
              case .rect(let original)? = view.annotations.first?.shape else {
            fail("RESIZE", "前置画矩形失败 annotations=\(view.annotations)")
            endSession()
            return
        }

        // 右上角控制点在画布 (250,150)，拖到 (320,220)。
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 250, y: selection.minY + 150),
            CGPoint(x: selection.minX + 320, y: selection.minY + 220),
        ])
        let expected = CGRect(x: 50, y: 50, width: 270, height: 170)
        guard case .rect(let resized)? = view.annotations.first?.shape, resized == expected else {
            fail("RESIZE", "拖角后 \(view.annotations.first?.shape as Any) 期望 \(expected)")
            endSession()
            return
        }

        keyDown(6, characters: "z", in: window, view: view, modifierFlags: .command)
        guard case .rect(let restored)? = view.annotations.first?.shape, restored == original else {
            fail("RESIZE", "撤销一步后 \(view.annotations.first?.shape as Any) 期望回到 \(original)")
            endSession()
            return
        }
        pass("RESIZE", "右上角拖到 (320,220) 得 \(resized)，一次撤销回到 \(restored)")
        endSession()
    }

    /// 设置里选了 16:9 后，拖出的选区保持该比例，工具条标签同步。
    private func runAspectRatio() {
        let suite = "yaosnap.p2.aspect.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fail("ASPECT-RATIO", "无法创建测试 UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        let store = SettingsStore(defaults: defaults)
        var settings = store.load()
        settings.selectionAspectRatio = .sixteenNine
        store.save(settings)
        controller.settingsStore = store
        defer {
            controller.settingsStore = SettingsStore()
            defaults.removePersistentDomain(forName: suite)
        }

        guard let (window, view) = beginSession("ASPECT-RATIO") else { return }
        drag(view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 800, y: 500))
        let rect = view.selectionRect
        let target = 16.0 / 9.0
        let deviation = abs(rect.width / rect.height - target) / target
        if deviation <= 0.01 {
            pass("ASPECT-RATIO", "选区 \(rect) 比例偏差 \(String(format: "%.4f", deviation))")
        } else {
            fail("ASPECT-RATIO", "选区 \(rect) 比例 \(rect.width / rect.height) 偏离 16:9")
        }

        guard let bar = view.subviews.compactMap({ $0 as? AnnotateToolbar }).first else {
            fail("ASPECT-RATIO-LABEL", "覆盖视图里没有 AnnotateToolbar")
            endSession()
            return
        }
        if bar.ratioLabel.stringValue == "16:9" {
            pass("ASPECT-RATIO-LABEL", "工具条比例标签为 16:9")
        } else {
            fail("ASPECT-RATIO-LABEL", "比例标签为 \(bar.ratioLabel.stringValue)")
        }
        endSession()
    }

    /// 导出阴影开关前后，同一选区复制的剪贴板图像四周各多出一圈边距。
    private func runShadowExport() {
        let suite = "yaosnap.p2.shadow.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fail("SHADOW-EXPORT", "无法创建测试 UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        let store = SettingsStore(defaults: defaults)
        controller.settingsStore = store
        defer {
            controller.settingsStore = SettingsStore()
            defaults.removePersistentDomain(forName: suite)
        }

        func copiedSize(_ id: String) -> (Int, Int)? {
            guard let (window, view) = beginSession(id) else { return nil }
            drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 450, y: 350))
            NSPasteboard.general.clearContents()
            keyDown(36, characters: "\r", in: window, view: view)
            defer { endSession() }
            guard let image = pasteboardImage() else {
                fail(id, "剪贴板没有图像")
                return nil
            }
            return (image.width, image.height)
        }

        guard let plain = copiedSize("SHADOW-OFF") else { return }
        var settings = store.load()
        settings.exportShadow = true
        store.save(settings)
        guard let shadowed = copiedSize("SHADOW-ON") else { return }

        if shadowed.0 > plain.0, shadowed.1 > plain.1 {
            pass("SHADOW-EXPORT", "无边距 \(plain.0)x\(plain.1) -> 加阴影 \(shadowed.0)x\(shadowed.1)")
        } else {
            fail("SHADOW-EXPORT", "加阴影后尺寸未变大 \(plain.0)x\(plain.1) -> \(shadowed.0)x\(shadowed.1)")
        }
    }

    /// 白板模式：Esc 不退出、工具条默认隐藏、空格切换、导出背景为指定颜色。
    func runWhiteboardMode() {
        controller.startWhiteboard(color: WhiteboardColor.parse("#112233"), activeScreen: false)
        pump(0.4)
        guard let window = visibleOverlayWindows.first,
              let view = window.contentView as? OverlayView else {
            fail("WHITEBOARD-ESC", "startWhiteboard 后没有可见覆盖窗口")
            return
        }
        let sessionCount = visibleOverlayWindows.count

        keyDown(53, characters: "\u{1b}", in: window, view: view)
        if visibleOverlayWindows.count == sessionCount {
            pass("WHITEBOARD-ESC", "Esc 后会话仍在，覆盖窗口 \(sessionCount) 个")
        } else {
            fail("WHITEBOARD-ESC", "Esc 结束了白板会话")
        }

        drag(view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200))
        guard let bar = view.subviews.compactMap({ $0 as? AnnotateToolbar }).first else {
            fail("WHITEBOARD-TOOLBAR", "找不到标注工具条")
            endSession()
            return
        }
        if bar.isHidden {
            pass("WHITEBOARD-TOOLBAR", "有选区时工具条默认隐藏")
        } else {
            fail("WHITEBOARD-TOOLBAR", "白板模式下工具条未自动隐藏")
        }

        keyDown(49, characters: " ", in: window, view: view)
        if !bar.isHidden {
            pass("WHITEBOARD-SPACE-SHOW", "空格键显示工具条")
        } else {
            fail("WHITEBOARD-SPACE-SHOW", "空格键没有显示工具条")
        }

        keyDown(49, characters: " ", in: window, view: view)
        if bar.isHidden {
            pass("WHITEBOARD-SPACE-HIDE", "再次空格隐藏工具条")
        } else {
            fail("WHITEBOARD-SPACE-HIDE", "再次空格没有隐藏工具条")
        }

        keyDown(53, characters: "\u{1b}", in: window, view: view)
        if visibleOverlayWindows.count == sessionCount {
            pass("WHITEBOARD-ESC-SELECTION", "有选区时 Esc 也不结束会话")
        } else {
            fail("WHITEBOARD-ESC-SELECTION", "有选区时 Esc 结束了会话")
        }

        NSPasteboard.general.clearContents()
        keyDown(36, characters: "\r", in: window, view: view)
        guard let image = pasteboardImage(),
              let bytes = srgbBytes(image, width: image.width, height: image.height) else {
            fail("WHITEBOARD-COLOR", "剪贴板没有可读取的图像")
            endSession()
            return
        }
        let samples = [
            (0, 0),
            (image.width - 1, 0),
            (0, image.height - 1),
            (image.width - 1, image.height - 1),
            (image.width / 2, image.height / 2),
        ]
        let allMatch = samples.allSatisfy { point in
            let offset = (point.1 * image.width + point.0) * 4
            return abs(Int(bytes[offset]) - 17) <= 1
                && abs(Int(bytes[offset + 1]) - 34) <= 1
                && abs(Int(bytes[offset + 2]) - 51) <= 1
        }
        if allMatch {
            pass("WHITEBOARD-COLOR", "导出背景为 #112233，采样点 rgb(17,34,51)")
        } else {
            fail("WHITEBOARD-COLOR", "导出背景不是 #112233")
        }
        endSession()
    }

    func runAll() {
        if !ScreenCaptureService.hasPermission() {
            print("FATAL 屏幕录制权限缺失，无法执行标注验收")
            exit(2)
        }

        runHistoryReplay()
        runPlainCopyUnchanged()
        runDrawAndCopy()
        runClickAndTinyStroke()
        runReselectClears()
        runShapeCopies()
        runToolStyleMemory()
        runUndo()
        runRedo()
        runQuickSave()
        runAspectRatio()
        runShadowExport()
        runRecognition()
        runSerialTool()
        runBlurTool()
        runEraserTool()
        runTextAnnotation()
        runMultilineText()
        runTextTransform()
        runSelectDrag()
        runDeleteSelection()
        runCopyPasteSelection()
        runControlDragCopy()
        runMultiSelect()
        runMultiCopyClone()
        runAutoSelectOnCreate()
        runDrawAgainAfterAutoSelect()
        runRightClickCancels()
        runRightClickFinishesStroke()
        runPolylineTool()
        runTabTogglesLineArrow()
        runWheelPenSize()
        runAlphaTransparency()
        runDigitPenSize()
        runColorWheelAlpha()
        runPaletteCustomization()
        runMagnifierAndColorSampling()
        runArrowNudge()
        runLineStyleDash()
        runShapeResizeHandle()
        runWhiteboardMode()

        print("SUMMARY passes=\(passes) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}

@main
struct P2AnnotateE2EMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)

            let base = URL(fileURLWithPath: "/tmp/yaosnap-verify", isDirectory: true)
            let evidence = base.appendingPathComponent("evidence", isDirectory: true)
            try? FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)

            let harness = AnnotateHarness(evidenceDir: evidence)
            harness.runAll()
        }
    }
}
