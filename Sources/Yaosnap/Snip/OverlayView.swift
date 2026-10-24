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

    /// 是否显示十字光标。保存面板等场景由控制器临时关闭。
    var showsCrosshair = true {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    private static let maskAlpha: CGFloat = 0.32
    private static let minimumSelectionSide: CGFloat = 1
    /// 按下到松开的位移小于该值视为单击；双击确认时手抖不应清掉已确定的选区。
    private static let dragThreshold: CGFloat = 3

    /// 尺寸标签的绘制参数。散在绘制代码里会让间距和字号无法对齐调。
    private enum SizeLabel {
        static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        static let textColor = NSColor.white
        static let background = NSColor(white: 0, alpha: 0.7)
        static let padding = NSSize(width: 6, height: 3)
        static let cornerRadius: CGFloat = 4
        /// 标签与选区、屏幕边缘的间距。
        static let gap: CGFloat = 4
    }

    /// 冻结帧的 NSImage 包装。draw 每帧都会调用，重建 NSImage 在大屏拖拽时会掉帧。
    private let frozenImage: NSImage

    /// 本屏可吸附候选。冻结帧存续期间窗口布局视为不变，只取一次。
    private lazy var candidates: [WindowCandidate] = {
        let own = getpid()
        let all = WindowDetector.onScreenWindows(ownPID: own)
        let snap = WindowDetector.snapCandidates(from: all, ownPID: own)
        return snap.filter { shot.bounds.intersects($0.bounds) }
    }()

    /// 选区确定后浮现的操作工具条（复制 / 保存 / 取消）。
    private lazy var actionBar: ActionBarView = {
        let bar = ActionBarView()
        bar.onCopy = { [weak self] in self?.requestCopy() }
        bar.onSave = { [weak self] in self?.requestSave() }
        bar.onCancel = { [weak self] in self?.requestCancel() }
        bar.isHidden = true
        return bar
    }()

    init(shot: DisplayShot) {
        self.shot = shot
        frozenImage = NSImage(
            cgImage: shot.image,
            size: NSSize(width: shot.bounds.width, height: shot.bounds.height)
        )
        super.init(frame: NSRect(
            x: 0, y: 0,
            width: shot.bounds.width,
            height: shot.bounds.height
        ))
        addSubview(actionBar)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        if showsCrosshair {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // 用 NSImage 绘制，避免 CGImage 直接进 CGContext 时的上下翻转。
        frozenImage.draw(in: bounds)
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
        updateActionBar()
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
        updateActionBar()
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
            updateActionBar()
            needsDisplay = true
            return
        }
        isCommitted = true
        commitSelection()
        updateActionBar()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            NotificationCenter.default.post(name: .snipEscapePressed, object: nil)
        case 36: // Return
            guard isCommitted, !selectionRect.isEmpty else {
                NSSound.beep()
                return
            }
            requestCopy()
        // ⌘S 只认 command，⌘⌃S / ⌘⌥S 不是保存快捷键
        case 1 where event.modifierFlags.intersection([.command, .control, .option]) == .command:
            guard isCommitted, !selectionRect.isEmpty else {
                NSSound.beep()
                return
            }
            requestSave()
        default:
            super.keyDown(with: event)
        }
    }

    /// 光标下的窗口：视图坐标 → CG 全局坐标后在本屏候选里取最顶层命中。
    private func windowUnderMouse(at viewPoint: CGPoint) -> WindowCandidate? {
        let globalPoint = RectMath.toGlobalPoint(
            viewPoint: viewPoint,
            displayBounds: shot.bounds,
            viewHeight: bounds.height
        )
        return WindowDetector.window(at: globalPoint, in: candidates)
    }

    /// 选区确定后把工具条摆在选区右下角外侧；下方放不下时收进选区内。
    private func updateActionBar() {
        guard isCommitted, !selectionRect.isEmpty else {
            actionBar.isHidden = true
            return
        }
        actionBar.isHidden = false
        let size = actionBar.frame.size
        var origin = CGPoint(
            x: selectionRect.maxX - size.width,
            y: selectionRect.minY - size.height - 6
        )
        if origin.y < bounds.minY + 4 {
            origin.y = selectionRect.minY + 6
        }
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - size.width - 4)
        actionBar.frame = NSRect(origin: origin, size: size)
    }

    private func commitSelection() {
        NotificationCenter.default.post(
            name: .snipCommitted,
            object: nil,
            userInfo: [
                SnipNotificationKey.viewRect: selectionRect,
                SnipNotificationKey.viewHeight: bounds.height,
                SnipNotificationKey.scale: shot.scale,
                SnipNotificationKey.displayID: shot.displayID,
            ]
        )
    }

    private func requestCopy() {
        NotificationCenter.default.post(
            name: .snipCopyRequested,
            object: nil,
            userInfo: [SnipNotificationKey.displayID: shot.displayID]
        )
    }

    private func requestSave() {
        NotificationCenter.default.post(
            name: .snipSaveRequested,
            object: nil,
            userInfo: [SnipNotificationKey.displayID: shot.displayID]
        )
    }

    private func requestCancel() {
        NotificationCenter.default.post(name: .snipEscapePressed, object: nil)
    }

    // MARK: - 绘制

    private func drawHoverHighlight() {
        guard let rect = hoverRectInView() else { return }
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 2
        NSColor.systemBlue.setStroke()
        border.stroke()
    }

    private func drawMask() {
        let mask = NSBezierPath(rect: bounds)
        // even-odd 挖空选区/悬停窗口。.clear 混合模式会连已绘制的冻结帧一起擦掉，透出窗口黑底。
        if !selectionRect.isEmpty {
            mask.appendRect(selectionRect)
            mask.windingRule = .evenOdd
        } else if let hoverRect = hoverRectInView() {
            // 悬停窗口提亮：挖空后冻结帧原样显示，接近 Snipaste 观感
            mask.appendRect(hoverRect)
            mask.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(Self.maskAlpha).setFill()
        mask.fill()
    }

    /// 当前悬停窗口在本屏视图坐标系下的矩形；无悬停或完全在本屏外时为 nil。
    private func hoverRectInView() -> CGRect? {
        guard let window = hoverWindow else { return nil }
        let rect = RectMath.clamp(
            RectMath.toViewRect(
                globalRect: window.bounds,
                displayBounds: shot.bounds,
                viewHeight: bounds.height
            ),
            to: bounds
        )
        return rect.isEmpty ? nil : rect
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
            .font: SizeLabel.font,
            .foregroundColor: SizeLabel.textColor,
        ]
        let padding = SizeLabel.padding
        let textSize = text.size(withAttributes: attributes)
        let labelSize = NSSize(
            width: ceil(textSize.width) + padding.width * 2,
            height: ceil(textSize.height) + padding.height * 2
        )

        var origin = CGPoint(
            x: selectionRect.maxX - labelSize.width,
            y: selectionRect.maxY + SizeLabel.gap
        )
        if origin.y + labelSize.height > bounds.maxY {
            origin.y = selectionRect.maxY - labelSize.height - SizeLabel.gap
        }
        origin.x = min(
            max(origin.x, bounds.minX + SizeLabel.gap),
            bounds.maxX - labelSize.width - SizeLabel.gap
        )

        let labelRect = NSRect(origin: origin, size: labelSize)
        SizeLabel.background.setFill()
        NSBezierPath(
            roundedRect: labelRect,
            xRadius: SizeLabel.cornerRadius,
            yRadius: SizeLabel.cornerRadius
        ).fill()
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

/// 截图通知 userInfo 的键。收成封闭枚举，避免字符串字面量在两端拼错。
enum SnipNotificationKey: Hashable {
    case viewRect
    case viewHeight
    case scale
    case displayID
}

extension Dictionary where Key == AnyHashable, Value == Any {
    subscript(key: SnipNotificationKey) -> Any? {
        self[AnyHashable(key)]
    }
}
