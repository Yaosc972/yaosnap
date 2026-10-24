import AppKit
import YaosnapCore

/// 单屏覆盖视图：绘制冻结帧与选区遮罩，承载选区与标注交互。
@MainActor
final class OverlayView: NSView {
    let shot: DisplayShot

    /// 会话状态机。idling 无选区；selecting 在拖选区（origin 视图坐标，freeDrag 表示
    /// 已脱离窗口吸附）；ready 选区已确定；drawing 在拖标注（origin 画布坐标）；
    /// editing 在输入单行文字。
    private enum Phase {
        case idle
        case selecting(origin: CGPoint, freeDrag: Bool)
        case ready
        case drawing(origin: CGPoint)
        case editing
    }

    private var phase: Phase = .idle
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
    /// 标注形状任一边长小于该值视为无效，丢弃。
    private static let minimumStrokeSide: CGFloat = 2
    /// 按下到拖动的位移小于该值不脱离窗口吸附；双击确认时手抖不应清掉已确定的选区。
    private static let dragThreshold: CGFloat = 3
    /// 文字输入框的宽度范围，超出部分由单行滚动承接。
    private static let minimumTextWidth: CGFloat = 80
    private static let maximumTextWidth: CGFloat = 320

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

    /// 选区确定后浮现的标注工具条（形状 / 颜色 / 笔尖 / 复制 / 保存 / 取消）。
    private lazy var toolbar: AnnotateToolbar = {
        let bar = AnnotateToolbar(
            initialKind: toolStore.currentKind,
            initialStyle: toolStore.currentStyle
        )
        bar.onSelectTool = { [weak self] kind in self?.selectTool(kind) }
        bar.onStyleChange = { [weak self] style in self?.applyStyle(style) }
        bar.onCopy = { [weak self] in self?.requestCopy() }
        bar.onSave = { [weak self] in self?.requestSave() }
        bar.onCancel = { [weak self] in self?.requestCancel() }
        bar.isHidden = true
        return bar
    }()

    /// 每形状独立记忆颜色与笔尖。
    private var toolStore = ToolStyleStore()

    /// 两字符快捷键（RR）的首字符暂存。
    private var pendingShortcut: (key: String, at: TimeInterval)?

    /// 文字编辑控件与提交时需要的快照。origin 是画布坐标的基线起点。
    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero
    private var textStyle: Style?
    private var editingClickMonitor: Any?

    /// 标注画布。进入 ready 时创建，选区重画或清空时移除。
    private var canvas: AnnotationCanvas?

