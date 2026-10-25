import AppKit
import YaosnapCore

/// 持有所有贴图窗口。窗口关闭时由 windowWillClose 回收。
@MainActor
final class PinController: NSObject, NSWindowDelegate {
    private var pinned: [PinWindow] = []

    @discardableResult
    func pinFromPasteboard() -> Bool {
        guard let content = PasteboardReader.read(from: .general),
              let image = PasteboardReader.render(content) else {
            print("[pin] 剪贴板没有可贴的内容")
            NSSound.beep()
            return false
        }
        guard let screen = screenUnderMouse() else {
            print("[pin] 找不到可用屏幕")
            NSSound.beep()
            return false
        }
        present(image, on: screen, at: nil)
        print("[pin] pinned kind=\(content.kind) size=\(Int(image.pointSize.width))x\(Int(image.pointSize.height))")
        return true
    }

    /// 命令行贴图：--pos 给的是主屏左上角为原点的坐标，越界时由窗口初始化钳回可见区域。
    @discardableResult
    func pin(image: PasteImage, at topLeft: CGPoint?) -> Bool {
        let appKitTop = topLeft.map(Self.appKitTop(fromTopLeft:))
        guard let screen = screen(containing: appKitTop) else {
            print("[pin] 找不到可用屏幕")
            NSSound.beep()
            return false
        }
        present(image, on: screen, at: appKitTop)
        print("[pin] pinned from cli size=\(Int(image.pointSize.width))x\(Int(image.pointSize.height))")
        return true
    }

    func showAll() {
        for window in pinned { window.orderFront(nil) }
        pinned.last?.makeKey()
    }

    func hideAll() {
        for window in pinned { window.orderOut(nil) }
    }

    /// 只要还有可见窗口就全部隐藏，否则全部显示。
    @discardableResult
    func toggleVisibility() -> Bool {
        if pinned.contains(where: \.isVisible) {
            for window in pinned { window.orderOut(nil) }
            return false
        }
        for window in pinned { window.orderFront(nil) }
        pinned.last?.makeKey()
        return true
    }

    func closeAll() {
        let windows = pinned
        pinned.removeAll()
        for window in windows { window.close() }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? PinWindow else { return }
        pinned.removeAll { $0 === window }
    }

    /// 拖到屏幕外时把整个窗口钳回可见区域。
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? PinWindow,
              let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = window.frame
        let x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
        let y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
        guard x != frame.minX || y != frame.minY else { return }
        window.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private func present(_ image: PasteImage, on screen: NSScreen, at topLeft: CGPoint?) {
        let window = PinWindow(
            pasteImage: image,
            screen: screen,
            cascadeIndex: pinned.count,
            topLeft: topLeft
        )
        window.delegate = self
        pinned.append(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Snipaste 的 --pos 以主屏左上角为原点、y 向下；AppKit 以左下角为原点、y 向上。
    private static func appKitTop(fromTopLeft point: CGPoint) -> CGPoint {
        let main = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == CGMainDisplayID()
        } ?? NSScreen.screens.first
        let topY = main?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: topY - point.y)
    }

    private func screen(containing point: CGPoint?) -> NSScreen? {
        guard let point else { return screenUnderMouse() }
        return NSScreen.screens.first { $0.frame.contains(point) } ?? screenUnderMouse()
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}
