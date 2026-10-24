import AppKit
import YaosnapCore

/// 单屏覆盖视图：绘制冻结帧，承载选区交互（Task 7 扩展）。
@MainActor
final class OverlayView: NSView {
    let shot: DisplayShot

    init(shot: DisplayShot) {
        self.shot = shot
        super.init(frame: NSRect(
            x: 0, y: 0,
            width: shot.bounds.width,
            height: shot.bounds.height
        ))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // 用 NSImage 绘制，避免 CGImage 直接进 CGContext 时的上下翻转。
        NSImage(cgImage: shot.image, size: bounds.size).draw(in: bounds)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            NotificationCenter.default.post(name: .snipEscapePressed, object: nil)
        } else {
            super.keyDown(with: event)
        }
    }
}

extension Notification.Name {
    static let snipEscapePressed = Notification.Name("snipEscapePressed")
}
