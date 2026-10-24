import AppKit
import YaosnapCore

/// 单屏覆盖视图：绘制冻结帧与选区遮罩，承载拖拽选区交互。
@MainActor
final class OverlayView: NSView {
    let shot: DisplayShot

    /// 拖拽起点（视图坐标）。nil 表示当前没有进行中的拖拽。
    private var dragOrigin: CGPoint?
    /// 当前选区（视图坐标，左下原点）。空矩形表示尚未选中。
    private(set) var selectionRect: CGRect = .zero

    private static let maskAlpha: CGFloat = 0.45
    private static let minimumSelectionSide: CGFloat = 1

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
        drawMask()
        guard !selectionRect.isEmpty else { return }
        drawSelectionBorder()
        drawSizeLabel()
    }

    // MARK: - 鼠标交互

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
        selectionRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let current = convert(event.locationInWindow, from: nil)
        // 鼠标可拖出视图范围，钳制后选区始终落在冻结帧内。
        selectionRect = RectMath.clamp(
            RectMath.normalizedRect(from: origin, to: current),
            to: bounds
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        guard selectionRect.width >= Self.minimumSelectionSide,
              selectionRect.height >= Self.minimumSelectionSide else {
            selectionRect = .zero
            needsDisplay = true
            return
        }
        commitSelection()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            NotificationCenter.default.post(name: .snipEscapePressed, object: nil)
        } else {
            super.keyDown(with: event)
        }
    }

    private func commitSelection() {
        NotificationCenter.default.post(
            name: .snipCommitted,
            object: nil,
            userInfo: [
                "viewRect": selectionRect,
                "viewHeight": bounds.height,
                "scale": shot.scale,
                "displayID": shot.displayID,
            ]
        )
    }

    // MARK: - 绘制

    private func drawMask() {
        let mask = NSBezierPath(rect: bounds)
        if !selectionRect.isEmpty {
            // even-odd 挖空选区。.clear 混合模式会连已绘制的冻结帧一起擦掉，透出窗口黑底。
            mask.appendRect(selectionRect)
            mask.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(Self.maskAlpha).setFill()
        mask.fill()
    }

    private func drawSelectionBorder() {
        let border = NSBezierPath(rect: selectionRect)
        border.lineWidth = 1
        NSColor.white.setStroke()
        border.stroke()
    }

    private func drawSizeLabel() {
        let width = Int(selectionRect.width)
        let height = Int(selectionRect.height)
        guard width >= 1, height >= 1 else { return }

        let text = "\(width) × \(height)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let padding = NSSize(width: 6, height: 3)
        let textSize = text.size(withAttributes: attributes)
        let labelSize = NSSize(
            width: ceil(textSize.width) + padding.width * 2,
            height: ceil(textSize.height) + padding.height * 2
        )

        var origin = CGPoint(x: selectionRect.maxX - labelSize.width, y: selectionRect.maxY + 4)
        if origin.y + labelSize.height > bounds.maxY {
            origin.y = selectionRect.maxY - labelSize.height - 4
        }
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - labelSize.width - 4)

        let labelRect = NSRect(origin: origin, size: labelSize)
        NSColor(white: 0, alpha: 0.7).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
        text.draw(
            at: NSPoint(x: labelRect.minX + padding.width, y: labelRect.minY + padding.height),
            withAttributes: attributes
        )
    }
}

extension Notification.Name {
    static let snipEscapePressed = Notification.Name("snipEscapePressed")
    static let snipCommitted = Notification.Name("snipCommitted")
}
