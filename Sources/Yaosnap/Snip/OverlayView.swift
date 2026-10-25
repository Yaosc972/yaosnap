import AppKit
import YaosnapCore

/// 单屏覆盖视图：绘制冻结帧与选区遮罩，承载选区与标注交互。
@MainActor
final class OverlayView: NSView {
    let shot: DisplayShot
    /// 取色模式：放大镜常驻，单击取样后结束会话而不是开始框选。
    private let pickColorMode: Bool
    var onPickColor: (() -> Void)?

    /// 会话状态机。idling 无选区；selecting 在拖选区（origin 视图坐标，freeDrag 表示
    /// 已脱离窗口吸附）；ready 选区已确定；drawing 在拖标注（origin 画布坐标）；
    /// polylineEditing 折线已落下首点、等待后续顶点（points 是已确认顶点）；
    /// editing 在输入文字；selected 选中了一组标注；moving 在拖动整组（grab 是画布坐标的
    /// 按下点，originals 是按下时每个形状，拖动全程按它平移）；marquee 在选择模式下拖框选
    /// （base 是追加框选前的集合）；resizingText / rotatingText
    /// 在拖文字控制点（center 是未旋转包围盒中心，original 是按下时的形状）；
    /// resizingShape 在拖面状形状的四角（recorded 表示这次拖动已压过撤销栈）。
    private enum Phase {
        case idle
        case selecting(origin: CGPoint, freeDrag: Bool)
        case ready
        case drawing(origin: CGPoint)
        case polylineEditing(points: [CGPoint])
        case editing
        case selected(ids: Set<UUID>)
        /// pendingClones 非空表示这是 Control 按下起的克隆拖动：真正挪动时才把副本入列，
        /// 只是点一下不会留下多余副本。recorded 保证整组一次拖动只压一次撤销快照。
        case moving(
            ids: Set<UUID>,
            grab: CGPoint,
            originals: [UUID: Shape],
            pendingClones: [Annotation]?,
            recorded: Bool
        )
        case marquee(origin: CGPoint, base: Set<UUID>, additive: Bool)
        case resizingText(id: UUID, corner: TextHandle, original: Shape, center: CGPoint)
        case rotatingText(id: UUID, original: Shape, center: CGPoint)
        case resizingShape(id: UUID, corner: ShapeHandle, original: Shape, recorded: Bool)
    }

    /// 工具模式。select 时鼠标只做选中与移动，不落新形状；draw 时行为与之前一致。
    private enum ToolMode: Equatable {
        case select
        case draw(ShapeKind)
    }

    private var phase: Phase = .idle
    private var toolMode: ToolMode = .draw(.rect)
    /// 光标下的可吸附窗口（全局坐标）。nil 表示光标不在任何窗口上。
    private var hoverWindow: WindowCandidate?
    /// 当前选区（视图坐标，左下原点）。空矩形表示尚未选中。
    private(set) var selectionRect: CGRect = .zero

