import AppKit

/// 覆盖在整屏之上的无边框窗口，背景为冻结帧。
@MainActor
final class SnipOverlayWindow: NSWindow {
    init(screen: NSScreen, translucent: Bool = false) {
        // designated init 的 contentRect 用全局屏幕坐标；带 screen: 的便捷 init 相对该屏左下角，副屏会二次偏移。
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .init(Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 透明白板要让实时桌面从窗口下方透出，窗口本身不能有不透明底色和阴影。
        isOpaque = !translucent
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        backgroundColor = translucent ? .clear : .black
        // 窗口由 SnipController 强引用并跨会话复用，关闭时不能由 AppKit 释放。
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