    /// 待导出标注。控制器在复制 / 保存时按 displayID 来取。
    var annotations: [Annotation] { canvas?.annotations ?? [] }

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
        addSubview(toolbar)
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
        // 有按压或已有选区时不画 hover，跳过状态更新避免整屏重绘
        guard case .idle = phase, selectionRect.isEmpty else { return }
        let hit = windowUnderMouse(at: convert(event.locationInWindow, from: nil))
        guard hit != hoverWindow else { return }
        hoverWindow = hit
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch phase {
        case .idle:
            beginSelection(at: point)
        case .ready:
            if event.clickCount == 2, selectionRect.contains(point) {
                requestCopy()
                return
            }
            guard selectionRect.contains(point) else {
                // 选区外按下：清空标注并重画选区
                removeCanvas()
                beginSelection(at: point)
                return
            }
            // 选区内按下：按当前工具起一笔 draft，单击不落形状（点序列除外，单击即圆点）
            guard let canvas else { return }
            let start = canvasPoint(from: point)
            if toolStore.currentKind == .text {
                beginTextEditing(at: point)
                return
            }
            canvas.draft = makeDraft(origin: start, current: start)
            phase = .drawing(origin: start)
        case .editing:
            commitTextEditing()
        case .selecting, .drawing:
            break // 已有按压，忽略重入
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch phase {
        case .selecting(let origin, let freeDrag):
            guard freeDrag
                || abs(point.x - origin.x) >= Self.dragThreshold
                || abs(point.y - origin.y) >= Self.dragThreshold else { return }
            phase = .selecting(origin: origin, freeDrag: true)
            // 拖动即脱离窗口锁定：按起点与当前点重算自由选区。
            // 鼠标可拖出视图范围，钳制后选区始终落在冻结帧内。
            selectionRect = RectMath.clamp(
                RectMath.normalizedRect(from: origin, to: point),
                to: bounds
            )
            needsDisplay = true
        case .drawing(let origin):
            guard let canvas else { return }
            let current = canvasPoint(from: point)
            switch toolStore.currentKind {
            case .brush, .marker, .mosaic:
                appendDraftPoint(current)
            case .rect, .roundedRect, .ellipse, .line, .arrow:
                canvas.draft = makeDraft(origin: origin, current: current)
            case .text:
                break
            }
        case .idle, .ready, .editing:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch phase {
        case .selecting:
            guard selectionRect.width >= Self.minimumSelectionSide,
                  selectionRect.height >= Self.minimumSelectionSide else {
                selectionRect = .zero
                phase = .idle
                updateActionBar()
                needsDisplay = true
                return
            }
            commitSelection()
        case .drawing:
            commitDraft()
        case .idle, .ready, .editing:
            break // ready 下单击保留选区，等待 Enter / 双击 / ⌘S
        }
    }

    override func keyDown(with event: NSEvent) {
        if case .editing = phase {
            switch event.keyCode {
            case 53: cancelTextEditing()
            case 36: commitTextEditing()
            default: break // 编辑期间不响应复制 / 保存 / 撤销 / 工具快捷键
            }
            return
        }
        switch event.keyCode {
        case 53: // Esc
            NotificationCenter.default.post(name: .snipEscapePressed, object: nil)
        case 36: // Return
            guard case .ready = phase, !selectionRect.isEmpty else {
                NSSound.beep()
                return
            }
            requestCopy()
        // ⌘S 只认 command，⌘⌃S / ⌘⌥S 不是保存快捷键
        case 1 where event.modifierFlags.intersection([.command, .control, .option]) == .command:
            guard case .ready = phase, !selectionRect.isEmpty else {
                NSSound.beep()
                return
            }
            requestSave()
        case 6 where event.modifierFlags.intersection([.command, .control, .option]) == .command: // ⌘Z
            undoLastAnnotation()
        default:
            if !handleToolShortcut(event) {
                super.keyDown(with: event)
            }
        }
    }

    /// 撤销最后一笔。ready / drawing 都可用；无标注提示音。只撤销不重做。
    private func undoLastAnnotation() {
        guard let canvas, !canvas.annotations.isEmpty else {
            NSSound.beep()
            return
        }
        canvas.annotations.removeLast()
    }

    /// 工具快捷键：无修饰键时匹配 ShapeCatalog 的 shortcut 字符。
    /// 两字符 shortcut（RR）靠短时间内连按两次首字符进入。
    private func handleToolShortcut(_ event: NSEvent) -> Bool {
        guard case .ready = phase,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let key = event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty
        else { return false }
        let first = String(key.prefix(1))
        let now = ProcessInfo.processInfo.systemUptime
        if let pending = pendingShortcut, now - pending.at < 0.5 {
            if let entry = ShapeCatalog.p2.first(where: { $0.shortcut == pending.key + first }) {
                pendingShortcut = nil
                selectTool(entry.kind)
                return true
            }
        }
        guard let entry = ShapeCatalog.p2.first(where: { $0.shortcut == first }) else { return false }
        pendingShortcut = (key: first, at: now)
        selectTool(entry.kind)
        return true
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

    /// 视图点 → 画布点。画布 frame 与选区重合，减去选区原点即得。
    private func canvasPoint(from viewPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(viewPoint.x - selectionRect.minX, 0), selectionRect.width),
            y: min(max(viewPoint.y - selectionRect.minY, 0), selectionRect.height)
        )
    }

    /// 开始一次选区拖拽。起点落在窗口内 → 初始选区为整个窗口；拖动后才脱离窗口锁定。
    private func beginSelection(at point: CGPoint) {
        hoverWindow = nil
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
        phase = .selecting(origin: point, freeDrag: false)
        updateActionBar()
        needsDisplay = true
    }

    /// 选区确定：边界取整保证预览与导出位图尺寸一致，然后进入 ready。
    private func commitSelection() {
        selectionRect = selectionRect.integral
        phase = .ready
        setupCanvas()
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
        updateActionBar()
    }

