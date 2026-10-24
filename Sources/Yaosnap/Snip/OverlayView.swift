import AppKit
import YaosnapCore

/// 单屏覆盖视图：绘制冻结帧与选区遮罩，承载拖拽选区交互。
@MainActor
final class OverlayView: NSView {
    let shot: DisplayShot

    /// 拖拽起点（视图坐标）。nil 表示当前没有按下鼠标。
    private var dragOrigin: CGPoint?
    /// 本次按下后位移是否超过阈值。用于区分"单击确认"和"重画选区"。
    private var didDrag = false
    /// 选区是否已确定（已发 snipCommitted），等待 Enter / 双击 / ⌘S 输出。
    private var isCommitted = false
    /// 光标下的可吸附窗口（全局坐标）。nil 表示光标不在任何窗口上。
    private var hoverWindow: WindowCandidate?
    /// 当前选区（视图坐标，左下原点）。空矩形表示尚未选中。
    private(set) var selectionRect: CGRect = .zero

    private static let maskAlpha: CGFloat = 0.45
    private static let minimumSelectionSide: CGFloat = 1
    /// 按下到松开的位移小于该值视为单击；双击确认时手抖不应清掉已确定的选区。
    private static let dragThreshold: CGFloat = 3

    /// 本屏可吸附候选。冻结帧存续期间窗口布局视为不变，只取一次。
    private lazy var candidates: [WindowCandidate] = {
        let own = getpid()
        let all = WindowDetector.onScreenWindows(ownPID: own)
        let snap = WindowDetector.snapCandidates(from: all, ownPID: own)
        return snap.filter { shot.bounds.intersects($0.bounds) }
    }()

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
        if selectionRect.isEmpty {
            drawHoverHighlight()
        } else {
            drawSelectionBorder()
            drawSizeLabel()
        }
    }

    // MARK: - 鼠标交互

    override func mouseMoved(with event: NSEvent) {
        // 已有选区时 hover 不绘制，跳过状态更新避免整屏重绘
        guard dragOrigin == nil, selectionRect.isEmpty else { return }
        let hit = windowUnderMouse(at: convert(event.locationInWindow, from: nil))
        guard hit != hoverWindow else { return }
        hoverWindow = hit
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isCommitted, selectionRect.contains(point) {
            if event.clickCount == 2 {
                requestCopy()
                return
            }
            // 已确定的选区：单击保留选区，拖动可重画
            dragOrigin = point
            didDrag = false
            return
        }

        isCommitted = false
        didDrag = false
        dragOrigin = point
        hoverWindow = nil
        // 起点落在窗口内 → 初始选区为整个窗口；拖动后才脱离窗口锁定。
        if let window = windowUnderMouse(at: point) {
            selectionRect = RectMath.clamp(
                RectMath.toViewRect(
                    globalRect: window.bounds,
                    displayBounds: shot.bounds,
                    viewHeight: bounds.height
                ),
                to: bounds
            )
        } else {
            selectionRect = .zero
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let current = convert(event.locationInWindow, from: nil)
        guard didDrag
            || abs(current.x - origin.x) >= Self.dragThreshold
            || abs(current.y - origin.y) >= Self.dragThreshold else { return }
        didDrag = true
        isCommitted = false
        // 拖动即脱离窗口锁定：按起点与当前点重算自由选区。
        // 鼠标可拖出视图范围，钳制后选区始终落在冻结帧内。
        selectionRect = RectMath.clamp(
            RectMath.normalizedRect(from: origin, to: current),
            to: bounds
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragOrigin != nil else { return }
        dragOrigin = nil
        // 单击已确定的选区：保留它，等待 Enter / 双击 / ⌘S
        if isCommitted && !didDrag {
            return
        }
        guard selectionRect.width >= Self.minimumSelectionSide,
              selectionRect.height >= Self.minimumSelectionSide else {
            selectionRect = .zero
            isCommitted = false
            needsDisplay = true
            return
        }
        isCommitted = true
        commitSelection()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            NotificationCenter.default.post(name: .snipEscapePressed, object: nil)
        case 36: // Return
            guard isCommitted, !selectionRect.isEmpty else { return }
            requestCopy()
        case 1 where event.modifierFlags.contains(.command): // ⌘S
            guard isCommitted, !selectionRect.isEmpty else { return }
            requestSave()
        default:
            super.keyDown(with: event)
        }
    }

    /// 光标下的窗口：视图坐标 → CG 全局坐标后在本屏候选里取最顶层命中。
    private func windowUnderMouse(at viewPoint: CGPoint) -> WindowCandidate? {
        let globalPoint = CGPoint(
            x: shot.bounds.minX + viewPoint.x,
            y: shot.bounds.minY + (bounds.height - viewPoint.y)
        )
        return WindowDetector.window(at: globalPoint, in: candidates)
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

    private func requestCopy() {
        NotificationCenter.default.post(
            name: .snipCopyRequested,
            object: nil,
            userInfo: ["displayID": shot.displayID]
        )
    }

    private func requestSave() {
        NotificationCenter.default.post(
            name: .snipSaveRequested,
            object: nil,
            userInfo: ["displayID": shot.displayID]
        )
    }

    // MARK: - 绘制

    private func drawHoverHighlight() {
        guard let window = hoverWindow else { return }
        let rect = RectMath.clamp(
            RectMath.toViewRect(
                globalRect: window.bounds,
                displayBounds: shot.bounds,
                viewHeight: bounds.height
            ),
            to: bounds
        )
        guard !rect.isEmpty else { return }
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 2
        NSColor.systemBlue.setStroke()
        border.stroke()
    }

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
    static let snipCopyRequested = Notification.Name("snipCopyRequested")
    static let snipSaveRequested = Notification.Name("snipSaveRequested")
}