    /// 是否显示十字光标。保存面板等场景由控制器临时关闭。
    var showsCrosshair = true {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    /// 新标注创建后是否自动选中，来自设置，默认开启。
    var autoSelectOnCreation = true

    /// 选区宽高比，来自设置。改写后只刷新工具条上的比例标签。
    var selectionAspectRatio: SelectionAspectRatio = .free {
        didSet { toolbar.updateAspectRatio(selectionAspectRatio) }
    }

    private static let maskAlpha: CGFloat = 0.32
    private static let minimumSelectionSide: CGFloat = 1
    /// 标注形状任一边长小于该值视为无效，丢弃。
    private static let minimumStrokeSide: CGFloat = 2
    /// 按下到拖动的位移小于该值不脱离窗口吸附；双击确认时手抖不应清掉已确定的选区。
    private static let dragThreshold: CGFloat = 3
    /// 选择工具命中测试的容差：细线条点击偏几个点也能选中。
    private static let hitTolerance: CGFloat = 4
    /// 文字与面状形状控制点共用的命中半径。比绘制的方块略大，按下不要求像素级精确。
    private static let handleHitRadius: CGFloat = 8
    /// 文字编辑器的最小宽度。选区右侧不够宽时向右溢出，保证插入点始终可输入。
    private static let minimumTextWidth: CGFloat = 80

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
    /// 当前显示的图像。回放历史时换成历史截图，翻回 index 0 恢复实时冻结帧。
    private var activeImage: NSImage
    private var activeSource: CGImage
    private var activeScaleX: CGFloat
    private var activeScaleY: CGFloat
    /// 最近成功输出的截图。0 表示本次实时冻结帧，1 是最新历史。
    private let history: [CaptureHistoryEntry]
    private(set) var historyIndex = 0
    /// warp 不生效只提示一次，避免每次按键刷日志。
    private var didWarnCursorWarp = false

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
            initialStyle: toolStore.currentStyle,
            initialAspectRatio: selectionAspectRatio
        )
        bar.onSelectTool = { [weak self] kind in self?.selectTool(kind) }
        bar.onSelectMode = { [weak self] in self?.enterSelectMode() }
        bar.onStyleChange = { [weak self] style in self?.applyStyle(style) }
        bar.onCopy = { [weak self] in self?.requestCopy() }
        bar.onExtractText = { [weak self] in self?.requestTextRecognition() }
        bar.onScanBarcode = { [weak self] in self?.requestBarcodeScan() }
        bar.onSave = { [weak self] in self?.requestSave() }
        bar.onQuickSave = { [weak self] in self?.requestSave(quick: true) }
        bar.onShare = { [weak self] in self?.requestShare() }
        bar.onCancel = { [weak self] in self?.requestCancel() }
        bar.isHidden = true
        return bar
    }()

    /// 每形状独立记忆颜色与笔尖。
    private var toolStore = ToolStyleStore()

    /// 应用内剪贴板。二次编辑的复制粘贴不碰系统剪贴板。
    private var copiedAnnotations: [Annotation] = []

    /// 框选矩形（画布坐标，y 向上）。只在 marquee 阶段非空。
    private var marqueeRect: CGRect = .zero

    /// 两字符快捷键（RR）的首字符暂存。
    private var pendingShortcut: (key: String, at: TimeInterval)?

    /// 放大镜可见性由 Option 按住或正在拖选区两种来源决定。
    private(set) var isMagnifierVisible = false
    private var isOptionDown = false
    private var isShiftDown = false
    private var magnifierCursor: CGPoint?
    /// 取色格式。Shift 在 Hex 与 rgb() 之间切换，切换结果保留到本次截图结束。
    private(set) var colorFormat: ColorFormat = .hex
    private var colorFeedback: String?
    private var colorFeedbackToken = 0

    /// 文字编辑控件与提交时需要的快照。origin 是画布坐标的基线起点。
    private var textEditor: AnnotatingTextView?
    private var textOrigin: CGPoint = .zero
    private var textStyle: Style?
    private var editingClickMonitor: Any?

    /// 标注画布。进入 ready 时创建，选区重画或清空时移除。
    private var canvas: AnnotationCanvas?

    /// 标注层快照撤销 / 重做。一次擦除可能删掉多条，快照比逐条命令更简单，也能原样恢复顺序。
    private var annotationHistory = SnapshotHistory<AnnotationSnapshot>()
    private struct AnnotationSnapshot {
        var annotations: [Annotation]
        var nextSerial: Int
    }

    /// 橡皮擦拖动的上一落点与"本次拖动已压栈"标记。
    private var eraserLastPoint: CGPoint?
    private var eraserPushedUndo = false

    /// 待导出标注。控制器在复制 / 保存时按 displayID 来取。
    var annotations: [Annotation] { canvas?.annotations ?? [] }

    init(
        shot: DisplayShot,
        history: [CaptureHistoryEntry] = [],
        pickColorMode: Bool = false,
        initialHistoryIndex: Int = 0
    ) {
        self.shot = shot
        self.history = history
        self.pickColorMode = pickColorMode
        let frozen = NSImage(
            cgImage: shot.image,
            size: NSSize(width: shot.bounds.width, height: shot.bounds.height)
        )
        frozenImage = frozen
        activeImage = frozen
        activeSource = shot.image
        activeScaleX = shot.scale
        activeScaleY = shot.scale
        super.init(frame: NSRect(
            x: 0, y: 0,
            width: shot.bounds.width,
            height: shot.bounds.height
        ))
        addSubview(toolbar)
        // 从菜单历史进入时直接停在该张；0 仍是本次实时冻结帧。
        historyIndex = min(max(initialHistoryIndex, 0), history.count)
        if historyIndex > 0 { applyHistoryImage() }
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
        activeImage.draw(in: bounds)
        drawMask()
        if selectionRect.isEmpty {
            drawHoverHighlight()
        } else {
            drawSelectionBorder()
            drawSizeLabel()
        }
        drawMarquee()
        drawMagnifier()
        drawHistoryLabel()
    }

    // MARK: - 鼠标交互

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        magnifierCursor = point
        refreshMagnifier()
        if case .polylineEditing(let points) = phase {
            updatePolylinePreview(points, cursor: canvasPoint(from: point))
            return
        }
        // 有按压或已有选区时不画 hover，跳过状态更新避免整屏重绘
        guard case .idle = phase, selectionRect.isEmpty else { return }
        let hit = windowUnderMouse(at: point)
        guard hit != hoverWindow else { return }
        hoverWindow = hit
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        magnifierCursor = point
        defer { refreshMagnifier() }
        switch phase {
        case .idle:
            if pickColorMode {
                copyMagnifierColor()
                onPickColor?()
            } else {
                beginSelection(at: point)
            }
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
            if isSelectMode {
                selectModeMouseDown(at: point, event: event)
                return
            }
            beginDraft(at: point)
        case .polylineEditing(let points):
            // 双击结束：第一次按下已追加顶点，第二次按下只提交。
            if event.clickCount >= 2 {
                commitPolyline()
                return
            }
            appendPolylinePoint(canvasPoint(from: point), to: points)
        case .selected(let ids):
            // 自动选中后仍要保留双击复制的既有节奏，否则双击会落到拖动分支。
            if event.clickCount == 2, selectionRect.contains(point) {
                requestCopy()
                return
            }
            // 控制点优先于文字本体，也优先于"点在选区外"的取消逻辑：
            // 旋转圆点可能落在选区边缘外。
            if let hit = textHandleHit(at: rawCanvasPoint(from: point)) {
                beginTextHandleDrag(hit)
                return
            }
            if let hit = shapeHandleHit(at: rawCanvasPoint(from: point)) {
                beginShapeHandleDrag(hit)
                return
            }
            guard selectionRect.contains(point) else {
                removeCanvas()
                beginSelection(at: point)
                return
            }
            if isSelectMode {
                selectModeMouseDown(at: point, event: event)
                return
            }
            // 画完自动选中后仍在 draw 模式：按在选中的形状上直接拖，按在别处开新一笔。
            let start = canvasPoint(from: point)
            if let hit = hitAnnotation(at: start), ids.contains(hit.id) {
                phase = .moving(
                    ids: ids,
                    grab: start,
                    originals: movingOriginals(for: ids),
                    pendingClones: nil,
                    recorded: false
                )
                return
            }
            clearSelection()
            beginDraft(at: point)
        case .editing:
            commitTextEditing()
        case .selecting, .drawing, .moving, .marquee,
             .resizingText, .rotatingText, .resizingShape:
            break // 已有按压，忽略重入
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        magnifierCursor = point
        defer { refreshMagnifier() }
        switch phase {
        case .selecting(let origin, let freeDrag):
            guard freeDrag
                || abs(point.x - origin.x) >= Self.dragThreshold
                || abs(point.y - origin.y) >= Self.dragThreshold else { return }
            phase = .selecting(origin: origin, freeDrag: true)
            // 拖动即脱离窗口锁定：按起点与当前点重算选区，固定比例时按比例扩展。
            // 鼠标可拖出视图范围，两种路径都把结果限制在冻结帧内。
            if let ratio = selectionAspectRatio.value {
                selectionRect = RectMath.aspectRect(
                    from: origin,
                    to: point,
                    ratio: ratio,
                    within: bounds,
                    minimumSide: Self.minimumSelectionSide
                )
            } else {
                selectionRect = RectMath.clamp(
                    RectMath.normalizedRect(from: origin, to: point),
                    to: bounds
                )
            }
            needsDisplay = true
        case .drawing(let origin):
            guard let canvas else { return }
            let current = canvasPoint(from: point)
            if toolStore.currentKind == .eraser {
                eraseAnnotations(from: eraserLastPoint ?? origin, to: current)
                eraserLastPoint = current
                return
            }
            switch toolStore.currentKind {
            case .brush, .marker, .mosaic, .blur:
                appendDraftPoint(current)
            case .rect, .roundedRect, .ellipse, .line, .arrow, .polyline:
                canvas.draft = makeDraft(origin: origin, current: current)
            case .serial, .text, .eraser:
                break
            }
        case .moving(let ids, let grab, let originals, let pendingClones, let recorded):
            guard let canvas else { return }
            let current = canvasPoint(from: point)
            var moveIDs = ids
            var moveOriginals = originals
            var didRecord = recorded
            // 克隆副本在第一次真实拖动时才入列，平移基准仍是按下时的形状。
            if let clones = pendingClones {
                pushUndoSnapshot()
                canvas.annotations.append(contentsOf: clones)
                moveIDs = Set(clones.map(\.id))
                moveOriginals = Dictionary(
                    uniqueKeysWithValues: clones.map { ($0.id, $0.shape) }
                )
                didRecord = true
                canvas.selectedIDs = moveIDs
                phase = .moving(
                    ids: moveIDs,
                    grab: grab,
                    originals: moveOriginals,
                    pendingClones: nil,
                    recorded: true
                )
            }
            let delta = CGPoint(x: current.x - grab.x, y: current.y - grab.y)
            // 整组一次拖动只压一次栈；按下未移动的单击不产生撤销步。
            if !didRecord, delta != .zero {
                pushUndoSnapshot()
                didRecord = true
                phase = .moving(
                    ids: moveIDs,
                    grab: grab,
                    originals: moveOriginals,
                    pendingClones: nil,
                    recorded: true
                )
            }
            for index in canvas.annotations.indices where moveIDs.contains(canvas.annotations[index].id) {
                guard let original = moveOriginals[canvas.annotations[index].id] else { continue }
                canvas.annotations[index].shape = original.translated(by: delta)
            }
        case .marquee(let origin, _, _):
            marqueeRect = RectMath.normalizedRect(from: origin, to: canvasPoint(from: point))
            needsDisplay = true
        case .resizingText(let id, let corner, let original, let center):
            guard let canvas,
                  case .text(let text, _, let fontSize, let rotation) = original,
                  let geometry = original.textGeometry,
                  let index = canvas.annotations.firstIndex(where: { $0.id == id }) else { return }
            let current = rawCanvasPoint(from: point)
            let startDistance = hypot(
                geometry.point(for: corner).x - center.x,
                geometry.point(for: corner).y - center.y
            )
            let currentDistance = hypot(current.x - center.x, current.y - center.y)
            let newSize = TextGeometry.scaledFontSize(
                fontSize,
                from: startDistance,
                to: currentDistance
            )
            // Shift 拖角把旋转过的文字拉回水平，缩放照常。
            let newRotation = event.modifierFlags.contains(.shift) ? 0 : rotation
            canvas.annotations[index].shape = .text(
                text,
                origin: TextMetrics.origin(text: text, fontSize: newSize, centeredAt: center),
                fontSize: newSize,
                rotation: newRotation
            )
        case .rotatingText(let id, let original, let center):
            guard let canvas,
                  case .text(let text, let origin, let fontSize, _) = original,
                  let index = canvas.annotations.firstIndex(where: { $0.id == id }) else { return }
            let current = rawCanvasPoint(from: point)
            // 手柄在正上方时为 0 度；减去 π/2 让水平拖动对应水平文字。
            let angle = atan2(current.y - center.y, current.x - center.x) - .pi / 2
            canvas.annotations[index].shape = .text(
                text,
                origin: origin,
                fontSize: fontSize,
                rotation: angle
            )
        case .resizingShape(let id, let corner, let original, let recorded):
            guard let canvas,
                  let index = canvas.annotations.firstIndex(where: { $0.id == id }) else { return }
            let box = ShapeResize.resizedBox(
                original.bounds,
                corner: corner,
                to: rawCanvasPoint(from: point),
                minimum: Self.minimumStrokeSide
            )
            // 第一次真正拖动才压栈，点一下控制点不会留下空撤销步。
            if !recorded {
                pushUndoSnapshot()
                phase = .resizingShape(id: id, corner: corner, original: original, recorded: true)
            }
            canvas.annotations[index].shape = original.resized(to: box)
        case .idle, .ready, .polylineEditing, .editing, .selected:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        magnifierCursor = convert(event.locationInWindow, from: nil)
        defer { refreshMagnifier() }
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
        case .drawing(let origin):
            if toolStore.currentKind == .eraser {
                canvas?.draft = nil
                eraserLastPoint = nil
                eraserPushedUndo = false
                phase = .ready
                return
            }
            let current = canvasPoint(from: convert(event.locationInWindow, from: nil))
            if toolStore.currentKind == .polyline,
               hypot(current.x - origin.x, current.y - origin.y) < Self.dragThreshold,
               let draft = canvas?.draft {
                // 点按落下首点进入折线编辑；拖拽按直线规则提交。
                canvas?.draft = Annotation(
                    id: draft.id,
                    shape: .polyline([origin]),
                    style: draft.style
                )
                phase = .polylineEditing(points: [origin])
                return
            }
            commitDraft()
        case .moving(let ids, _, _, _, _):
            phase = .selected(ids: ids)
            canvas?.selectedIDs = ids
        case .marquee(_, let base, let additive):
            let hits = AnnotationSelection.ids(
                in: canvas?.annotations ?? [],
                intersecting: marqueeRect
            )
            let ids = additive ? base.union(hits) : hits
            marqueeRect = .zero
            applySelection(ids)
            needsDisplay = true
        case .resizingText(let id, _, let original, _), .rotatingText(let id, let original, _):
            discardRedoIfChanged(id, from: original)
            phase = .selected(ids: [id])
            canvas?.selectedIDs = [id]
        case .resizingShape(let id, _, _, _):
            phase = .selected(ids: [id])
            canvas?.selectedIDs = [id]
        case .idle, .ready, .polylineEditing, .editing, .selected:
            break // ready 下单击保留选区，等待 Enter / 双击 / ⌘S
        }
    }

    /// 右键：绘制中结束当前笔画，折线编辑中提交折线，文字编辑中不打断输入，其余取消截图。
    override func rightMouseDown(with event: NSEvent) {
        switch phase {
        case .editing:
            break
        case .drawing:
            commitDraft()
        case .polylineEditing:
            commitPolyline()
        default:
            requestCancel()
        }
    }

    /// 滚轮调笔宽。向上滚变粗，钳制在 5 档内。
    override func scrollWheel(with event: NSEvent) {
        guard isReadyOrSelected, event.scrollingDeltaY != 0 else {
            super.scrollWheel(with: event)
            return
        }
        let step = event.scrollingDeltaY > 0 ? 1 : -1
        let raw = min(max(toolStore.currentStyle.pen.rawValue + step, 1), 5)
        guard let pen = PenSize(rawValue: raw) else { return }
        applyPen(pen)
    }

    // MARK: - 二次编辑

    /// 选择模式按下：命中则选中或起拖；Control 按下克隆整组再拖副本；Shift 追加 / 移除；
    /// 空白处拖动框选，Shift 拖框追加到当前集合。
    private func selectModeMouseDown(at viewPoint: CGPoint, event: NSEvent) {
        guard let canvas else { return }
        let start = canvasPoint(from: viewPoint)
        let shift = event.modifierFlags.contains(.shift)
        guard let hit = hitAnnotation(at: start) else {
            let base = shift ? canvas.selectedIDs : []
            marqueeRect = .zero
            phase = .marquee(origin: start, base: base, additive: shift)
            needsDisplay = true
            return
        }
        if shift {
            var ids = canvas.selectedIDs
            if ids.contains(hit.id) {
                ids.remove(hit.id)
            } else {
                ids.insert(hit.id)
            }
            applySelection(ids)
            return
        }
        let ids = canvas.selectedIDs.contains(hit.id) ? canvas.selectedIDs : [hit.id]
        if event.modifierFlags.contains(.control) {
            let selected = canvas.annotations.filter { ids.contains($0.id) }
            let clones = selected.map { Annotation(shape: $0.shape, style: $0.style) }
            canvas.selectedIDs = ids
            phase = .moving(
                ids: ids,
                grab: start,
                originals: movingOriginals(for: ids),
                pendingClones: clones,
                recorded: false
            )
            return
        }
        if canvas.selectedIDs.contains(hit.id) {
            phase = .moving(
                ids: ids,
                grab: start,
                originals: movingOriginals(for: ids),
                pendingClones: nil,
                recorded: false
            )
            return
        }
        applySelection([hit.id])
    }

    /// 把选中集合同步到画布与状态机；空集合回到 ready。
    private func applySelection(_ ids: Set<UUID>) {
        canvas?.selectedIDs = ids
        phase = ids.isEmpty ? .ready : .selected(ids: ids)
    }

    private func movingOriginals(for ids: Set<UUID>) -> [UUID: Shape] {
        Dictionary(
            uniqueKeysWithValues: (canvas?.annotations ?? [])
                .filter { ids.contains($0.id) }
                .map { ($0.id, $0.shape) }
        )
    }

    /// 自上而下取最上层命中。
    private func hitAnnotation(at canvasPoint: CGPoint) -> Annotation? {
        canvas?.annotations.reversed().first {
            // 线宽算进容差，否则粗笔画边缘点不中。
            $0.shape.contains(canvasPoint, tolerance: Self.hitTolerance + $0.style.pen.lineWidth / 2)
        }
    }

    /// 清除选中。阶段退回 ready，选区与标注不动。
    private func clearSelection() {
        canvas?.selectedIDs = []
        marqueeRect = .zero
        switch phase {
        case .selected, .moving, .resizingShape, .marquee:
            phase = .ready
        default:
            break
        }
    }

    private func deleteSelected() {
        guard case .selected(let ids) = phase, let canvas, !ids.isEmpty else {
            NSSound.beep()
            return
        }
        let existing = ids.intersection(Set(canvas.annotations.map(\.id)))
        guard !existing.isEmpty else {
            NSSound.beep()
            return
        }
        pushUndoSnapshot()
        canvas.annotations = AnnotationSelection.removing(existing, from: canvas.annotations)
        canvas.selectedIDs = []
        phase = .ready
    }

    private func copySelected() {
        guard case .selected(let ids) = phase, let canvas else {
            NSSound.beep()
            return
        }
        let selected = canvas.annotations.filter { ids.contains($0.id) }
        guard !selected.isEmpty else {
            NSSound.beep()
            return
        }
        copiedAnnotations = selected
    }

    private func pasteAnnotation() {
        guard !copiedAnnotations.isEmpty, let canvas else {
            NSSound.beep()
            return
        }
        let pasted = copiedAnnotations.map {
            Annotation(
                shape: $0.shape.translated(by: CGPoint(x: 12, y: 12)),
                style: $0.style
            )
        }
        pushUndoSnapshot()
        canvas.annotations.append(contentsOf: pasted)
        // 连续粘贴以新副本为源，否则每次偏移基准相同，多个副本会叠在同一处。
        copiedAnnotations = pasted
        applySelection(Set(pasted.map(\.id)))
        // 粘贴后切到选择模式，用户可以直接拖动刚贴出的副本。
        toolMode = .select
        toolbar.selectMode()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            if case .polylineEditing = phase {
                cancelPolyline()
                return
            }
            // 有选中时 Esc 只清选中，不退出截图；选区与标注都保留。
            if case .selected = phase {
                clearSelection()
                return
            }
            NotificationCenter.default.post(name: .snipEscapePressed, object: nil)
        case 36: // Return
            if case .polylineEditing = phase {
                commitPolyline()
                return
            }
            guard canOutput, !selectionRect.isEmpty else {
                NSSound.beep()
                return
            }
            requestCopy()
        // 放大镜可见时的 C 只取色，不与 ⌘⇧C（复制标注）混淆。
        case 8 where isMagnifierVisible
            && event.modifierFlags.intersection([.command, .control]).isEmpty:
            copyMagnifierColor()
        case 48: // Tab：直线 / 箭头互换
            guard isReadyOrSelected,
                  case .draw(let kind) = toolMode,
                  kind == .line || kind == .arrow else {
                super.keyDown(with: event)
                return
            }
            selectTool(kind == .line ? .arrow : .line)
        // ⌘S 只认 command，⌘⌃S / ⌘⌥S 不是保存快捷键
        case 1 where event.modifierFlags.intersection([.command, .control, .option]) == .command:
            guard canOutput, !selectionRect.isEmpty else {
                NSSound.beep()
                return
            }
            requestSave()
        case 51, 117: // Delete / Forward Delete
            deleteSelected()
        case 8 where event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command, .shift]:
            copySelected()
        case 9 where event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command, .shift]:
            pasteAnnotation()
        // shift 必须从 ⌘Z 的掩码里排除，否则 ⌘⇧Z 会被撤销抢先匹配。
        case 6 where event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command, .shift]:
            redoLastAnnotation()
        case 6 where event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command:
            undoLastAnnotation()
        case 123, 124, 125, 126:
            guard handleArrowKey(event) else {
                super.keyDown(with: event)
                return
            }
        // 只有存在历史时才接管 , / .，否则让事件照常向上传递。
        case 43 where canStepHistory(event):
            stepHistory(-1)
        case 47 where canStepHistory(event):
            stepHistory(1)
        default:
            if handleCursorKey(event) || handleToolShortcut(event) {
                return
            }
            super.keyDown(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        // Shift 只在按下沿切换一次；长按不会连续翻转格式。
        if shift, !isShiftDown, isMagnifierVisible {
            colorFormat = colorFormat.toggled
        }
        isOptionDown = option
        isShiftDown = shift
        refreshMagnifier()
    }

    /// 拖选区脱离窗口吸附后自动召唤放大镜；松开鼠标后仅剩 Option 一种来源。
    private var isDraggingSelection: Bool {
        if case .selecting(_, let freeDrag) = phase { return freeDrag }
        return false
    }

    /// Option 按下前还没收到过鼠标移动时，退回窗口记录的当前位置。
    private var effectiveMagnifierCursor: CGPoint? {
        if let magnifierCursor { return magnifierCursor }
        guard let window else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    private func refreshMagnifier() {
        let visible = pickColorMode || isOptionDown || isDraggingSelection
        guard visible != isMagnifierVisible else {
            if visible { needsDisplay = true }
            return
        }
        isMagnifierVisible = visible
        if !visible { colorFeedback = nil }
        needsDisplay = true
    }

    private func copyMagnifierColor() {
        guard let cursor = effectiveMagnifierCursor else { return }
        let sampler = MagnifierSampler(
            image: activeSource,
            canvasSize: bounds.size,
            scaleX: activeScaleX,
            scaleY: activeScaleY
        )
        guard let color = sampler.color(at: cursor) else {
            NSSound.beep()
            return
        }
        let text = colorFormat.string(for: color)
        guard ClipboardService.copyString(text) else {
            NSSound.beep()
            return
        }
        showColorFeedback(text)
    }

    private func showColorFeedback(_ text: String) {
        colorFeedback = text
        colorFeedbackToken &+= 1
        let token = colorFeedbackToken
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.colorFeedbackToken == token else { return }
                self.colorFeedback = nil
                self.needsDisplay = true
            }
        }
    }

    /// ready 语义的阶段：选区已确定，复制 / 保存 / 切工具都可用。
    private var isCommittedPhase: Bool {
        switch phase {
        case .ready, .selected, .moving: return true
        case .idle, .selecting, .drawing, .polylineEditing, .editing, .marquee,
             .resizingText, .rotatingText, .resizingShape: return false
        }
    }

    /// Tab 与滚轮只在选区已定、且没在拖动时生效。
    private var isReadyOrSelected: Bool {
        switch phase {
        case .ready, .selected: return true
        case .idle, .selecting, .drawing, .polylineEditing, .editing, .moving, .marquee,
             .resizingText, .rotatingText, .resizingShape: return false
        }
    }

    /// 能出图的阶段。拖动中途按 Enter / ⌘S 会把半成品输出，所以排除 moving 与缩放。
    private var canOutput: Bool {
        switch phase {
        case .ready, .selected: return true
        case .idle, .selecting, .drawing, .polylineEditing, .editing, .moving, .marquee,
             .resizingText, .rotatingText, .resizingShape: return false
        }
    }

    private var isSelectMode: Bool { toolMode == .select }

    // MARK: - 方向键与光标

    /// 方向键：裸键平移，Control 扩大，Shift 缩小。其他修饰组合不拦截。
    private func handleArrowKey(_ event: NSEvent) -> Bool {
        guard isReadyOrSelected,
              let direction = Self.arrowDirection(for: event.keyCode) else { return false }
        switch event.modifierFlags.intersection([.command, .control, .option, .shift]) {
        case []: applyNudge(direction, mode: .move)
        case .control: applyNudge(direction, mode: .expand)
        case .shift: applyNudge(direction, mode: .shrink)
        default: return false
        }
        return true
    }

    private static func arrowDirection(for keyCode: UInt16) -> NudgeDirection? {
        switch keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        default: return nil
        }
    }

    private func applyNudge(_ direction: NudgeDirection, mode: NudgeMode) {
        let updated = RectMath.nudge(
            selectionRect,
            direction: direction,
            mode: mode,
            within: bounds,
            minimumSide: Self.minimumSelectionSide,
            aspectRatio: selectionAspectRatio.value
        )
        guard updated != selectionRect else { return }
        updateSelection(updated, annotationsFollowSelection: mode == .move)
    }

    /// 方向键调整后的统一落点：画布、标注、工具条与控制器里的待输出选区。
    private func updateSelection(_ rect: CGRect, annotationsFollowSelection: Bool) {
        let previousOrigin = selectionRect.origin
        selectionRect = rect
        if let canvas {
            // 平移时框与标注一起走；边界伸缩时补偿标注坐标，让它继续贴住原截图内容。
            if !annotationsFollowSelection {
                let delta = CGPoint(
                    x: previousOrigin.x - rect.minX,
                    y: previousOrigin.y - rect.minY
                )
                if delta != .zero {
                    canvas.translateAnnotations(by: delta)
                }
            }
            canvas.frame = rect
            canvas.updateCropOrigin(cropOriginPx(for: rect))
        }
        updateActionBar()
        needsDisplay = true
        publishSelection()
    }

    /// W A S D 逐像素移动系统光标。文字编辑时事件由编辑器接收，不会走到这里。
    private func handleCursorKey(_ event: NSEvent) -> Bool {
        if case .editing = phase { return false }
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let directions: [String: NudgeDirection] = [
            "w": .up, "a": .left, "s": .down, "d": .right,
        ]
        guard let direction = directions[key] else { return false }
        moveSystemCursor(direction)
        return true
    }

    private func moveSystemCursor(_ direction: NudgeDirection) {
        guard let current = effectiveMagnifierCursor else { return }
        var next = current
        switch direction {
        case .up: next.y += 1
        case .down: next.y -= 1
        case .left: next.x -= 1
        case .right: next.x += 1
        }
        next.x = min(max(next.x, bounds.minX), max(bounds.minX, bounds.maxX - 1))
        next.y = min(max(next.y, bounds.minY), max(bounds.minY, bounds.maxY - 1))
        magnifierCursor = next
        refreshMagnifier()
        needsDisplay = true

        let global = RectMath.toGlobalPoint(
            viewPoint: next,
            displayBounds: shot.bounds,
            viewHeight: bounds.height
        )
        let beforeWarp = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(global)
        CGAssociateMouseAndMouseCursorPosition(1)
        // warp 返回 void，读回系统光标判断是否真的移动。系统会把光标贴到整数像素，
        // 所以只看位置是否变化；目标与当前位置相同（贴边）时不做判断。
        if !didWarnCursorWarp, let beforeWarp,
           hypot(beforeWarp.x - global.x, beforeWarp.y - global.y) >= 0.5,
           let actual = CGEvent(source: nil)?.location,
           abs(actual.x - beforeWarp.x) < 0.01, abs(actual.y - beforeWarp.y) < 0.01 {
            didWarnCursorWarp = true
            print("[snip] warning: 光标 warp 未生效，仅更新内部光标状态")
        }
    }

    // MARK: - 历史回放

    private func canStepHistory(_ event: NSEvent) -> Bool {
        !history.isEmpty
            && event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    }

    /// index 0 是本次实时冻结帧，1... 是历史（1 为最新）。
    private func stepHistory(_ delta: Int) {
        let next = min(max(historyIndex + delta, 0), history.count)
        guard next != historyIndex else { return }
        historyIndex = next
        applyHistoryImage()
        resetSelection()
        needsDisplay = true
    }

    private func applyHistoryImage() {
        guard historyIndex > 0 else {
            activeImage = frozenImage
            activeSource = shot.image
            activeScaleX = shot.scale
            activeScaleY = shot.scale
            return
        }
        let entry = history[historyIndex - 1]
        activeImage = NSImage(cgImage: entry.image, size: bounds.size)
        activeSource = entry.image
        activeScaleX = bounds.width > 0 ? CGFloat(entry.image.width) / bounds.width : 1
        activeScaleY = bounds.height > 0 ? CGFloat(entry.image.height) / bounds.height : 1
    }

    private func resetSelection() {
        removeCanvas()
        selectionRect = .zero
        phase = .idle
        hoverWindow = nil
        pendingShortcut = nil
        updateActionBar()
    }

    /// 撤销一步。快照恢复整组标注，橡皮擦一次拖动删掉的多条也在同一步回退。
    private func undoLastAnnotation() {
        guard let current = currentSnapshot(),
              let previous = annotationHistory.undo(current: current) else {
            NSSound.beep()
            return
        }
        restore(previous)
    }

    /// 重做一步：撤销时压入的快照原样恢复。
    private func redoLastAnnotation() {
        guard let current = currentSnapshot(),
              let next = annotationHistory.redo(current: current) else {
            NSSound.beep()
            return
        }
        restore(next)
    }

    private func currentSnapshot() -> AnnotationSnapshot? {
        guard let canvas else { return nil }
        return AnnotationSnapshot(annotations: canvas.annotations, nextSerial: canvas.nextSerial)
    }

    private func restore(_ snapshot: AnnotationSnapshot) {
        guard let canvas else { return }
        canvas.annotations = snapshot.annotations
        canvas.nextSerial = snapshot.nextSerial
        let remaining = canvas.selectedIDs.intersection(Set(canvas.annotations.map(\.id)))
        canvas.selectedIDs = remaining
        if remaining.isEmpty {
            if case .selected = phase {
                phase = .ready
            }
        } else if case .selected = phase {
            phase = .selected(ids: remaining)
        }
        needsDisplay = true
    }

    /// 文字缩放 / 旋转不进撤销栈，但一旦真的改变形状，旧的重做分支就失效。
    private func discardRedoIfChanged(_ id: UUID, from original: Shape) {
        guard let canvas,
              let current = canvas.annotations.first(where: { $0.id == id }) else { return }
        if current.shape != original {
            annotationHistory.discardRedo()
        }
    }

    /// 工具快捷键：无修饰键时匹配 ShapeCatalog 的 shortcut 字符。
    /// 两字符 shortcut（RR）靠短时间内连按两次首字符进入。
    private func handleToolShortcut(_ event: NSEvent) -> Bool {
        guard isCommittedPhase,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let key = event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty
        else { return false }
        let first = String(key.prefix(1))
        if let digit = Int(first), let pen = PenSize(rawValue: digit) {
            applyPen(pen)
            return true
        }
        if first == "V" {
            pendingShortcut = nil
            enterSelectMode()
            return true
        }
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

    /// 不钳制到选区的画布坐标。控制点可能落在选区外的边缘处，命中要用真实坐标。
    private func rawCanvasPoint(from viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: viewPoint.x - selectionRect.minX, y: viewPoint.y - selectionRect.minY)
    }

    /// 选中的文字标注及其控制点。旋转圆点最先命中，其次四角。
    private func textHandleHit(at point: CGPoint) -> (id: UUID, handle: TextHandle)? {
        guard case .selected(let ids) = phase, ids.count == 1, let id = ids.first,
              let shape = canvas?.annotations.first(where: { $0.id == id })?.shape,
              let geometry = shape.textGeometry else { return nil }
        let handles = [TextHandle.rotate] + TextHandle.allCases.filter(\.isCorner)
        for handle in handles {
            let anchor = geometry.point(for: handle)
            if hypot(point.x - anchor.x, point.y - anchor.y) <= Self.handleHitRadius {
                return (id, handle)
            }
        }
        return nil
    }

    private func beginTextHandleDrag(_ hit: (id: UUID, handle: TextHandle)) {
        guard let canvas,
              let shape = canvas.annotations.first(where: { $0.id == hit.id })?.shape,
              let geometry = shape.textGeometry else { return }
        canvas.selectedIDs = [hit.id]
        switch hit.handle {
        case .rotate:
            phase = .rotatingText(id: hit.id, original: shape, center: geometry.center)
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            phase = .resizingText(
                id: hit.id,
                corner: hit.handle,
                original: shape,
                center: geometry.center
            )
        }
    }

    /// 选中面状形状的四角命中。线状形状没有控制点，仍只显示包围盒。
    private func shapeHandleHit(at point: CGPoint) -> (id: UUID, corner: ShapeHandle)? {
        guard case .selected(let ids) = phase, ids.count == 1, let id = ids.first,
              let shape = canvas?.annotations.first(where: { $0.id == id })?.shape,
              shape.supportsResizeHandles else { return nil }
        for corner in ShapeHandle.allCases {
            let anchor = corner.point(in: shape.bounds)
            if hypot(point.x - anchor.x, point.y - anchor.y) <= Self.handleHitRadius {
                return (id, corner)
            }
        }
        return nil
    }

    private func beginShapeHandleDrag(_ hit: (id: UUID, corner: ShapeHandle)) {
        guard let canvas,
              let shape = canvas.annotations.first(where: { $0.id == hit.id })?.shape,
              shape.supportsResizeHandles else { return }
        canvas.selectedIDs = [hit.id]
        phase = .resizingShape(id: hit.id, corner: hit.corner, original: shape, recorded: false)
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
        publishSelection()
        updateActionBar()
    }

    /// 控制器在窗口入列后调用：活动窗口截屏 / 重复上次区域直接带着选区进会话。
    func applyInitialSelection(_ viewRect: CGRect) {
        guard case .idle = phase, selectionRect.isEmpty, !pickColorMode else { return }
        let clamped = RectMath.clamp(viewRect, to: bounds)
        guard clamped.width >= Self.minimumSelectionSide,
              clamped.height >= Self.minimumSelectionSide else { return }
        selectionRect = clamped
        commitSelection()
        needsDisplay = true
    }

    /// 把当前选区连同实际输出源交给控制器。方向键调整后也会重新发布。
    private func publishSelection() {
        NotificationCenter.default.post(
            name: .snipCommitted,
            object: nil,
            userInfo: [
                SnipNotificationKey.viewRect: selectionRect,
                SnipNotificationKey.viewHeight: bounds.height,
                SnipNotificationKey.scale: shot.scale,
                SnipNotificationKey.displayID: shot.displayID,
                SnipNotificationKey.sourceImage: activeSource,
                SnipNotificationKey.cropRectPx: RectMath.imageRect(
                    fromViewRect: selectionRect,
                    viewHeight: bounds.height,
                    scaleX: activeScaleX,
                    scaleY: activeScaleY
                ),
            ]
        )
    }

    private func cropOriginPx(for rect: CGRect) -> CGPoint {
        let imageRect = RectMath.imageRect(
            fromViewRect: rect,
            viewHeight: bounds.height,
            scaleX: activeScaleX,
            scaleY: activeScaleY
        )
        return CGPoint(x: imageRect.minX, y: imageRect.minY)
    }

    /// 选区内按当前工具起一笔 draft。单击不落形状（点序列除外，单击即圆点）。
    private func beginDraft(at viewPoint: CGPoint) {
        guard let canvas else { return }
        let start = canvasPoint(from: viewPoint)
        if toolStore.currentKind == .text {
            beginTextEditing(at: viewPoint)
            return
        }
        if toolStore.currentKind == .eraser {
            eraserLastPoint = start
            eraserPushedUndo = false
            canvas.draft = nil
            phase = .drawing(origin: start)
            // 单击也擦：路径退化成单点采样。
            eraseAnnotations(from: start, to: start)
            return
        }
        canvas.draft = makeDraft(origin: start, current: start)
        phase = .drawing(origin: start)
    }

    /// 拖拽的标注落笔。矩形系两边不足、线系位移不足则丢弃，单击不产生形状；
    /// 点序列非空即提交，单击落成圆点。
    private func commitDraft() {
        guard let canvas, let draft = canvas.draft, isDraftValid(draft) else {
            if let canvas { canvas.draft = nil }
            phase = .ready
            return
        }
        pushUndoSnapshot()
        canvas.annotations.append(draft)
        if case .serial = draft.shape {
            canvas.nextSerial += 1
        }
        canvas.draft = nil
        // Snipaste 的 auto_select_on_creation：新标注立即选中，可直接拖动或缩放。
        if autoSelectOnCreation {
            canvas.selectedIDs = [draft.id]
            phase = .selected(ids: [draft.id])
        }
    }

    /// 橡皮擦沿路径删除相交标注。一次拖动只压一次栈，撤销时整组恢复。
    private func eraseAnnotations(from start: CGPoint, to end: CGPoint) {
        guard let canvas else { return }
        let tolerance = toolStore.currentStyle.pen.lineWidth
        let hits = canvas.annotations.filter {
            $0.shape.intersects(path: [start, end], tolerance: tolerance)
        }
        guard !hits.isEmpty else { return }
        if !eraserPushedUndo {
            pushUndoSnapshot()
            eraserPushedUndo = true
        }
        let hitIDs = Set(hits.map(\.id))
        canvas.annotations.removeAll { hitIDs.contains($0.id) }
        if !canvas.selectedIDs.isDisjoint(with: hitIDs) {
            clearSelection()
        }
    }

    private func pushUndoSnapshot() {
        guard let snapshot = currentSnapshot() else { return }
        annotationHistory.record(snapshot)
    }

    private func isDraftValid(_ draft: Annotation) -> Bool {
        switch draft.shape {
        case .rect(let rect), .roundedRect(let rect, _), .ellipse(let rect):
            return rect.width >= Self.minimumStrokeSide && rect.height >= Self.minimumStrokeSide
        case .line(let from, let to), .arrow(let from, let to):
            // 水平/垂直线的 bounds 有一边为 0，按位移判断
            return hypot(to.x - from.x, to.y - from.y) >= Self.minimumStrokeSide
        case .brush, .marker, .mosaic, .blur, .serial:
            return true
        case .polyline(let points):
            guard points.count >= 2 else { return false }
            // 反复点在同一点不算一笔。
            return zip(points, points.dropFirst()).contains {
                hypot($0.1.x - $0.0.x, $0.1.y - $0.0.y) >= Self.minimumStrokeSide
            }
        case .text:
            return false
        }
    }

    // MARK: - 折线编辑

    /// 点按追加一个已确认顶点，同时把 draft 更新为不含预览尾点的折线。
    private func appendPolylinePoint(_ point: CGPoint, to points: [CGPoint]) {
        guard let canvas, let draft = canvas.draft else { return }
        let updated = points + [point]
        phase = .polylineEditing(points: updated)
        canvas.draft = Annotation(id: draft.id, shape: .polyline(updated), style: draft.style)
    }

    /// 鼠标移动时把光标点接在已确认顶点后做实时预览。
    private func updatePolylinePreview(_ points: [CGPoint], cursor: CGPoint) {
        guard let canvas, let draft = canvas.draft else { return }
        var preview = points
        if let last = preview.last, hypot(cursor.x - last.x, cursor.y - last.y) >= 1 {
            preview.append(cursor)
        }
        canvas.draft = Annotation(id: draft.id, shape: .polyline(preview), style: draft.style)
    }

    /// 提交时只收已确认顶点，预览尾点不落库。
    private func commitPolyline() {
        guard case .polylineEditing(let points) = phase, let canvas else { return }
        guard let draft = canvas.draft else {
            phase = .ready
            return
        }
        let finalized = Annotation(id: draft.id, shape: .polyline(points), style: draft.style)
        guard isDraftValid(finalized) else {
            canvas.draft = nil
            phase = .ready
            return
        }
        pushUndoSnapshot()
        canvas.annotations.append(finalized)
        canvas.draft = nil
        if autoSelectOnCreation {
            canvas.selectedIDs = [finalized.id]
            phase = .selected(ids: [finalized.id])
        } else {
            phase = .ready
        }
    }

    private func cancelPolyline() {
        canvas?.draft = nil
        phase = .ready
    }

    // MARK: - 文字编辑

    /// 单击进入编辑态。编辑器按渲染同一份度量定位：NSTextView 是 flipped 视图，
    /// 文本从 frame 顶部向下排，顶部留出 ascent 让第一行基线落在点击点，提交前后文字不跳。
    private func beginTextEditing(at viewPoint: CGPoint) {
        guard let canvas else { return }
        let style = canvas.currentStyle
        let fontSize = style.pen.textFontSize
        let line = TextMetrics.lineHeight(fontSize: fontSize)
        let width = max(Self.minimumTextWidth, selectionRect.maxX - viewPoint.x)
        let bottom = selectionRect.minY
        let top = viewPoint.y + line.ascent
        // 至少留三行：点击点贴近选区底部时，换行后的内容否则完全看不见。
        let height = max(3 * (line.ascent + line.descent), top - bottom)
        let editor = AnnotatingTextView(frame: NSRect(
            x: viewPoint.x,
            y: top - height,
            width: width,
            height: height
        ))
        editor.drawsBackground = false
        editor.isRichText = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        // 渲染只按 \n 硬换行。编辑器若按视图宽度软折行，编辑时看到的行数与提交后不一致。
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.font = .systemFont(ofSize: fontSize)
        let ink = NSColor(
            srgbRed: style.color.r,
            green: style.color.g,
            blue: style.color.b,
            alpha: 1
        )
        editor.textColor = ink
        editor.insertionPointColor = ink
        editor.delegate = self
        editor.onCommit = { [weak self] in self?.commitTextEditing() }
        editor.onCancel = { [weak self] in self?.cancelTextEditing() }
        addSubview(editor, positioned: .above, relativeTo: canvas)
        textEditor = editor
        textStyle = style
        textOrigin = canvasPoint(from: viewPoint)
        phase = .editing
        window?.makeFirstResponder(editor)
        installOutsideClickCommit()
    }

    /// 第一行基线要落在提交后的位置。中文走 fallback 字体，ascent 与主字体不同，
    /// 输入过程中按实际首行重新对齐一次，提交前后文字不跳。
    private func alignEditorBaseline() {
        guard let editor = textEditor, let style = textStyle else { return }
        let firstRow = editor.string.components(separatedBy: "\n").first ?? ""
        let layout = TextMetrics.multiline(
            firstRow.isEmpty ? "国" : firstRow,
            fontSize: style.pen.textFontSize,
            origin: .zero
        )
        let top = selectionRect.minY + textOrigin.y + layout.rect.maxY
        var frame = editor.frame
        frame.origin.y = top - frame.height
        if frame != editor.frame {
            editor.frame = frame
        }
    }

    private func commitTextEditing() {
        guard case .editing = phase, let editor = textEditor else { return }
        let text = editor.string
        let origin = textOrigin
        let style = textStyle
        endTextEditing()
        window?.makeFirstResponder(self)
        // 空内容丢弃；非空原样入列，换行符保留给多行渲染。
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let canvas, let style else {
            phase = .ready
            return
        }
        let annotation = Annotation(
            shape: .text(
                text,
                origin: origin,
                fontSize: style.pen.textFontSize,
                rotation: 0
            ),
            style: style
        )
        pushUndoSnapshot()
        canvas.annotations.append(annotation)
        if autoSelectOnCreation {
            canvas.selectedIDs = [annotation.id]
            phase = .selected(ids: [annotation.id])
        } else {
            phase = .ready
        }
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
        let editor = textEditor
        textEditor = nil
        editor?.removeFromSuperview()
        textStyle = nil
    }

    /// 工具条等子视图会先吃掉鼠标事件，编辑期间靠本地监听补上"点外部提交"。
    private func installOutsideClickCommit() {
        editingClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self,
                  case .editing = self.phase,
                  let editor = self.textEditor,
                  event.windowNumber == editor.window?.windowNumber
            else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard !editor.frame.contains(point) else { return event }
            self.commitTextEditing()
            // 工具条按钮 refusesFirstResponder，点击不会让编辑器失焦；
            // 提交后放行这一次点击，按钮与提交共用同一次按压。
            return self.toolbar.frame.contains(point) ? event : nil
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
        case .polyline:
            return Annotation(shape: .polyline([origin, current]), style: style)
        case .brush:
            return Annotation(shape: .brush([current]), style: style)
        case .marker:
            return Annotation(shape: .marker([current]), style: style)
        case .mosaic:
            return Annotation(shape: .mosaic([current]), style: style)
        case .blur:
            return Annotation(shape: .blur([current]), style: style)
        case .serial:
            return Annotation(
                shape: .serial(
                    value: canvas.nextSerial,
                    center: current,
                    radius: style.pen.serialRadius
                ),
                style: style
            )
        case .text, .eraser:
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
        case .blur(let points): updated = grown(points).map { .blur($0) }
        case .rect, .roundedRect, .ellipse, .line, .arrow, .polyline: updated = nil
        case .text, .serial: updated = nil
        }
        if let updated {
            canvas.draft = Annotation(id: draft.id, shape: updated, style: draft.style)
        }
    }

    /// 选区确定后创建标注画布，frame 与选区重合。
    private func setupCanvas() {
        // 新标注层配新历史，序号也从 1 重新开始。
        annotationHistory.removeAll()
        let newCanvas = AnnotationCanvas(
            base: activeSource,
            cropOriginPx: cropOriginPx(for: selectionRect),
            scale: activeScaleX,
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
        annotationHistory.removeAll()
    }

    private func updateActionBar() {
        guard isCommittedPhase, !selectionRect.isEmpty else {
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
        toolMode = .draw(kind)
        clearSelection()
        let style = toolStore.select(kind)
        canvas?.currentStyle = style
        toolbar.select(kind, style: style)
    }

    /// 数字键与滚轮共用：改当前工具笔尖，同步记忆与工具条圆点。
    private func applyPen(_ pen: PenSize) {
        var style = toolStore.currentStyle
        guard style.pen != pen else { return }
        style.pen = pen
        toolStore.update(style)
        canvas?.currentStyle = style
        toolbar.updateStyle(style)
    }

    /// AnnotateToolbar.onSelectMode / V：只切模式，不动 ToolStyleStore 记忆的 kind。
    private func enterSelectMode() {
        toolMode = .select
        clearSelection()
        toolbar.selectMode()
    }

    /// AnnotateToolbar.onStyleChange：样式写回当前工具的记忆。
    private func applyStyle(_ style: Style) {
        // 透明度是分组属性，先落组再写回工具，避免被 update 归一化掉。
        if style.color.a != toolStore.alpha(for: toolStore.currentKind) {
            toolStore.updateAlpha(style.color.a)
        }
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

    private func requestShare() {
        NotificationCenter.default.post(
            name: .snipShareRequested,
            object: nil,
            userInfo: [SnipNotificationKey.displayID: shot.displayID]
        )
    }

    private func requestTextRecognition() {
        NotificationCenter.default.post(
            name: .snipTextRecognizeRequested,
            object: nil,
            userInfo: [SnipNotificationKey.displayID: shot.displayID]
        )
    }

    private func requestBarcodeScan() {
        NotificationCenter.default.post(
            name: .snipBarcodeScanRequested,
            object: nil,
            userInfo: [SnipNotificationKey.displayID: shot.displayID]
        )
    }

    /// 识别结果回显。控制器在后台识别完成后回主线程调用。
    func showToolbarMessage(_ text: String) {
        toolbar.showMessage(text)
    }

    private func requestSave(quick: Bool = false) {
        var info: [AnyHashable: Any] = [SnipNotificationKey.displayID: shot.displayID]
        if quick { info[SnipNotificationKey.quickSave] = true }
        NotificationCenter.default.post(
            name: .snipSaveRequested,
            object: nil,
            userInfo: info
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

    /// 框选矩形画在覆盖层上，不经过画布，因此不进导出。
    private func drawMarquee() {
        guard case .marquee = phase, !marqueeRect.isEmpty else { return }
        let rect = marqueeRect.offsetBy(dx: selectionRect.minX, dy: selectionRect.minY)
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        let accent = RGBAColor.palette[5]
        func color(_ alpha: CGFloat) -> NSColor {
            NSColor(srgbRed: accent.r, green: accent.g, blue: accent.b, alpha: alpha)
        }
        color(0.10).setFill()
        path.fill()
        color(0.90).setStroke()
        let dash: [CGFloat] = [4, 3]
        path.setLineDash(dash, count: dash.count, phase: 0)
        path.stroke()
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

    /// 底部居中的历史位置标签。只在实际回放时出现。
    private func drawHistoryLabel() {
        guard historyIndex > 0 else { return }
        let text = "历史 \(historyIndex)/\(history.count)" as NSString
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
        let labelRect = NSRect(
            x: (bounds.width - labelSize.width) / 2,
            y: bounds.minY + 16,
            width: labelSize.width,
            height: labelSize.height
        )
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

    private func drawMagnifier() {
        guard isMagnifierVisible, let cursor = effectiveMagnifierCursor else { return }
        let frame = MagnifierGeometry.frame(cursor: cursor, in: bounds)
        let interior = MagnifierGeometry.interiorRect(in: frame)
        let sampler = MagnifierSampler(
            image: activeSource,
            canvasSize: bounds.size,
            scaleX: activeScaleX,
            scaleY: activeScaleY
        )
        guard let sample = sampler.magnified(
            at: cursor,
            sourcePixels: MagnifierGeometry.samplePixelCount(scale: min(activeScaleX, activeScaleY)),
            zoom: MagnifierGeometry.zoom
        ) else { return }

        let outer = NSBezierPath(
            roundedRect: frame,
            xRadius: MagnifierGeometry.cornerRadius,
            yRadius: MagnifierGeometry.cornerRadius
        )
        NSColor(white: 0.1, alpha: 0.92).setFill()
        outer.fill()

        NSGraphicsContext.saveGraphicsState()
        let radius = MagnifierGeometry.cornerRadius - MagnifierGeometry.borderWidth
        NSBezierPath(roundedRect: interior, xRadius: radius, yRadius: radius).addClip()
        NSImage(cgImage: sample.image, size: interior.size).draw(in: interior)
        drawMagnifierCrosshair(in: interior, sample: sample)
        NSGraphicsContext.restoreGraphicsState()

        outer.lineWidth = MagnifierGeometry.borderWidth
        NSColor.white.withAlphaComponent(0.85).setStroke()
        outer.stroke()

        if let colorFeedback {
            drawColorFeedback(colorFeedback, in: frame)
        }
    }

    private func drawMagnifierCrosshair(
        in interior: CGRect,
        sample: MagnifierSampler.Magnified
    ) {
        let outputSide = CGFloat(sample.outputSide)
        let center = CGPoint(
            x: interior.minX + sample.crosshair.x / outputSide * interior.width,
            y: interior.maxY - sample.crosshair.y / outputSide * interior.height
        )
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: interior.minX, y: center.y))
        cross.line(to: CGPoint(x: interior.maxX, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: interior.minY))
        cross.line(to: CGPoint(x: center.x, y: interior.maxY))
        cross.lineWidth = 3
        NSColor.black.withAlphaComponent(0.5).setStroke()
        cross.stroke()
        cross.lineWidth = 1
        NSColor.white.setStroke()
        cross.stroke()

        // 光标像素本身圈出来，只看十字线分不清落在哪一格。
        let cell = interior.width * CGFloat(sample.zoom) / outputSide
        let box = NSBezierPath(rect: CGRect(
            x: center.x - cell / 2,
            y: center.y - cell / 2,
            width: cell,
            height: cell
        ))
        box.lineWidth = 2
        NSColor.black.withAlphaComponent(0.6).setStroke()
        box.stroke()
        box.lineWidth = 1
        NSColor.white.setStroke()
        box.stroke()
    }

    private func drawColorFeedback(_ text: String, in frame: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = text as NSString
        let textSize = string.size(withAttributes: attributes)
        let padding = NSSize(width: 5, height: 2)
        let size = NSSize(
            width: ceil(textSize.width) + padding.width * 2,
            height: ceil(textSize.height) + padding.height * 2
        )
        let rect = CGRect(
            x: frame.midX - size.width / 2,
            y: frame.minY + MagnifierGeometry.borderWidth + 3,
            width: size.width,
            height: size.height
        )
        NSColor(white: 0, alpha: 0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        string.draw(
            at: CGPoint(x: rect.minX + padding.width, y: rect.minY + padding.height),
            withAttributes: attributes
        )
    }
}

/// NSTextView 默认把 Enter 当换行；⌘Enter 提交、Esc 取消由编辑器自己收，
/// 编辑期间它是 first responder，按键到不了 OverlayView。
private final class AnnotatingTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // 输入法组字时 Esc 属于候选窗，不能当成取消整段编辑。
        if event.keyCode == 53 {
            if hasMarkedText() {
                super.keyDown(with: event)
                return
            }
            onCancel?()
            return
        }
        if event.modifierFlags.contains(.command),
           (event.keyCode == 36 || event.keyCode == 76) {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }
}

extension OverlayView: NSTextViewDelegate {
    /// 失焦即提交：窗口失活等场景让编辑器让出 first responder 时走这里。
    func textDidEndEditing(_ notification: Notification) {
        guard case .editing = phase else { return }
        commitTextEditing()
    }

    func textDidChange(_ notification: Notification) {
        guard case .editing = phase else { return }
        alignEditorBaseline()
    }
}

extension Notification.Name {
    static let snipEscapePressed = Notification.Name("snipEscapePressed")
    static let snipCommitted = Notification.Name("snipCommitted")
    static let snipCopyRequested = Notification.Name("snipCopyRequested")
    static let snipShareRequested = Notification.Name("snipShareRequested")
    static let snipTextRecognizeRequested = Notification.Name("snipTextRecognizeRequested")
    static let snipBarcodeScanRequested = Notification.Name("snipBarcodeScanRequested")
    static let snipSaveRequested = Notification.Name("snipSaveRequested")
}

/// 截图通知 userInfo 的键。收成封闭枚举，避免字符串字面量在两端拼错。
enum SnipNotificationKey: Hashable {
    case viewRect
    case viewHeight
    case scale
    case displayID
    /// 实际输出源与像素裁剪矩形。历史回放时可能是历史截图。
    case sourceImage
    case cropRectPx
    /// ⌘ + 保存按钮：直接写快捷保存目录，不弹面板。
    case quickSave
}

extension Dictionary where Key == AnyHashable, Value == Any {
    subscript(key: SnipNotificationKey) -> Any? {
        self[AnyHashable(key)]
    }
}