    /// 拖拽的标注落笔。矩形系两边不足、线系位移不足则丢弃，单击不产生形状；
    /// 点序列非空即提交，单击落成圆点。
    private func commitDraft() {
        guard let canvas, let draft = canvas.draft, isDraftValid(draft) else {
            if let canvas { canvas.draft = nil }
            phase = .ready
            return
        }
        canvas.annotations.append(draft)
        canvas.draft = nil
        phase = .ready
    }

    private func isDraftValid(_ draft: Annotation) -> Bool {
        switch draft.shape {
        case .rect(let rect), .roundedRect(let rect, _), .ellipse(let rect):
            return rect.width >= Self.minimumStrokeSide && rect.height >= Self.minimumStrokeSide
        case .line(let from, let to), .arrow(let from, let to):
            // 水平/垂直线的 bounds 有一边为 0，按位移判断
            return hypot(to.x - from.x, to.y - from.y) >= Self.minimumStrokeSide
        case .brush, .marker, .mosaic:
            return true
        case .text:
            return false
        }
    }

    // MARK: - 文字编辑

    /// 单击进入编辑态。输入框按渲染同一份度量定位，框内文字垂直居中，
    /// 框高取 ascent+descent 时基线正好落在点击点，提交前后文字不跳。
    private func beginTextEditing(at viewPoint: CGPoint) {
        guard let canvas else { return }
        let style = canvas.currentStyle
        let fontSize = style.pen.textFontSize
        let line = TextMetrics.lineHeight(fontSize: fontSize)
        let width = min(
            max(Self.minimumTextWidth, selectionRect.maxX - viewPoint.x),
            Self.maximumTextWidth
        )
        let field = NSTextField(frame: NSRect(
            x: viewPoint.x,
            y: viewPoint.y - line.descent,
            width: width,
            height: ceil(line.ascent + line.descent)
        ))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        let ink = NSColor(
            srgbRed: style.color.r,
            green: style.color.g,
            blue: style.color.b,
            alpha: 1
        )
        field.textColor = ink
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.target = self
        field.action = #selector(textFieldSubmitted(_:))
        field.delegate = self
        addSubview(field, positioned: .above, relativeTo: canvas)
        textField = field
        textStyle = style
        textOrigin = canvasPoint(from: viewPoint)
        phase = .editing
        window?.makeFirstResponder(field)
        // 编辑态由 field editor 绘制，颜色要单独下发，否则用系统默认色。
        if let editor = field.currentEditor() as? NSTextView {
            editor.textColor = ink
            editor.insertionPointColor = ink
        }
        installOutsideClickCommit()
    }

    @objc private func textFieldSubmitted(_ sender: NSTextField) {
        commitTextEditing()
    }

    private func commitTextEditing() {
        guard case .editing = phase, let field = textField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = textOrigin
        let style = textStyle
        endTextEditing()
        phase = .ready
        window?.makeFirstResponder(self)
        guard !text.isEmpty, let canvas, let style else { return }
        canvas.annotations.append(Annotation(
            shape: .text(text, origin: origin, fontSize: style.pen.textFontSize),
            style: style
        ))
    }

    private func cancelTextEditing() {
        guard case .editing = phase else { return }
        endTextEditing()
        phase = .ready
        window?.makeFirstResponder(self)
    }

    private func endTextEditing() {
        if let monitor = editingClickMonitor {
            NSEvent.removeMonitor(monitor)
            editingClickMonitor = nil
        }
        // 先摘引用再移除视图：移除会触发失焦回调，引用已空时提交逻辑自然跳过。
        let field = textField
        textField = nil
        field?.removeFromSuperview()
        textStyle = nil
    }

