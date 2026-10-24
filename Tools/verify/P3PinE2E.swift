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

    private func makeImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.3, blue: 0.2, alpha: 1))
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
        runMiddleReset()
        runControlW()
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
