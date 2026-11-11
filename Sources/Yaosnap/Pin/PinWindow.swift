import AppKit
import YaosnapCore

/// 无边框置顶贴图窗口。窗口尺寸、旋转、翻转与透明度都只由 transform 派生。
@MainActor
final class PinWindow: NSWindow {
    private let pinView = PinContentView(frame: .zero)
    private(set) var pasteImage: PasteImage
    /// 控制器分配的身份，分组与 Solo 只按它记账，不用窗口对象。
    let pinID: Int
    /// 多选与整组拖动由控制器协调，窗口只把交互意图转过去。
    weak var pinController: PinController?
    private(set) var transform: PinTransform = .identity
    /// 背景只影响绘制，不进入 transform，也不参与任何导出。
    private(set) var background: PinBackground = .transparent
    /// 是否在多选集合里；控制器是唯一写入口。
    private(set) var isMultiSelected = false
    /// Shift+Esc 销毁的贴图不进恢复列表，普通关闭才进。
    private(set) var canRestore = true
    /// 初始适配到屏幕 80% 后的尺寸。transform.scale 从 1 起，首次变换才不会跳回原图尺寸。
    private(set) var basePointSize: CGSize

    /// 每次裁剪前的保留区域，⌘Z 逐级退回。原始的 pasteImage 始终未改动。
    private var cropHistory: [CGRect?] = []
    private var imageCache: (key: ImageKey, image: CGImage, pointSize: CGSize)?
    /// 标注底栏放在贴图窗口外的浮动面板里：贴图可以很小（40x30），
    /// 底栏塞进内容视图会把整张图盖住，也接不了 15 个工具。
    private var annotatePanel: NSPanel?

    private struct ImageKey: Equatable {
        let crop: CGRect?
        let grayscale: Bool
        let inverted: Bool
    }

    private var pixelSize: CGSize {
        CGSize(width: pasteImage.image.width, height: pasteImage.image.height)
    }