    /// 工具条等子视图会先吃掉鼠标事件，编辑期间靠本地监听补上"点外部提交"。
    private func installOutsideClickCommit() {
        editingClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self,
                  case .editing = self.phase,
                  let field = self.textField,
                  event.windowNumber == field.window?.windowNumber
            else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard !field.frame.contains(point) else { return event }
            // 工具条点击交给失焦提交，这样按钮同一次点击就能响应。
            guard !self.toolbar.frame.contains(point) else { return event }
            self.commitTextEditing()
            return nil
        }
    }

    /// 按当前工具构建 draft。origin == current 表示笔画起点。
    private func makeDraft(origin: CGPoint, current: CGPoint) -> Annotation? {
        guard let canvas else { return nil }
        let style = canvas.currentStyle
        switch toolStore.currentKind {
        case .rect:
            return Annotation(shape: .rect(RectMath.normalizedRect(from: origin, to: current)), style: style)
        case .roundedRect:
            let rect = RectMath.normalizedRect(from: origin, to: current)
            // 圆角半径取短边 1/4，与 Snipaste 观感近似
            return Annotation(
                shape: .roundedRect(rect, radius: min(rect.width, rect.height) * 0.25),
                style: style
            )
        case .ellipse:
            return Annotation(shape: .ellipse(RectMath.normalizedRect(from: origin, to: current)), style: style)
        case .line:
            return Annotation(shape: .line(from: origin, to: current), style: style)
        case .arrow:
            return Annotation(shape: .arrow(from: origin, to: current), style: style)
        case .brush:
            return Annotation(shape: .brush([current]), style: style)
        case .marker:
            return Annotation(shape: .marker([current]), style: style)
        case .mosaic:
            return Annotation(shape: .mosaic([current]), style: style)
        case .text:
            return nil
        }
    }

    /// 点序列形状增量加点，1pt 内的点忽略，避免原地震动堆积重复点。
    private func appendDraftPoint(_ point: CGPoint) {
        guard let canvas, let draft = canvas.draft else { return }
        func grown(_ points: [CGPoint]) -> [CGPoint]? {
            guard let last = points.last,
                  hypot(point.x - last.x, point.y - last.y) >= 1
            else { return nil }
            return points + [point]
        }
        let updated: Shape?
        switch draft.shape {
        case .brush(let points): updated = grown(points).map { .brush($0) }
        case .marker(let points): updated = grown(points).map { .marker($0) }
        case .mosaic(let points): updated = grown(points).map { .mosaic($0) }
        case .rect, .roundedRect, .ellipse, .line, .arrow: updated = nil
        case .text: updated = nil
        }
        if let updated {
            canvas.draft = Annotation(id: draft.id, shape: updated, style: draft.style)
        }
    }

    /// 选区确定后创建标注画布，frame 与选区重合。
    private func setupCanvas() {
        let imageRect = RectMath.imageRect(
            fromViewRect: selectionRect,
            viewHeight: bounds.height,
            scale: shot.scale
        )
        let newCanvas = AnnotationCanvas(
            base: shot.image,
            cropOriginPx: CGPoint(x: imageRect.minX, y: imageRect.minY),
            scale: shot.scale,
            initialStyle: toolStore.currentStyle
        )
        // 画布压在工具条下面；hitTest 返回 nil，鼠标事件不受它遮挡。
        addSubview(newCanvas, positioned: .below, relativeTo: toolbar)
        newCanvas.frame = selectionRect
        canvas = newCanvas
    }

    private func removeCanvas() {
        canvas?.removeFromSuperview()
        canvas = nil
    }

    private func updateActionBar() {
        guard case .ready = phase, !selectionRect.isEmpty else {
            toolbar.isHidden = true
            return
        }
        toolbar.isHidden = false
        toolbar.frame.origin = ToolbarPlacement.origin(
            toolbarSize: toolbar.frame.size,
            selection: selectionRect,
            within: bounds
        )
    }

    /// AnnotateToolbar.onSelectTool / 快捷键：切工具并读回该工具的记忆样式。
    private func selectTool(_ kind: ShapeKind) {
        canvas?.currentStyle = toolStore.select(kind)
        toolbar.select(kind)
    }

    /// AnnotateToolbar.onStyleChange：样式写回当前工具的记忆。
    private func applyStyle(_ style: Style) {
        toolStore.update(style)
        canvas?.currentStyle = style
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

extension OverlayView: NSTextFieldDelegate {
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelTextEditing()
        return true
    }

    /// 失焦即提交：点工具条或别处让字段让出 first responder 时走这里，
    /// 这样按钮的同一次点击既能提交也不用吞事件。
    func controlTextDidEndEditing(_ obj: Notification) {
        guard case .editing = phase else { return }
        commitTextEditing()
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
