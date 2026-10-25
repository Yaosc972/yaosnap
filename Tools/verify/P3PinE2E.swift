import AppKit
import CoreGraphics
import Foundation
import YaosnapCore

/// P3 贴图第一批验收 harness。驱动真实 PinController / PinWindow，
/// 验证单张 / 多张共存、关闭、隐藏显示、Esc 与双击。
@MainActor
final class PinHarness {
    private let controller = PinController()
    private var passes = 0
    private var failures = 0

    // MARK: - 基础设施

    private func pass(_ id: String, _ detail: String) {
        passes += 1
        print("PASS \(id) \(detail)")
    }

    private func fail(_ id: String, _ detail: String) {
        failures += 1
        print("FAIL \(id) \(detail)")
    }

    private func pump(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private var imageSerial = 0

    private func makeImage(width: Int, height: Int) -> CGImage {
        imageSerial += 1
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // 每次生成不同像素，剪贴板内容才算真的变了，不会误触关闭贴图的恢复。
        ctx.setFillColor(CGColor(
            srgbRed: 0.9,
            green: min(1, 0.3 + CGFloat(imageSerial) * 0.01),
            blue: 0.2,
            alpha: 1
        ))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func putImage(width: Int, height: Int) {
        let image = NSImage(
            cgImage: makeImage(width: width, height: height),
            size: NSSize(width: width, height: height)
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.writeObjects([image])
    }

    private func putString(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private func allPinWindows() -> [PinWindow] {
        NSApp.windows.compactMap { $0 as? PinWindow }
    }

    private func visiblePinWindows() -> [PinWindow] {
        allPinWindows().filter(\.isVisible)
    }

    private func keyEvent(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        window: NSWindow
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func mouseEvent(clickCount: Int, window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: 5, y: 5),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        )
    }

    private func mouseDragEvent(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        window: NSWindow
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }

    /// 把窗口内容离屏渲染成位图再取像素，屏幕休眠时也不会拿到全黑。
    private func sampledPixel(
        of window: PinWindow,
        atRelative point: CGPoint
    ) -> (r: Int, g: Int, b: Int)? {
        guard let view = window.contentView,
              view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return nil }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0,
              let context = CGContext(
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
        let x = min(width - 1, max(0, Int(point.x * CGFloat(width))))
        let yFromBottom = min(height - 1, max(0, Int(point.y * CGFloat(height))))
        let offset = ((height - 1 - yFromBottom) * width + x) * 4
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    // MARK: - 用例

    private func runFirstPin() {
        putImage(width: 40, height: 30)
        let pinned = controller.pinFromPasteboard()
        pump()
        let windows = visiblePinWindows()
        guard pinned, windows.count == 1 else {
            fail("PIN-ONE", "期望 1 个贴图窗口，实际 \(windows.count)")
            return
        }
        let size = windows[0].frame.size
        if size == NSSize(width: 40, height: 30),
           windows[0].level == .floating,
           windows[0].styleMask.isEmpty,
           !windows[0].isOpaque {
            pass("PIN-ONE", "单张贴图 40x30，无边框置顶透明，尺寸一致")
        } else {
            fail("PIN-ONE", "尺寸 \(Int(size.width))x\(Int(size.height))，level=\(windows[0].level.rawValue)")
        }
    }

    private func runSecondPin() {
        putImage(width: 60, height: 40)
        let pinned = controller.pinFromPasteboard()
        pump()
        let windows = visiblePinWindows()
        if pinned, windows.count == 2 {
            pass("PIN-TWO", "第二张贴图后两个窗口共存")
        } else {
            fail("PIN-TWO", "期望 2 个贴图窗口，实际 \(windows.count)")
        }
    }

    private func runCloseOne() {
        let windows = visiblePinWindows()
        guard let first = windows.first else {
            fail("PIN-CLOSE", "没有可关闭的贴图窗口")
            return
        }
        first.close()
        pump()
        let remaining = visiblePinWindows()
        if remaining.count == 1 {
            pass("PIN-CLOSE", "关闭一个后剩 1 个")
        } else {
            fail("PIN-CLOSE", "期望剩 1 个窗口，实际 \(remaining.count)")
        }
    }

    private func runHideShow() {
        let hidden = controller.toggleVisibility()
        pump()
        let visibleAfterHide = visiblePinWindows().count
        if !hidden, visibleAfterHide == 0 {
            pass("PIN-HIDE", "隐藏全部后无可见窗口")
        } else {
            fail("PIN-HIDE", "隐藏后可见 \(visibleAfterHide) 个")
        }

        let shown = controller.toggleVisibility()
        pump()
        let visibleAfterShow = visiblePinWindows().count
        if shown, visibleAfterShow == 1 {
            pass("PIN-SHOW", "再次切换后窗口恢复可见")
        } else {
            fail("PIN-SHOW", "显示后可见 \(visibleAfterShow) 个")
        }
    }

    private func runEscape() {
        guard let window = visiblePinWindows().first,
              let view = window.contentView,
              let event = keyEvent(keyCode: 53, characters: "\u{1b}", window: window) else {
            fail("PIN-ESC", "没有可发送 Esc 的贴图窗口")
            return
        }
        view.keyDown(with: event)
        pump()
        if visiblePinWindows().isEmpty {
            pass("PIN-ESC", "Esc 关闭当前贴图")
        } else {
            fail("PIN-ESC", "Esc 后仍有 \(visiblePinWindows().count) 个窗口")
        }
    }

    private func runDoubleClick() {
        putImage(width: 24, height: 24)
        let pinned = controller.pinFromPasteboard()
        pump()
        guard pinned,
              let window = visiblePinWindows().first,
              let view = window.contentView,
              let event = mouseEvent(clickCount: 2, window: window) else {
            fail("PIN-DBLCLICK", "没有可双击的贴图窗口")
            return
        }
        view.mouseDown(with: event)
        pump()
        if visiblePinWindows().isEmpty {
            pass("PIN-DBLCLICK", "左键双击关闭贴图")
        } else {
            fail("PIN-DBLCLICK", "双击后仍有 \(visiblePinWindows().count) 个窗口")
        }
    }

    private func runColorPin() {
        putString("#FF8800")
        let pinned = controller.pinFromPasteboard()
        pump()
        guard pinned, let window = visiblePinWindows().first else {
            fail("PIN-COLOR", "颜色文本没有贴出窗口")
            return
        }
        let expected = PasteboardReader.colorBlockSize
        if window.frame.size == expected {
            pass("PIN-COLOR", "HEX 颜色生成 \(Int(expected.width))x\(Int(expected.height)) 色块")
        } else {
            fail("PIN-COLOR", "色块尺寸 \(window.frame.size)，期望 \(expected)")
        }
        window.close()
        pump()
    }

    private func runTextPin() {
        putString("贴图文本第二行\nsecond line")
        let pinned = controller.pinFromPasteboard()
        pump()
        guard pinned, let window = visiblePinWindows().first else {
            fail("PIN-TEXT", "纯文本没有贴出窗口")
            return
        }
        let size = window.frame.size
        if size.width > 64, size.height > 64 {
            pass("PIN-TEXT", "纯文本渲染成 \(Int(size.width))x\(Int(size.height)) 窗口")
        } else {
            fail("PIN-TEXT", "文本窗口尺寸异常 \(size)")
        }
        window.close()
        pump()
    }

    private func runFilePathPin() {
        let ctx = CGContext(
            data: nil, width: 20, height: 10,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.7, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        let cgImage = ctx.makeImage()!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yaosnap-pin-e2e-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = ImageOutput.pngData(from: cgImage) else {
            fail("PIN-FILE", "测试 PNG 编码失败")
            return
        }
        try? data.write(to: url)

        putString(url.path)
        let pinned = controller.pinFromPasteboard()
        pump()
        guard pinned, let window = visiblePinWindows().first else {
            fail("PIN-FILE", "图片路径没有贴出窗口")
            return
        }
        if window.frame.size == NSSize(width: 20, height: 10) {
            pass("PIN-FILE", "图片文件路径贴出 20x10 图像")
        } else {
            fail("PIN-FILE", "文件贴图尺寸 \(window.frame.size)，期望 20x10")
        }
        window.close()
        pump()
    }

    private func runHTMLPin() {
        let html = "<html><body><p>HTML 贴图</p></body></html>".data(using: .utf8)!
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(html, forType: .html)

        let pinned = controller.pinFromPasteboard()
        pump()
        guard pinned, let window = visiblePinWindows().first else {
            fail("PIN-HTML", "HTML 没有贴出窗口")
            return
        }
        let size = window.frame.size
        let minHeight = PasteboardReader.textPadding * 2 + PasteboardReader.textFontSize
        if size.width > 64, size.height > minHeight {
            pass("PIN-HTML", "HTML 转文本渲染成 \(Int(size.width))x\(Int(size.height)) 窗口")
        } else {
            fail("PIN-HTML", "HTML 窗口尺寸异常 \(size)")
        }
        window.close()
        pump()
    }

    /// 记下已有窗口号再贴一张 40x30，返回新增的窗口。每个用例只碰自己新建的窗口。
    private func pinFreshWindow() -> PinWindow? {
        let before = Set(allPinWindows().map(\.windowNumber))
        putImage(width: 40, height: 30)
        guard controller.pinFromPasteboard() else { return nil }
        pump()
        return allPinWindows().first { !before.contains($0.windowNumber) }
    }

    private func runZoom() {
        guard let window = pinFreshWindow() else {
            fail("PIN-ZOOM", "没有新建贴图窗口")
            return
        }
        window.setScale(2)
        pump(0.1)
        let size = window.frame.size
        if size == NSSize(width: 80, height: 60) {
            pass("PIN-ZOOM", "scale 2 后窗口 80x60")
        } else {
            fail("PIN-ZOOM", "窗口 \(Int(size.width))x\(Int(size.height))，期望 80x60")
        }
        window.close()
        pump()
    }

    private func runRotate() {
        guard let window = pinFreshWindow() else {
            fail("PIN-ROTATE", "没有新建贴图窗口")
            return
        }
        window.rotate(byQuarterTurns: 1)
        pump(0.1)
        let size = window.frame.size
        if size == NSSize(width: 30, height: 40) {
            pass("PIN-ROTATE", "顺时针 90 度后窗口 30x40")
        } else {
            fail("PIN-ROTATE", "窗口 \(Int(size.width))x\(Int(size.height))，期望 30x40")
        }
        window.close()
        pump()
    }

    private func runOpacity() {
        guard let window = pinFreshWindow() else {
            fail("PIN-OPACITY", "没有新建贴图窗口")
            return
        }
        window.setOpacity(0.5)
        pump(0.1)
        if window.alphaValue == 0.5 {
            pass("PIN-OPACITY", "透明度 0.5 生效")
        } else {
            fail("PIN-OPACITY", "alphaValue 为 \(window.alphaValue)，期望 0.5")
        }
        window.close()
        pump()
    }

    private func runImageEffects() {
        guard let window = pinFreshWindow(), let view = window.contentView,
              let original = sampledPixel(of: window, atRelative: CGPoint(x: 0.5, y: 0.5)),
              let grayEvent = keyEvent(keyCode: 5, characters: "g", window: window) else {
            fail("PIN-GRAYSCALE", "没有可读像素的贴图窗口")
            return
        }
        view.keyDown(with: grayEvent)
        pump(0.1)
        guard let gray = sampledPixel(of: window, atRelative: CGPoint(x: 0.5, y: 0.5)) else {
            fail("PIN-GRAYSCALE", "灰度后读不到像素")
            window.close()
            return
        }
        if gray.r == gray.g, gray.g == gray.b,
           !(original.r == original.g && original.g == original.b) {
            pass("PIN-GRAYSCALE", "G 后像素 \(gray.r),\(gray.g),\(gray.b) 三通道相等")
        } else {
            fail("PIN-GRAYSCALE", "原色 \(original)，灰度后 \(gray)")
        }

        guard let invertEvent = keyEvent(keyCode: 34, characters: "i", window: window) else {
            fail("PIN-INVERT", "构造 I 键失败")
            window.close()
            return
        }
        view.keyDown(with: invertEvent)
        pump(0.1)
        guard let inverted = sampledPixel(of: window, atRelative: CGPoint(x: 0.5, y: 0.5)) else {
            fail("PIN-INVERT", "反色后读不到像素")
            window.close()
            return
        }
        if abs(inverted.r - (255 - gray.r)) <= 2,
           abs(inverted.g - (255 - gray.g)) <= 2,
           abs(inverted.b - (255 - gray.b)) <= 2 {
            pass("PIN-INVERT", "反色后像素 \(inverted) 等于 255 减灰度值")
        } else {
            fail("PIN-INVERT", "灰度 \(gray)，反色后 \(inverted)")
        }

        // 关掉两个开关应回到原色，验证原始图没有被改写。
        view.keyDown(with: invertEvent)
        view.keyDown(with: grayEvent)
        pump(0.1)
        if let restored = sampledPixel(of: window, atRelative: CGPoint(x: 0.5, y: 0.5)),
           abs(restored.r - original.r) <= 2,
           abs(restored.g - original.g) <= 2,
           abs(restored.b - original.b) <= 2 {
            pass("PIN-EFFECT-RESTORE", "关掉灰度与反色后恢复原色")
        } else {
            fail("PIN-EFFECT-RESTORE", "原色 \(original)，恢复后读像素失败或颜色不符")
        }
        window.close()
        pump()
    }

    private func runCrop() {
        guard let window = pinFreshWindow(), let view = window.contentView else {
            fail("PIN-CROP", "没有新建贴图窗口")
            return
        }
        let before = window.frame
        guard let cropKey = keyEvent(keyCode: 8, characters: "c", window: window),
              let down = mouseDragEvent(.leftMouseDown, at: CGPoint(x: 0, y: 0), window: window),
              let drag = mouseDragEvent(.leftMouseDragged, at: CGPoint(x: 20, y: 30), window: window),
              let up = mouseDragEvent(.leftMouseUp, at: CGPoint(x: 20, y: 30), window: window) else {
            fail("PIN-CROP", "构造裁剪事件失败")
            window.close()
            return
        }
        view.keyDown(with: cropKey)
        pump(0.05)
        view.mouseDown(with: down)
        view.mouseDragged(with: drag)
        view.mouseUp(with: up)
        pump(0.1)

        let after = window.frame
        if after.size == NSSize(width: 20, height: 30),
           after.minX == before.minX,
           after.maxY == before.maxY {
            pass("PIN-CROP", "裁剪后窗口 20x30，左上角未动")
        } else {
            fail("PIN-CROP", "裁剪后 frame \(after)，裁剪前 \(before)")
        }

        guard let undo = keyEvent(
            keyCode: 6,
            characters: "z",
            modifiers: [.command],
            window: window
        ) else {
            fail("PIN-CROP-UNDO", "构造 ⌘Z 失败")
            window.close()
            return
        }
        view.keyDown(with: undo)
        pump(0.1)
        if window.frame.size == before.size,
           window.frame.minX == before.minX,
           window.frame.maxY == before.maxY {
            pass("PIN-CROP-UNDO", "⌘Z 恢复到裁剪前的 40x30")
        } else {
            fail("PIN-CROP-UNDO", "撤销后 frame \(window.frame)，期望 \(before)")
        }
        window.close()
        pump()
    }

    private func runMiddleReset() {
        guard let window = pinFreshWindow(), let view = window.contentView else {
            fail("PIN-MIDDLE-RESET", "没有新建贴图窗口")
            return
        }
        window.setScale(2)
        window.rotate(byQuarterTurns: 1)
        window.setOpacity(0.5)
        window.toggleFlipHorizontal()
        pump(0.1)

        guard let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .otherMouseDown,
            mouseCursorPosition: .zero,
            mouseButton: .center
        ), let event = NSEvent(cgEvent: cgEvent) else {
            fail("PIN-MIDDLE-RESET", "构造中键事件失败")
            window.close()
            return
        }
        view.otherMouseDown(with: event)
        pump(0.1)

        let size = window.frame.size
        if size == NSSize(width: 40, height: 30),
           window.alphaValue == 1,
           window.transform == .identity {
            pass("PIN-MIDDLE-RESET", "中键恢复到 40x30、不透明、identity")
        } else {
            fail("PIN-MIDDLE-RESET", "尺寸 \(size) alpha \(window.alphaValue)")
        }
        window.close()
        pump()
    }

    private func runControlW() {
        guard let window = pinFreshWindow(), let view = window.contentView else {
            fail("PIN-CTRL-W", "没有新建贴图窗口")
            return
        }
        let before = visiblePinWindows().count
        guard let event = keyEvent(
            keyCode: 13,
            characters: "w",
            modifiers: .control,
            window: window
        ) else {
            fail("PIN-CTRL-W", "构造 Ctrl+W 事件失败")
            window.close()
            return
        }
        view.keyDown(with: event)
        pump()
        let after = visiblePinWindows().count
        if after == before - 1 {
            pass("PIN-CTRL-W", "Ctrl+W 关闭当前贴图")
        } else {
            fail("PIN-CTRL-W", "关闭后可见 \(after) 个，期望 \(before - 1)")
        }
        window.close()
        pump()
    }

    private func runRestoreClosed() {
        guard let window = pinFreshWindow() else {
            fail("PIN-RESTORE", "没有新建贴图窗口")
            return
        }
        window.setScale(1.5)
        pump(0.1)
        let frame = window.frame
        let transform = window.transform
        window.close()
        pump()

        // 不再写剪贴板：内容与上次贴出相同，贴图键应该恢复而不是新建。
        let before = Set(allPinWindows().map(\.windowNumber))
        let pinned = controller.pinFromPasteboard()
        pump()
        guard pinned, let restored = allPinWindows().first(where: { !before.contains($0.windowNumber) }) else {
            fail("PIN-RESTORE", "剪贴板未变时没有恢复关闭的贴图")
            return
        }
        if restored.frame == frame, restored.transform == transform {
            pass("PIN-RESTORE", "关闭后贴图键恢复原位置与变换")
        } else {
            fail("PIN-RESTORE", "恢复后 frame \(restored.frame) transform \(restored.transform)")
        }
    }

    private func runPassthrough() {
        guard let window = pinFreshWindow() else {
            fail("PIN-PASSTHROUGH", "没有新建贴图窗口")
            return
        }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        _ = controller.togglePassthrough(at: center)
        pump(0.05)
        guard window.ignoresMouseEvents else {
            fail("PIN-PASSTHROUGH", "切换后 ignoresMouseEvents 仍为 false")
            return
        }
        if visiblePinWindows().contains(where: { $0 !== window && $0.ignoresMouseEvents }) {
            fail("PIN-PASSTHROUGH", "穿透切换影响了光标未覆盖的贴图")
            return
        }

        _ = controller.togglePassthrough(at: center)
        pump(0.05)
        if window.ignoresMouseEvents {
            fail("PIN-PASSTHROUGH", "再次切换后仍为穿透")
        } else {
            pass("PIN-PASSTHROUGH", "切换后穿透，再切换恢复可点击")
        }
    }

    private func runGroupSwitch() {
        controller.closeAll()
        pump()
        guard let defaultPin = pinFreshWindow(), let secondPin = pinFreshWindow() else {
            fail("PIN-GROUP-SWITCH", "没有新建贴图窗口")
            return
        }
        guard controller.addGroup(named: "工作"),
              let workID = controller.pinGroups.first(where: { $0.name == "工作" })?.id else {
            fail("PIN-GROUP-SWITCH", "新建分组失败")
            return
        }
        guard controller.activateGroup(workID) else {
            fail("PIN-GROUP-SWITCH", "切换分组失败")
            return
        }
        let afterSwitch = visiblePinWindows()
        if afterSwitch.isEmpty {
            pass("PIN-GROUP-SWITCH", "切到空分组后原组贴图全部隐藏")
        } else {
            fail("PIN-GROUP-SWITCH", "切组后仍有 \(afterSwitch.count) 个可见贴图")
        }

        guard controller.activateGroup(PinBoard.defaultGroupID) else {
            fail("PIN-GROUP-RESTORE", "切回默认组失败")
            return
        }
        let restored = visiblePinWindows()
        if restored.count == 2,
           restored.contains(where: { $0 === defaultPin }),
           restored.contains(where: { $0 === secondPin }) {
            pass("PIN-GROUP-RESTORE", "切回默认组后两张贴图恢复可见")
        } else {
            fail("PIN-GROUP-RESTORE", "切回后可见 \(restored.count) 个")
        }

        controller.deleteGroup(workID)
        pump()
    }

    private func runSolo() {
        controller.closeAll()
        pump()
        guard let solo = pinFreshWindow(), let other = pinFreshWindow() else {
            fail("PIN-SOLO", "没有新建贴图窗口")
            return
        }
        guard controller.toggleSolo(pinID: solo.pinID) else {
            fail("PIN-SOLO", "开启 Solo 失败")
            return
        }
        pump(0.1)
        let soloVisible = visiblePinWindows()
        if soloVisible.count == 1, soloVisible[0] === solo {
            pass("PIN-SOLO", "Solo 后只显示目标贴图")
        } else {
            fail("PIN-SOLO", "Solo 后可见 \(soloVisible.count) 个，期望 1")
        }

        guard controller.toggleSolo(pinID: solo.pinID) else {
            fail("PIN-SOLO-EXIT", "退出 Solo 失败")
            return
        }
        pump(0.1)
        let afterExit = visiblePinWindows()
        if afterExit.count == 2,
           afterExit.contains(where: { $0 === solo }),
           afterExit.contains(where: { $0 === other }) {
            pass("PIN-SOLO-EXIT", "退出 Solo 后两张贴图恢复可见")
        } else {
            fail("PIN-SOLO-EXIT", "退出后可见 \(afterExit.count) 个，期望 2")
        }

        solo.close()
        other.close()
        pump()
    }

    func runAll() {
        runFirstPin()
        runSecondPin()
        runCloseOne()
        runHideShow()
        runEscape()
        runDoubleClick()
        runColorPin()
        runTextPin()
        runHTMLPin()
        runFilePathPin()
        runZoom()
        runRotate()
        runOpacity()
        runImageEffects()
        runCrop()
        runMiddleReset()
        runControlW()
        runRestoreClosed()
        runPassthrough()
        runGroupSwitch()
        runSolo()
        controller.closeAll()
        print("SUMMARY passes=\(passes) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}

@main
struct P3PinE2EMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)

            let base = URL(fileURLWithPath: "/tmp/yaosnap-verify", isDirectory: true)
            let evidence = base.appendingPathComponent("evidence", isDirectory: true)
            try? FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)

            let harness = PinHarness()
            harness.runAll()
        }
    }
}
