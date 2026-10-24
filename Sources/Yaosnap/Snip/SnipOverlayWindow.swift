import AppKit

/// 覆盖在整屏之上的无边框窗口，背景为冻结帧。
@MainActor
final class SnipOverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // designated init 的 contentRect 用全局屏幕坐标；带 screen: 的便捷 init 相对该屏左下角，副屏会二次偏移。
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .init(Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = true
        hasShadow = false
        ignoresMouseEvents = false
        backgroundColor = .black
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