    /// topLeft 使用主屏左上角为原点的屏幕坐标（y 向下），与 CLI 的 --pos 一致。
    init(
        pasteImage: PasteImage,
        pinID: Int,
        screen: NSScreen,
        cascadeIndex: Int,
        topLeft requestedTopLeft: CGPoint? = nil
    ) {
        let visible = screen.visibleFrame
        let source = pasteImage.pointSize
        let fit = min(
            1,
            visible.width * 0.8 / max(1, source.width),
            visible.height * 0.8 / max(1, source.height)
        )
        let size = CGSize(
            width: max(1, floor(source.width * fit)),
            height: max(1, floor(source.height * fit))
        )
        basePointSize = size
        self.pasteImage = pasteImage
        self.pinID = pinID
        var origin: CGPoint
        if let requestedTopLeft {
            // 窗口 frame 的原点是左下角，而请求给的是左上角。
            origin = CGPoint(x: requestedTopLeft.x, y: requestedTopLeft.y - size.height)
        } else {
            // 后续贴图错开叠放，否则多张完全重合看不出有几张。
            let offset = CGFloat(cascadeIndex % 6) * 24
            origin = CGPoint(
                x: visible.midX - size.width / 2 + offset,
                y: visible.maxY - visible.height * 0.12 - size.height - offset
            )
        }
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        // 非整数原点会让 AppKit 把 frame 向外取整，尺寸凭空多 1 点。
        origin = CGPoint(x: floor(origin.x), y: floor(origin.y))

        super.init(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        configureWindow()

        pinView.baseSize = size
        refreshImage()
    }

    /// 从恢复列表重建。frame 与 transform 都取关闭时的原值，尺寸不再重新适配屏幕。
    init(pasteImage: PasteImage, pinID: Int, restoring entry: PinRestoreEntry) {
        basePointSize = entry.basePointSize
        self.pasteImage = pasteImage
        self.pinID = pinID
        super.init(
            contentRect: entry.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        configureWindow()
        transform = entry.transform
        alphaValue = entry.transform.opacity
        refreshImage()
        pinView.transform = entry.transform
        pinView.needsDisplay = true
    }

    private func configureWindow() {
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        contentView = pinView
        makeFirstResponder(pinView)
    }

    /// 历史翻页：把窗口内容、变换、位置一次性换成历史里的另一张。
    func applyHistory(_ entry: PinRestoreEntry) {
        pasteImage = entry.image
        basePointSize = entry.basePointSize
        transform = entry.transform
        alphaValue = entry.transform.opacity
        imageCache = nil
        // 标注属于被换下的那张图，翻页后不留到新图上。
        pinView.clearAnnotations()
        refreshImage()
        pinView.transform = entry.transform
        pinView.needsDisplay = true
        setFrame(entry.frame, display: true)
        invalidateCursorRects(for: pinView)
    }

    /// 逗号看更早关闭的贴图，句号看更新的。
    func stepHistory(by direction: Int) {
        pinController?.stepHistory(by: direction, in: self)
    }

    /// 销毁：关闭且不留下可恢复的副本。
    func destroy() {
        canRestore = false
        close()
    }

    // MARK: - 标注底栏（独立浮窗）

    /// 承载标注底栏的浮窗。点按钮时不让贴图窗口失焦，因此用非激活面板。
    private func makeAnnotatePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = level
        panel.isFloatingPanel = true
        // 只有底栏里的输入控件需要按键，面板本身不抢 key。
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    func attachAnnotateBar(_ bar: PinAnnotateBar) {
        let panel = annotatePanel ?? makeAnnotatePanel()
        annotatePanel = panel
        let size = bar.intrinsicContentSize
        bar.translatesAutoresizingMaskIntoConstraints = true
        panel.contentView = bar
        bar.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)
        if panel.parent == nil {
            addChildWindow(panel, ordered: .above)
        }
        positionAnnotatePanel()
        panel.orderFront(nil)
    }

    func detachAnnotateBar() {
        guard let panel = annotatePanel else { return }
        annotatePanel = nil
        panel.orderOut(nil)
        if panel.parent != nil { removeChildWindow(panel) }
        panel.contentView = NSView(frame: .zero)
    }

    /// 贴在贴图窗口正下方；下方放不下就翻到上方，横向钳进屏幕。
    private func positionAnnotatePanel() {
        guard let panel = annotatePanel else { return }
        let size = panel.frame.size
        guard size.width > 0, size.height > 0 else { return }
        let gap: CGFloat = 8
        let bounds = (screen ?? NSScreen.main)?.visibleFrame ?? frame
        var origin = CGPoint(x: frame.midX - size.width / 2, y: frame.minY - gap - size.height)
        if origin.y < bounds.minY {
            let above = frame.maxY + gap
            origin.y = above + size.height <= bounds.maxY ? above : bounds.minY
        }
        origin.x = min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width))
        panel.setFrameOrigin(origin)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        positionAnnotatePanel()
    }

    override func close() {
        detachAnnotateBar()
        super.close()
    }

    /// 当前视觉状态（裁剪、滤镜、旋转、翻转）加标注的位图，供复制与另存为使用。
    func flattenedImage() -> CGImage? {
        guard let cache = imageCache else { return nil }
        let base = cache.image
        let annotations = pinView.annotations
        let turns = transform.quarterTurns
        let flipH = transform.flipHorizontal
        let flipV = transform.flipVertical
        let rotated = turns % 2 != 0
        let needsTransform = turns != 0 || flipH || flipV
        // 无变换也无标注时直接返回原图，避免一次无谓的位图拷贝。
        guard needsTransform || !annotations.isEmpty else { return base }
        guard let context = CGContext(
            data: nil,
            width: rotated ? base.height : base.width,
            height: rotated ? base.width : base.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: base.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.translateBy(x: CGFloat(context.width) / 2, y: CGFloat(context.height) / 2)
        if needsTransform {
            context.rotate(by: CGFloat(turns) * .pi / 2)
            context.scaleBy(x: flipH ? -1 : 1, y: flipV ? -1 : 1)
        }
        context.draw(base, in: CGRect(
            x: -CGFloat(base.width) / 2,
            y: -CGFloat(base.height) / 2,
            width: CGFloat(base.width),
            height: CGFloat(base.height)
        ))
        // 标注画布是固定点尺寸（cache.pointSize），与窗口缩放无关；导出上下文是像素，先放大。
        if !annotations.isEmpty, cache.pointSize.width > 0 {
            let scale = CGFloat(base.width) / cache.pointSize.width
            context.saveGState()
            context.translateBy(x: -CGFloat(cache.pointSize.width) / 2, y: -CGFloat(cache.pointSize.height) / 2)
            context.scaleBy(x: scale, y: scale)
            let input = RenderInput(
                base: base,
                cropOriginPx: .zero,
                canvasSize: cache.pointSize,
                scale: scale
            )
            AnnotationRenderer.draw(annotations, draft: nil, input: input, into: context)
            context.restoreGState()
        }
        return context.makeImage()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func setScale(_ value: CGFloat) {
        transform.setScale(value)
        applyTransform()
    }

    func adjustScale(by delta: CGFloat) {
        transform.adjustScale(by: delta)
        applyTransform()
    }

    func rotate(byQuarterTurns turns: Int) {
        transform.rotate(byQuarterTurns: turns)
        applyTransform()
    }

    func toggleFlipHorizontal() {
        transform.toggleFlipHorizontal()
        applyTransform()
    }

    func toggleFlipVertical() {
        transform.toggleFlipVertical()
        applyTransform()
    }

    func setOpacity(_ value: CGFloat) {
        transform.setOpacity(value)
        applyTransform()
    }

    func adjustOpacity(by delta: CGFloat) {
        transform.adjustOpacity(by: delta)
        applyTransform()
    }

    func toggleThumbnail() {
        transform.toggleThumbnail()
        applyTransform()
    }

    func toggleGrayscale() {
        transform.toggleGrayscale()
        applyTransform()
    }

    func toggleInverted() {
        transform.toggleInverted()
        applyTransform()
    }

    func setBackground(_ mode: PinBackground) {
        guard background != mode else { return }
        background = mode
        pinView.background = mode
        pinView.needsDisplay = true
    }

    func cycleBackground() {
        setBackground(background.next())
        print("[pin] background=\(background.rawValue) pin=\(pinID)")
    }

    func setMultiSelected(_ selected: Bool) {
        guard isMultiSelected != selected else { return }
        isMultiSelected = selected
        pinView.isSelected = selected
    }

    func resetTransform() {
        transform.reset()
        cropHistory.removeAll()
        applyTransform()
    }

    /// 裁剪只改 transform 里的保留区域，原图不复制也不删。窗口左上角保持不动。
    @discardableResult
    func applyCrop(viewSelection: CGRect) -> Bool {
        guard !transform.isThumbnail,
              let selection = PinCrop.clampedSelection(viewSelection, in: pinView.bounds),
              let rect = PinCrop.pixelRect(
                  fromViewRect: selection,
                  viewSize: pinView.bounds.size,
                  imagePixelSize: pixelSize,
                  transform: transform,
                  basePointSize: basePointSize
              ) else { return false }
        cropHistory.append(transform.cropRect)
        transform.setCrop(rect)
        applyTransform(anchor: .topLeft)
        return true
    }

    @discardableResult
    func undoLastCrop() -> Bool {
        guard let previous = cropHistory.popLast() else { return false }
        transform.setCrop(previous)
        applyTransform(anchor: .topLeft)
        return true
    }

    /// 效果与裁剪都烘进同一张显示图，导出走同一份成品，而不是在视图上叠滤镜。
    private func refreshImage() {
        let key = ImageKey(
            crop: transform.cropRect,
            grayscale: transform.isGrayscale,
            inverted: transform.isInverted
        )
        if imageCache?.key != key {
            imageCache = (
                key,
                PinImageEffects.render(
                    pasteImage.image,
                    crop: key.crop,
                    grayscale: key.grayscale,
                    inverted: key.inverted
                ),
                transform.displayedSize(original: pasteImage.pointSize, imagePixelSize: pixelSize)
            )
        }
        guard let imageCache else { return }
        pinView.image = NSImage(cgImage: imageCache.image, size: imageCache.pointSize)
        // 标注渲染需要当前裁剪/滤镜后的位图，与显示图同步。
        pinView.baseCGImage = imageCache.image
        pinView.baseSize = transform.displayedSize(
            original: basePointSize,
            imagePixelSize: pixelSize
        )
    }

    private enum Anchor {
        case center
        case topLeft
    }

    /// 以当前中心（裁剪时以左上角）为锚重设尺寸，再保证窗口留在屏幕可见区域。
    private func applyTransform(anchor: Anchor = .center) {
        pinView.transform = transform
        refreshImage()
        let size = transform.windowSize(base: pinView.baseSize)
        let oldFrame = frame
        alphaValue = transform.opacity
        let origin: CGPoint
        switch anchor {
        case .center:
            origin = CGPoint(
                x: floor(oldFrame.midX - size.width / 2),
                y: floor(oldFrame.midY - size.height / 2)
            )
        case .topLeft:
            origin = CGPoint(x: oldFrame.minX, y: oldFrame.maxY - size.height)
        }
        setFrame(
            CGRect(origin: origin, size: size),
            display: true
        )
        pinView.needsDisplay = true
        clampToVisibleFrame()
        invalidateCursorRects(for: pinView)
    }

    func clampToVisibleFrame() {
        guard let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let current = frame
        let x = min(max(current.minX, visible.minX), max(visible.minX, visible.maxX - current.width))
        let y = min(max(current.minY, visible.minY), max(visible.minY, visible.maxY - current.height))
        guard x != current.minX || y != current.minY else { return }
        setFrameOrigin(CGPoint(x: x, y: y))
    }
}

/// 键盘变换、双击关闭、边缘缩放、滚轮缩放与拖动移动。
/// 标注状态做成 internal 可读，验收 harness 直接驱动坐标变换与撤销。
@MainActor
final class PinContentView: NSView {
    var image: NSImage?
    /// 标注渲染用的当前位图（裁剪与滤镜已生效），由 PinWindow.refreshImage 同步。
    var baseCGImage: CGImage?
    var baseSize: CGSize = .zero
    var transform: PinTransform = .identity
    var background: PinBackground = .transparent
    var isSelected = false {
        didSet {
            if isSelected != oldValue { needsDisplay = true }
        }
    }

    /// 标注属于图像画布（baseSize，不随窗口缩放）。annotationTool 非 nil 即处于标注模式，
    /// 此时鼠标事件画形状而非拖动窗口。
    private(set) var annotations: [Annotation] = []
    private var annotationDraft: Annotation?
    private var annotationHistory = SnapshotHistory<[Annotation]>()
    var annotationTool: ShapeKind?
    var annotationStyle: Style = ShapeCatalog.entry(for: .rect)?.defaultStyle
        ?? Style(color: RGBAColor.palette[0], pen: .p3)
    /// 进入标注模式时的快照，取消按钮用它回滚本次会话的全部标注（含撤销栈）。
    private var annotationsBeforeMode: [Annotation] = []
    private var annotationHistoryBeforeMode = SnapshotHistory<[Annotation]>()
    private var annotationStart: CGPoint?
    /// 序号标注的下一个编号，撤销不回退（与截图主界面一致）。
    private var nextSerial = 1
    /// 折线待确认顶点；非 nil 表示正在多次点击折线。
    private var polylinePoints: [CGPoint]?
    /// 橡皮擦一次拖动只压一次撤销栈。
    private var eraserPushedUndo = false
    private var textEditor: PinAnnotatingTextView?
    private var textOrigin: CGPoint?
    private var textStyle: Style?

    private var dragStart: NSPoint?
    private var windowStart: NSPoint?
    private var resizeState: ResizeState?
    private var isCropping = false
    private var cropStart: CGPoint?
    private var cropSelection: CGRect?

    private let hotZone: CGFloat = 8
    private var hoverTracking: NSTrackingArea?
    private lazy var toolbar = makeToolbar()
    private lazy var annotateBar = makeAnnotateBar()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        if toolbar.superview == nil {
            addSubview(toolbar)
            toolbar.isHidden = true
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = toolbar.intrinsicContentSize
        toolbar.frame = CGRect(
            x: floor((bounds.width - size.width) / 2),
            y: bounds.height - size.height - 2,
            width: size.width,
            height: size.height
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        toolbar.updateStyle(scale: transform.scale)
        toolbar.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        toolbar.isHidden = true
    }

    private func makeToolbar() -> PinToolbar {
        let bar = PinToolbar()
        bar.onZoomOut = { [weak self] in self?.pinWindow?.adjustScale(by: -0.1) }
        bar.onZoomIn = { [weak self] in self?.pinWindow?.adjustScale(by: 0.1) }
        bar.onRotateLeft = { [weak self] in self?.pinWindow?.rotate(byQuarterTurns: -1) }
        bar.onRotateRight = { [weak self] in self?.pinWindow?.rotate(byQuarterTurns: 1) }
        bar.onFlipHorizontal = { [weak self] in self?.pinWindow?.toggleFlipHorizontal() }
        bar.onFlipVertical = { [weak self] in self?.pinWindow?.toggleFlipVertical() }
        bar.onGrayscale = { [weak self] in self?.pinWindow?.toggleGrayscale() }
        bar.onInverted = { [weak self] in self?.pinWindow?.toggleInverted() }
        bar.onCopy = { [weak self] in self?.copyImageFromMenu() }
        bar.onSave = { [weak self] in self?.saveImageFromMenu() }
        bar.onAnnotate = { [weak self] in
            guard let self else { return }
            self.setAnnotateMode(self.annotationTool == nil)
        }
        bar.onClose = { [weak self] in self?.pinWindow?.close() }
        return bar
    }

    private func makeAnnotateBar() -> PinAnnotateBar {
        let bar = PinAnnotateBar()
        bar.onSelectTool = { [weak self] kind in
            guard let self else { return }
            guard self.annotationTool != kind else { return }
            // 换工具即收掉上一笔未完成的折线与草稿，避免新旧工具混画。
            self.cancelPolyline()
            self.endTextEditing()
            self.annotationDraft = nil
            self.annotationStart = nil
            self.annotationTool = kind
            self.refreshAnnotateBar()
            self.needsDisplay = true
        }
        bar.onCycleColor = { [weak self] in self?.cycleAnnotationColor() }
        bar.onCyclePen = { [weak self] in self?.cycleAnnotationPen() }
        bar.onUndo = { [weak self] in self?.undoLastAnnotation() }
        bar.onFinish = { [weak self] in self?.setAnnotateMode(false) }
        bar.onCancel = { [weak self] in self?.setAnnotateMode(false, discardingAnnotations: true) }
        return bar
    }

    private var pinWindow: PinWindow? { window as? PinWindow }

    /// 棋盘格瓦片按模式缓存，颜色只有四种组合，重复构造 CGImage 是纯浪费。
    private static var checkerTiles: [PinBackground: CGImage] = [:]

    private struct ResizeState {
        let edge: PinEdge
        let anchorFraction: CGPoint
        let anchorGlobal: CGPoint
        let startMouse: CGPoint
        let baseSize: CGSize
        let quarterTurnsOdd: Bool
    }

    private enum PinEdge {
        case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight

        var anchorFraction: CGPoint {
            switch self {
            case .left: return CGPoint(x: 1, y: 0.5)
            case .right: return CGPoint(x: 0, y: 0.5)
            case .top: return CGPoint(x: 0.5, y: 0)
            case .bottom: return CGPoint(x: 0.5, y: 1)
            case .topLeft: return CGPoint(x: 1, y: 0)
            case .topRight: return CGPoint(x: 0, y: 0)
            case .bottomLeft: return CGPoint(x: 1, y: 1)
            case .bottomRight: return CGPoint(x: 0, y: 1)
            }
        }

        var isHorizontal: Bool {
            switch self {
            case .left, .right, .topLeft, .topRight, .bottomLeft, .bottomRight: return true
            case .top, .bottom: return false
            }
        }

        var isVertical: Bool {
            switch self {
            case .top, .bottom, .topLeft, .topRight, .bottomLeft, .bottomRight: return true
            case .left, .right: return false
            }
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawBackground(context)
        guard let image, baseSize.width > 0, baseSize.height > 0 else { return }
        let size = transform.unrotatedSize(base: baseSize)
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        // 先镜像再旋转，翻转才是按屏幕轴生效，而不是跟着图一起转。
        context.scaleBy(
            x: transform.flipHorizontal ? -1 : 1,
            y: transform.flipVertical ? -1 : 1
        )
        // AppKit 的 y 轴向上，负角表示顺时针。
        context.rotate(by: -CGFloat(transform.quarterTurns) * .pi / 2)
        image.draw(in: CGRect(
            x: -size.width / 2,
            y: -size.height / 2,
            width: size.width,
            height: size.height
        ))
        if !annotations.isEmpty || annotationDraft != nil {
            drawAnnotations(into: context, displaySize: size)
        }
        context.restoreGState()
        drawSelectionRing(context)
        drawCropOverlay(context)
    }

    /// 标注属于图像：与图像共用同一变换，窗口缩放旋转翻转时跟随。
    /// 画布点尺寸固定为 baseSize（缩放无关），显示时按 zoom 摆进当前 rect。
    private func drawAnnotations(into context: CGContext, displaySize: CGSize) {
        guard let base = baseCGImage, baseSize.width > 0, baseSize.height > 0 else { return }
        let zoom = displaySize.width / baseSize.width
        let input = RenderInput(
            base: base,
            cropOriginPx: .zero,
            canvasSize: baseSize,
            scale: CGFloat(base.width) / baseSize.width
        )
        context.saveGState()
        context.translateBy(x: -displaySize.width / 2, y: -displaySize.height / 2)
        context.scaleBy(x: zoom, y: zoom)
        AnnotationRenderer.draw(annotations, draft: annotationDraft, input: input, into: context)
        context.restoreGState()
    }

    /// 视图点 → 画布点（原点图像左下）。逆序撤销 draw 里的中心平移、镜像、旋转与显示倍率。
    private func canvasPoint(fromView point: CGPoint) -> CGPoint {
        var x = point.x - bounds.midX
        var y = point.y - bounds.midY
        if transform.flipHorizontal { x = -x }
        if transform.flipVertical { y = -y }
        let angle = CGFloat(transform.quarterTurns) * .pi / 2
        let rx = x * cos(angle) - y * sin(angle)
        let ry = x * sin(angle) + y * cos(angle)
        let displaySize = transform.unrotatedSize(base: baseSize)
        let zoom = baseSize.width > 0 ? displaySize.width / baseSize.width : 1
        return CGPoint(x: rx / zoom + baseSize.width / 2, y: ry / zoom + baseSize.height / 2)
    }

    // MARK: - 标注

    /// 进入 / 退出标注模式。取消时回滚到进入前的标注集。
    func setAnnotateMode(_ active: Bool, discardingAnnotations: Bool = false) {
        if active {
            guard annotationTool == nil else { return }
            annotationsBeforeMode = annotations
            annotationHistoryBeforeMode = annotationHistory
            annotationTool = .rect
            pinWindow?.attachAnnotateBar(annotateBar)
        } else {
            guard annotationTool != nil else { return }
            if discardingAnnotations {
                annotations = annotationsBeforeMode
                annotationHistory = annotationHistoryBeforeMode
            }
            endTextEditing()
            cancelPolyline()
            annotationTool = nil
            annotationDraft = nil
            annotationStart = nil
            nextSerial = max(1, nextSerial)
            pinWindow?.detachAnnotateBar()
        }
        refreshAnnotateBar()
        needsDisplay = true
        needsLayout = true
    }

    /// 历史翻页换了图像，旧画布上的标注一并作废。
    func clearAnnotations() {
        annotations = []
        annotationHistory.removeAll()
        annotationDraft = nil
        annotationStart = nil
        polylinePoints = nil
        nextSerial = 1
        refreshAnnotateBar()
        needsDisplay = true
    }

    private func refreshAnnotateBar() {
        annotateBar.updateState(
            tool: annotationTool ?? .rect,
            color: annotationStyle.color,
            pen: annotationStyle.pen,
            canUndo: annotationHistory.canUndo
        )
    }

    /// 颜色按钮循环调色板前 6 色；当前色不在其中时回到首色。
    private func cycleAnnotationColor() {
        let palette = Array(RGBAColor.palette.prefix(6))
        if let index = palette.firstIndex(of: annotationStyle.color) {
            annotationStyle.color = palette[(index + 1) % palette.count]
        } else {
            annotationStyle.color = palette[0]
        }
        refreshAnnotateBar()
    }

    private func cycleAnnotationPen() {
        let all = PenSize.allCases
        let index = all.firstIndex(of: annotationStyle.pen) ?? 0
        annotationStyle.pen = all[(index + 1) % all.count]
        refreshAnnotateBar()
    }

    /// 矩形系两边不足、线系位移不足则丢弃，点序列单击也落成圆点。
    private static let minimumStrokeSide: CGFloat = 3
    private static let minimumTextWidth: CGFloat = 160

    /// 落笔分发：一次点击就完成的工具（文字/序号）走这里，拖拽工具建草稿。
    private func beginAnnotationStroke(_ tool: ShapeKind, at viewPoint: CGPoint) {
        let point = canvasPoint(fromView: viewPoint)
        switch tool {
        case .text:
            beginTextEditing(at: viewPoint)
            return
        case .serial:
            commitSerial(at: point)
            return
        case .polyline:
            appendPolylinePoint(point)
            return
        case .eraser:
            eraserPushedUndo = false
            annotationStart = point
            eraseAnnotations(from: point, to: point)
            return
        default:
            break
        }
        annotationStart = point
        annotationDraft = makeDraft(tool: tool, origin: point, current: point)
        needsDisplay = true
    }

    private func updateAnnotationDraft(at viewPoint: CGPoint) {
        guard let tool = annotationTool else { return }
        let point = canvasPoint(fromView: viewPoint)
        switch tool {
        case .eraser:
            guard let last = annotationStart else { return }
            eraseAnnotations(from: last, to: point)
            annotationStart = point
            return
        case .polyline:
            guard let points = polylinePoints else { return }
            var preview = points
            if let last = preview.last, hypot(point.x - last.x, point.y - last.y) >= 1 {
                preview.append(point)
            }
            annotationDraft = Annotation(shape: .polyline(preview), style: annotationStyle)
        case .text, .serial:
            return
        default:
            guard let start = annotationStart, var draft = annotationDraft else { return }
            if let grown = appendPoint(point, to: draft.shape) {
                draft.shape = grown
            } else if !isPointSequence(draft.shape) {
                draft.shape = shapeForDrag(tool: tool, from: start, to: point)
            }
            annotationDraft = draft
        }
        needsDisplay = true
    }

    private func finishAnnotationStroke(at viewPoint: CGPoint) {
        guard let tool = annotationTool else { return }
        if tool == .eraser {
            annotationStart = nil
            eraserPushedUndo = false
            return
        }
        // 折线要等后续点击，鼠标抬起不算完成。
        if tool == .polyline { return }
        guard let start = annotationStart else { return }
        annotationStart = nil
        let point = canvasPoint(fromView: viewPoint)
        guard var draft = annotationDraft else {
            needsDisplay = true
            return
        }
        if isPointSequence(draft.shape) {
            // 点序列每移动一次已经增量加点；这里只补最后一个落点。
            if let grown = appendPoint(point, to: draft.shape) {
                draft.shape = grown
            }
        } else {
            draft.shape = shapeForDrag(tool: tool, from: start, to: point)
        }
        annotationDraft = nil
        guard isDraftValid(draft) else {
            needsDisplay = true
            return
        }
        commit(draft)
    }

    /// 按当前工具构建拖拽草稿。origin == current 表示笔画起点。
    private func makeDraft(tool: ShapeKind, origin: CGPoint, current: CGPoint) -> Annotation? {
        switch tool {
        case .brush:
            return Annotation(shape: .brush([current]), style: annotationStyle)
        case .marker:
            return Annotation(shape: .marker([current]), style: annotationStyle)
        case .mosaic:
            return Annotation(shape: .mosaic([current]), style: annotationStyle)
        case .blur:
            return Annotation(shape: .blur([current]), style: annotationStyle)
        case .polyline:
            return Annotation(shape: .polyline([origin, current]), style: annotationStyle)
        case .text, .serial, .eraser:
            return nil
        default:
            return Annotation(shape: shapeForDrag(tool: tool, from: origin, to: current), style: annotationStyle)
        }
    }

    /// 拖拽两点之间的形状。圆角半径取短边 1/4、放大镜固定 2 倍，与截图主界面一致。
    private func shapeForDrag(tool: ShapeKind, from start: CGPoint, to point: CGPoint) -> Shape {
        let rect = RectMath.normalizedRect(from: start, to: point)
        switch tool {
        case .rect:
            return .rect(rect)
        case .roundedRect:
            return .roundedRect(rect, radius: min(rect.width, rect.height) * 0.25)
        case .ellipse:
            return .ellipse(rect)
        case .magnify:
            return .magnify(rect, zoom: 2)
        case .mosaicRect:
            return .mosaicRect(rect)
        case .line:
            return .line(from: start, to: point)
        case .arrow:
            return .arrow(from: start, to: point)
        case .polyline:
            return .polyline([start, point])
        case .brush:
            return .brush([point])
        case .marker:
            return .marker([point])
        case .mosaic:
            return .mosaic([point])
        case .blur:
            return .blur([point])
        case .text, .serial, .eraser:
            return .rect(rect)
        }
    }

    private func isPointSequence(_ shape: Shape) -> Bool {
        switch shape {
        case .brush, .marker, .mosaic, .blur: return true
        default: return false
        }
    }

    /// 点序列增量加点，1pt 内的点忽略，避免原地震动堆积重复点。
    private func appendPoint(_ point: CGPoint, to shape: Shape) -> Shape? {
        func grown(_ points: [CGPoint]) -> [CGPoint]? {
            guard let last = points.last,
                  hypot(point.x - last.x, point.y - last.y) >= 1
            else { return nil }
            return points + [point]
        }
        switch shape {
        case .brush(let points): return grown(points).map { .brush($0) }
        case .marker(let points): return grown(points).map { .marker($0) }
        case .mosaic(let points): return grown(points).map { .mosaic($0) }
        case .blur(let points): return grown(points).map { .blur($0) }
        default: return nil
        }
    }

    private func isDraftValid(_ draft: Annotation) -> Bool {
        switch draft.shape {
        case .rect(let rect), .roundedRect(let rect, _), .ellipse(let rect), .magnify(let rect, _),
             .mosaicRect(let rect):
            return rect.width >= Self.minimumStrokeSide && rect.height >= Self.minimumStrokeSide
        case .line(let from, let to), .arrow(let from, let to):
            return hypot(to.x - from.x, to.y - from.y) >= Self.minimumStrokeSide
        case .brush, .marker, .mosaic, .blur:
            return true
        case .polyline(let points):
            guard points.count >= 2 else { return false }
            return zip(points, points.dropFirst()).contains {
                hypot($0.1.x - $0.0.x, $0.1.y - $0.0.y) >= Self.minimumStrokeSide
            }
        case .text, .serial:
            return false
        }
    }

    // MARK: - 序号 / 折线 / 橡皮擦 / 文字

    private func commitSerial(at point: CGPoint) {
        commit(Annotation(
            shape: .serial(value: nextSerial, center: point, radius: annotationStyle.pen.serialRadius),
            style: annotationStyle
        ))
        nextSerial += 1
    }

    /// 点按追加一个已确认顶点；双击或 Enter 收笔。
    private func appendPolylinePoint(_ point: CGPoint) {
        var points = polylinePoints ?? []
        if let last = points.last, hypot(point.x - last.x, point.y - last.y) < 1 { return }
        points.append(point)
        polylinePoints = points
        annotationDraft = Annotation(shape: .polyline(points), style: annotationStyle)
        needsDisplay = true
    }

    private func commitPolyline() {
        guard let points = polylinePoints else { return }
        polylinePoints = nil
        annotationDraft = nil
        let annotation = Annotation(shape: .polyline(points), style: annotationStyle)
        guard isDraftValid(annotation) else {
            needsDisplay = true
            return
        }
        commit(annotation)
    }

    private func cancelPolyline() {
        polylinePoints = nil
        annotationDraft = nil
        needsDisplay = true
    }

    /// 橡皮擦沿路径删除相交标注。一次拖动只压一次栈，撤销整组恢复。
    private func eraseAnnotations(from start: CGPoint, to end: CGPoint) {
        let tolerance = annotationStyle.pen.lineWidth
        let hits = annotations.filter {
            $0.shape.intersects(path: [start, end], tolerance: tolerance)
        }
        guard !hits.isEmpty else { return }
        if !eraserPushedUndo {
            annotationHistory.record(annotations)
            eraserPushedUndo = true
        }
        let hitIDs = Set(hits.map(\.id))
        annotations.removeAll { hitIDs.contains($0.id) }
        refreshAnnotateBar()
        needsDisplay = true
    }

    /// 单击进入编辑态。编辑器按渲染同一份度量定位：NSTextView 是 flipped 视图，
    /// 文本从 frame 顶部向下排，顶部留出 ascent 让第一行基线落在点击点。
    private func beginTextEditing(at viewPoint: CGPoint) {
        endTextEditing()
        let style = annotationStyle
        let fontSize = style.pen.textFontSize
        let line = TextMetrics.lineHeight(fontSize: fontSize)
        let width = max(Self.minimumTextWidth, bounds.maxX - viewPoint.x - 4)
        let top = viewPoint.y + line.ascent
        let height = max(3 * (line.ascent + line.descent), top - max(4, viewPoint.y - line.descent * 3))
        let editor = PinAnnotatingTextView(frame: NSRect(
            x: viewPoint.x,
            y: top - height,
            width: width,
            height: height
        ))
        editor.drawsBackground = false
        editor.isRichText = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        // 渲染只按 \n 硬换行，编辑器不能软折行，否则编辑时行数与提交后不一致。
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
        addSubview(editor, positioned: .above, relativeTo: nil)
        textEditor = editor
        textOrigin = canvasPoint(fromView: viewPoint)
        textStyle = style
        window?.makeFirstResponder(editor)
    }

    private func commitTextEditing() {
        guard let editor = textEditor else { return }
        let text = editor.string
        let origin = textOrigin
        let style = textStyle
        endTextEditing()
        window?.makeFirstResponder(self)
        // 空内容丢弃；非空原样入列，换行符保留给多行渲染。
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let origin, let style else { return }
        commit(Annotation(
            shape: .text(text, origin: origin, fontSize: style.pen.textFontSize, rotation: 0),
            style: style
        ))
    }

    private func cancelTextEditing() {
        endTextEditing()
        window?.makeFirstResponder(self)
    }

    private func endTextEditing() {
        guard let editor = textEditor else { return }
        // 先摘引用再移除视图：移除会触发失焦回调，引用已空时提交逻辑自然跳过。
        textEditor = nil
        textOrigin = nil
        textStyle = nil
        editor.delegate = nil
        editor.onCommit = nil
        editor.onCancel = nil
        editor.removeFromSuperview()
    }

    private func commit(_ annotation: Annotation) {
        annotationHistory.record(annotations)
        annotations.append(annotation)
        annotationDraft = nil
        refreshAnnotateBar()
        needsDisplay = true
    }

    private func undoLastAnnotation() {
        guard let previous = annotationHistory.undo(current: annotations) else { return }
        annotations = previous
        refreshAnnotateBar()
        needsDisplay = true
    }

    /// 背景铺在图像之下；图像自身的透明区域会露出它。
    private func drawBackground(_ context: CGContext) {
        guard let fill = background.fill else { return }
        context.setFillColor(fill.cgColor)
        context.fill(bounds)
        guard let tile = Self.checkerTile(for: background) else { return }
        context.saveGState()
        // 瓦片是 16px 的整数倍图，最近邻放大才不会把 8pt 格子糊成灰边。
        context.interpolationQuality = .none
        context.draw(tile, in: bounds, byTiling: true)
        context.restoreGState()
    }

    private static func checkerTile(for mode: PinBackground) -> CGImage? {
        if let cached = checkerTiles[mode] { return cached }
        guard let base = mode.fill, let alternate = mode.checkerAlternate else { return nil }
        let cell = Int(PinBackground.checkerCellSize)
        let side = cell * 2
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(base.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(alternate.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: cell, height: cell))
        context.fill(CGRect(x: cell, y: cell, width: cell, height: cell))
        guard let image = context.makeImage() else { return nil }
        checkerTiles[mode] = image
        return image
    }

    private func drawSelectionRing(_ context: CGContext) {
        guard isSelected else { return }
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(2)
        context.stroke(bounds.insetBy(dx: 1, dy: 1))
    }

    /// 裁剪模式下压暗保留区之外，并画出选择框与操作提示。
    private func drawCropOverlay(_ context: CGContext) {
        guard isCropping else { return }
        let dim = NSColor.black.withAlphaComponent(0.45).cgColor
        context.setFillColor(dim)
        if let selection = cropSelection, selection.width > 0, selection.height > 0 {
            let outside = [
                CGRect(x: 0, y: 0, width: bounds.width, height: selection.minY),
                CGRect(x: 0, y: selection.maxY, width: bounds.width, height: bounds.height - selection.maxY),
                CGRect(x: 0, y: selection.minY, width: selection.minX, height: selection.height),
                CGRect(x: selection.maxX, y: selection.minY, width: bounds.width - selection.maxX, height: selection.height)
            ]
            for rect in outside where rect.width > 0 && rect.height > 0 {
                context.fill(rect)
            }
            // 白线外再压一圈深色，浅色贴图上也能看清边界。
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1)
            context.stroke(selection.insetBy(dx: 0.5, dy: 0.5))
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            context.stroke(selection.insetBy(dx: 1.5, dy: 1.5))
        } else {
            context.fill(bounds)
        }
        let hint = (isCropping && cropSelection == nil)
            ? "拖动选择保留区域，Esc 取消"
            : "松开确认，Esc 取消"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let text = hint as NSString
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: (bounds.width - textSize.width) / 2, y: bounds.height - textSize.height - 12),
            withAttributes: attributes
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard let pinWindow = window as? PinWindow else { return }
        pinWindow.makeKey()
        let point = convert(event.locationInWindow, from: nil)
        if isCropping {
            cropStart = point
            cropSelection = nil
            needsDisplay = true
            return
        }
        // 标注模式吞掉所有点击，双击关闭与 Shift 多选都不生效。
        if let tool = annotationTool {
            // 折线用双击收笔；第二次点击本身不再落点。
            if tool == .polyline, event.clickCount >= 2, polylinePoints != nil {
                commitPolyline()
                return
            }
            beginAnnotationStroke(tool, at: point)
            return
        }
        if event.clickCount == 2 {
            if event.modifierFlags.contains(.shift) {
                pinWindow.toggleThumbnail()
            } else {
                pinWindow.close()
            }
            return
        }
        // Shift 单击只改多选集合，不进入拖动或缩放。
        if event.modifierFlags.contains(.shift) {
            pinWindow.pinController?.toggleSelection(pinID: pinWindow.pinID)
            return
        }
        if let edge = edge(at: point) {
            beginResize(edge, in: pinWindow)
            return
        }
        resizeState = nil
        dragStart = pinWindow.convertPoint(toScreen: event.locationInWindow)
        windowStart = pinWindow.frame.origin
        pinWindow.pinController?.beginDrag(of: pinWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pinWindow = window as? PinWindow else { return }
        if isCropping {
            guard let cropStart else { return }
            let current = convert(event.locationInWindow, from: nil)
            cropSelection = CGRect(
                x: min(cropStart.x, current.x),
                y: min(cropStart.y, current.y),
                width: abs(current.x - cropStart.x),
                height: abs(current.y - cropStart.y)
            ).intersection(bounds)
            needsDisplay = true
            return
        }
        if annotationTool != nil {
            updateAnnotationDraft(at: convert(event.locationInWindow, from: nil))
            return
        }
        if let resizeState {
            updateResize(resizeState, in: pinWindow, mouse: NSEvent.mouseLocation)
            return
        }
        guard let dragStart, let windowStart else { return }
        let current = pinWindow.convertPoint(toScreen: event.locationInWindow)
        let delta = CGPoint(x: current.x - dragStart.x, y: current.y - dragStart.y)
        if pinWindow.pinController?.dragSelection(by: delta) == true { return }
        pinWindow.setFrameOrigin(CGPoint(
            x: windowStart.x + delta.x,
            y: windowStart.y + delta.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        if annotationTool != nil {
            finishAnnotationStroke(at: convert(event.locationInWindow, from: nil))
            return
        }
        if isCropping {
            let selection = cropSelection
            endCropMode()
            guard let selection, selection.width >= 1, selection.height >= 1,
                  let pinWindow = window as? PinWindow else { return }
            pinWindow.applyCrop(viewSelection: selection)
            return
        }
        dragStart = nil
        windowStart = nil
        resizeState = nil
        (window as? PinWindow)?.pinController?.endDrag()
    }

    private func beginCrop() {
        guard !transform.isThumbnail, let pinWindow = window as? PinWindow else { return }
        pinWindow.makeKey()
        isCropping = true
        cropStart = nil
        cropSelection = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        NSCursor.crosshair.set()
    }

    private func endCropMode() {
        isCropping = false
        cropStart = nil
        cropSelection = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let pinWindow = window as? PinWindow else { return nil }
        let menu = NSMenu()

        menu.addItem(actionItem("复制图像", #selector(copyImageFromMenu)))
        menu.addItem(actionItem("图像另存为…", #selector(saveImageFromMenu)))
        menu.addItem(.separator())

        let shadow = actionItem("窗口阴影", #selector(toggleShadowFromMenu))
        shadow.state = pinWindow.hasShadow ? .on : .off
        menu.addItem(shadow)
        menu.addItem(.separator())

        let scaleItem = NSMenuItem(title: "缩放", action: nil, keyEquivalent: "")
        scaleItem.submenu = makeScaleMenu(current: pinWindow.transform.scale)
        menu.addItem(scaleItem)

        let effectsItem = NSMenuItem(title: "图像处理", action: nil, keyEquivalent: "")
        effectsItem.submenu = makeEffectsMenu(pinWindow: pinWindow)
        menu.addItem(effectsItem)

        let crop = actionItem("裁剪", #selector(beginCropFromMenu))
        crop.isEnabled = !pinWindow.transform.isThumbnail
        menu.addItem(crop)
        menu.addItem(.separator())

        menu.addItem(actionItem("粘贴", #selector(pasteFromMenu)))

        if let controller = pinWindow.pinController {
            let move = NSMenuItem(title: "移动到分组", action: nil, keyEquivalent: "")
            move.submenu = makeGroupMenu(controller: controller, pinID: pinWindow.pinID)
            menu.addItem(move)
            if controller.selectedPinCount > 0 {
                menu.addItem(actionItem("选中的贴图加入当前分组", #selector(joinSelectionFromMenu)))
            }
        }
        menu.addItem(.separator())

        menu.addItem(actionItem("关闭", #selector(closeFromMenu)))
        menu.addItem(actionItem("销毁", #selector(destroyFromMenu)))
        menu.addItem(.separator())

        let size = NSMenuItem(
            title: "\(Int(pinWindow.frame.width)) × \(Int(pinWindow.frame.height))",
            action: nil,
            keyEquivalent: ""
        )
        size.isEnabled = false
        menu.addItem(size)
        return menu
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func makeScaleMenu(current: CGFloat) -> NSMenu {
        let menu = NSMenu()
        for percent in [50, 100, 200] {
            let value = CGFloat(percent) / 100
            let item = actionItem("\(percent)%", #selector(scaleSelected(_:)))
            item.representedObject = value
            item.state = abs(current - value) < 0.01 ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("适应屏幕", #selector(fitToScreenFromMenu)))
        return menu
    }

    private func makeEffectsMenu(pinWindow: PinWindow) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(actionItem("向左旋转", #selector(rotateLeftFromMenu)))
        menu.addItem(actionItem("向右旋转", #selector(rotateRightFromMenu)))
        menu.addItem(actionItem("水平翻转", #selector(flipHorizontalFromMenu)))
        menu.addItem(actionItem("垂直翻转", #selector(flipVerticalFromMenu)))
        menu.addItem(.separator())
        menu.addItem(effectItem(
            title: "灰度",
            isOn: pinWindow.transform.isGrayscale,
            action: #selector(toggleGrayscaleFromMenu)
        ))
        menu.addItem(effectItem(
            title: "反色",
            isOn: pinWindow.transform.isInverted,
            action: #selector(toggleInvertedFromMenu)
        ))
        menu.addItem(.separator())
        let backgroundItem = NSMenuItem(title: "背景", action: nil, keyEquivalent: "")
        backgroundItem.submenu = makeBackgroundMenu(current: pinWindow.background)
        menu.addItem(backgroundItem)
        return menu
    }

    private func makeGroupMenu(controller: PinController, pinID: Int) -> NSMenu {
        let menu = NSMenu()
        for group in controller.pinGroups {
            let item = actionItem(group.name, #selector(groupSelected(_:)))
            item.representedObject = group.id
            item.state = group.id == controller.activePinGroupID ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func makeBackgroundMenu(current: PinBackground) -> NSMenu {
        let menu = NSMenu()
        for mode in PinBackground.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(backgroundSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func backgroundSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = PinBackground(rawValue: raw) else { return }
        (window as? PinWindow)?.setBackground(mode)
    }

    @objc private func joinSelectionFromMenu() {
        (window as? PinWindow)?.pinController?.joinSelectionToActiveGroup()
    }

    private func effectItem(title: String, isOn: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        return item
    }

    @objc private func toggleGrayscaleFromMenu() {
        (window as? PinWindow)?.toggleGrayscale()
    }

    @objc private func toggleInvertedFromMenu() {
        (window as? PinWindow)?.toggleInverted()
    }

    @objc private func beginCropFromMenu() {
        beginCrop()
    }

    @objc private func copyImageFromMenu() {
        guard let pinWindow = window as? PinWindow,
              let image = pinWindow.flattenedImage() else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: pinWindow.pasteImage.pointSize)])
    }

    @objc private func saveImageFromMenu() {
        guard let pinWindow = window as? PinWindow,
              let image = pinWindow.flattenedImage() else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ImageOutput.defaultFileName()
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let data = ImageOutput.pngData(from: image) else { return }
            try? data.write(to: url)
        }
    }

    @objc private func toggleShadowFromMenu() {
        guard let pinWindow = window as? PinWindow else { return }
        pinWindow.hasShadow.toggle()
    }

    @objc private func scaleSelected(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? CGFloat else { return }
        (window as? PinWindow)?.setScale(value)
    }

    @objc private func fitToScreenFromMenu() {
        guard let pinWindow = window as? PinWindow else { return }
        pinWindow.setScale(1)
        pinWindow.clampToVisibleFrame()
    }

    @objc private func rotateLeftFromMenu() {
        (window as? PinWindow)?.rotate(byQuarterTurns: -1)
    }

    @objc private func rotateRightFromMenu() {
        (window as? PinWindow)?.rotate(byQuarterTurns: 1)
    }

    @objc private func flipHorizontalFromMenu() {
        (window as? PinWindow)?.toggleFlipHorizontal()
    }

    @objc private func flipVerticalFromMenu() {
        (window as? PinWindow)?.toggleFlipVertical()
    }

    @objc private func pasteFromMenu() {
        (window as? PinWindow)?.pinController?.pinFromPasteboard()
    }

    @objc private func groupSelected(_ sender: NSMenuItem) {
        guard let groupID = sender.representedObject as? Int,
              let pinWindow = window as? PinWindow else { return }
        pinWindow.pinController?.assign(pinID: pinWindow.pinID, toGroup: groupID)
    }

    @objc private func closeFromMenu() {
        (window as? PinWindow)?.close()
    }

    @objc private func destroyFromMenu() {
        (window as? PinWindow)?.destroy()
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let pinWindow = window as? PinWindow, event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        pinWindow.resetTransform()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let pinWindow = window as? PinWindow else { return }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        if event.modifierFlags.contains(.control) {
            pinWindow.adjustOpacity(by: delta * 0.01)
        } else {
            pinWindow.setScale(pinWindow.transform.scale * exp(delta * 0.01))
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let pinWindow = window as? PinWindow else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            // 标注模式下 Esc 只退出标注，标注保留，窗口不关；未收笔的折线先撤掉。
            if annotationTool != nil {
                if polylinePoints != nil {
                    cancelPolyline()
                } else {
                    setAnnotateMode(false)
                }
                return
            }
            if isCropping {
                endCropMode()
            } else if event.modifierFlags.contains(.shift) {
                pinWindow.destroy()
            } else if pinWindow.pinController?.closeSelection(triggeredBy: pinWindow) == true {
                return
            } else {
                pinWindow.close()
            }
            return
        }
        if annotationTool != nil, event.keyCode == 36 || event.keyCode == 76 {
            // Enter 收笔：折线落库，其他工具下等同于「完成标注」。
            if polylinePoints != nil {
                commitPolyline()
                return
            }
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.charactersIgnoringModifiers ?? ""
        let key = characters.lowercased()
        if flags.contains(.command) {
            if key == "z" {
                if annotationTool != nil {
                    undoLastAnnotation()
                    return
                }
                if pinWindow.undoLastCrop() { return }
            }
            super.keyDown(with: event)
            return
        }
        if flags.contains(.control) {
            // Ctrl+W 的 characters 可能是控制字符，keyCode 更可靠。
            if event.keyCode == 13 || key == "w" {
                pinWindow.close()
                return
            }
            switch key {
            case "+", "=":
                pinWindow.adjustOpacity(by: 0.1)
            case "-", "_":
                pinWindow.adjustOpacity(by: -0.1)
            default:
                break
            }
            return
        }
        switch key {
        case "1":
            pinWindow.rotate(byQuarterTurns: -1)
        case "2":
            pinWindow.rotate(byQuarterTurns: 1)
        case "3":
            pinWindow.toggleFlipHorizontal()
        case "4":
            pinWindow.toggleFlipVertical()
        case "+", "=":
            pinWindow.adjustScale(by: 0.1)
        case "-", "_":
            pinWindow.adjustScale(by: -0.1)
        case "g":
            pinWindow.toggleGrayscale()
        case "i":
            pinWindow.toggleInverted()
        case "b":
            pinWindow.cycleBackground()
        case "c":
            if annotationTool == nil { beginCrop() }
        case ",":
            pinWindow.stepHistory(by: -1)
        case ".":
            pinWindow.stepHistory(by: 1)
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if annotationTool != nil {
            if polylinePoints != nil {
                cancelPolyline()
            } else {
                setAnnotateMode(false)
            }
            return
        }
        if isCropping {
            endCropMode()
            return
        }
        if let pinWindow = window as? PinWindow,
           pinWindow.pinController?.closeSelection(triggeredBy: pinWindow) == true {
            return
        }
        window?.close()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isCropping {
            addCursorRect(bounds, cursor: .crosshair)
            return
        }
        guard !transform.isThumbnail else { return }
        let bounds = self.bounds
        let hot = min(hotZone, min(bounds.width, bounds.height) / 2)
        guard hot > 0 else { return }
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: hot), cursor: .resizeUpDown)
        addCursorRect(
            NSRect(x: 0, y: bounds.height - hot, width: bounds.width, height: hot),
            cursor: .resizeUpDown
        )
        addCursorRect(
            NSRect(x: 0, y: hot, width: hot, height: max(0, bounds.height - hot * 2)),
            cursor: .resizeLeftRight
        )
        addCursorRect(
            NSRect(x: bounds.width - hot, y: hot, width: hot, height: max(0, bounds.height - hot * 2)),
            cursor: .resizeLeftRight
        )
        // AppKit 没有公开的对角缩放光标，四角用十字。
        addCursorRect(NSRect(x: 0, y: 0, width: hot, height: hot), cursor: .crosshair)
        addCursorRect(NSRect(x: bounds.width - hot, y: 0, width: hot, height: hot), cursor: .crosshair)
        addCursorRect(NSRect(x: 0, y: bounds.height - hot, width: hot, height: hot), cursor: .crosshair)
        addCursorRect(
            NSRect(x: bounds.width - hot, y: bounds.height - hot, width: hot, height: hot),
            cursor: .crosshair
        )
    }

    private func edge(at point: CGPoint) -> PinEdge? {
        guard !transform.isThumbnail else { return nil }
        let bounds = self.bounds
        let hot = min(hotZone, min(bounds.width, bounds.height) / 2)
        guard hot > 0 else { return nil }
        let nearLeft = point.x <= hot
        let nearRight = point.x >= bounds.maxX - hot
        let nearBottom = point.y <= hot
        let nearTop = point.y >= bounds.maxY - hot
        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearLeft && nearBottom { return .bottomLeft }
        if nearRight && nearBottom { return .bottomRight }
        if nearLeft { return .left }
        if nearRight { return .right }
        if nearTop { return .top }
        if nearBottom { return .bottom }
        return nil
    }

    private func beginResize(_ edge: PinEdge, in pinWindow: PinWindow) {
        let frame = pinWindow.frame
        let fraction = edge.anchorFraction
        resizeState = ResizeState(
            edge: edge,
            anchorFraction: fraction,
            anchorGlobal: CGPoint(
                x: frame.minX + fraction.x * frame.width,
                y: frame.minY + fraction.y * frame.height
            ),
            startMouse: NSEvent.mouseLocation,
            baseSize: pinWindow.basePointSize,
            quarterTurnsOdd: pinWindow.transform.quarterTurns % 2 == 1
        )
        dragStart = nil
        windowStart = nil
    }

    private func updateResize(_ state: ResizeState, in pinWindow: PinWindow, mouse: CGPoint) {
        let dx = abs(mouse.x - state.anchorGlobal.x)
        let dy = abs(mouse.y - state.anchorGlobal.y)
        // 窗口宽高相对未旋转基准轴的对应关系随四分之一圈互换。
        let widthBase = state.quarterTurnsOdd ? state.baseSize.height : state.baseSize.width
        let heightBase = state.quarterTurnsOdd ? state.baseSize.width : state.baseSize.height
        guard widthBase > 0, heightBase > 0 else { return }
        // 角上两个轴都参与，用位移更大的轴定尺度，否则纯纵向拖动会被没动过的横向距离锁死。
        let useHorizontal: Bool
        if state.edge.isHorizontal && state.edge.isVertical {
            let moveX = abs(mouse.x - state.startMouse.x)
            let moveY = abs(mouse.y - state.startMouse.y)
            useHorizontal = moveX >= moveY
        } else {
            useHorizontal = state.edge.isHorizontal
        }
        let rawScale = useHorizontal ? dx / widthBase : dy / heightBase
        pinWindow.setScale(rawScale)
        let frame = pinWindow.frame
        pinWindow.setFrameOrigin(CGPoint(
            x: state.anchorGlobal.x - state.anchorFraction.x * frame.width,
            y: state.anchorGlobal.y - state.anchorFraction.y * frame.height
        ))
        pinWindow.clampToVisibleFrame()
    }
}

/// NSTextView 默认把 Enter 当换行；⌘Enter 提交、Esc 取消由编辑器自己收，
/// 编辑期间它是 first responder，按键到不了 PinContentView。
private final class PinAnnotatingTextView: NSTextView {
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
           event.keyCode == 36 || event.keyCode == 76 {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }
}

extension PinContentView: NSTextViewDelegate {
    /// 失焦即提交：窗口失活等场景让编辑器让出 first responder 时走这里。
    func textDidEndEditing(_ notification: Notification) {
        commitTextEditing()
    }
}

