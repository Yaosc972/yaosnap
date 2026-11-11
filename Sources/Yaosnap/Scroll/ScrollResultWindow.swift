import AppKit
import YaosnapCore

/// 长图查看窗口：上下滚动查看、直接标注、复制 / 保存 / 贴到屏幕。
///
/// 标注坐标系与截图主界面一致：画布点坐标，原点在图像左下、y 向上，
/// 导出走 `AnnotationExport.flatten`，预览与导出共用同一个渲染器。
@MainActor
final class ScrollResultWindow: NSWindow {
    var onPin: ((CGImage, CGFloat) -> Void)?

    private let image: CGImage
    private let scale: CGFloat
    private let canvas: ScrollResultCanvas
    private let scrollView = NSScrollView()
    private var annotateBar: ScrollResultAnnotateBar?

    private var annotations: [Annotation] { canvas.annotations }
    private var annotateMode = false

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale

        let pointSize = NSSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 900, height: 700)
        let contentSize = NSSize(
            width: min(pointSize.width, visible.width * 0.7),
            height: min(pointSize.height, visible.height * 0.8)
        )
        canvas = ScrollResultCanvas(image: image, scale: scale, pointSize: pointSize)
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "滚动截图"
        isReleasedWhenClosed = false
        center()

        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        container.autoresizingMask = [.width, .height]

        let toolbar = makeToolbar()
        toolbar.frame = NSRect(x: 0, y: contentSize.height - 36, width: contentSize.width, height: 36)
        toolbar.autoresizingMask = [.width, .minYMargin]
        container.addSubview(toolbar)

        scrollView.frame = NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height - 36)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        // 画布不翻转（y 向上），标注坐标才能直接用视图坐标；初始滚动位置手动推到顶部。
        canvas.frame = NSRect(origin: .zero, size: pointSize)
        scrollView.documentView = canvas
        container.addSubview(scrollView)

        contentView = container
        scrollToTop()
    }

    override func setContentSize(_ size: NSSize) {
        super.setContentSize(size)
        scrollToTopIfNeeded()
    }

    private func scrollToTop() {
        let documentHeight = canvas.frame.height
        let clipHeight = scrollView.contentView.bounds.height
        let top = max(0, documentHeight - clipHeight)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private var didScrollToTop = false
    private func scrollToTopIfNeeded() {
        guard !didScrollToTop else { return }
        didScrollToTop = true
        scrollToTop()
    }

    // MARK: - 工具条

    private func makeToolbar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let buttons: [(String, Selector)] = [
            ("复制", #selector(copyTapped)),
            ("保存", #selector(saveTapped)),
            ("贴到屏幕", #selector(pinTapped)),
            ("标注", #selector(annotateTapped)),
            ("关闭", #selector(closeTapped))
        ]
        var x: CGFloat = 8
        for (title, action) in buttons {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.sizeToFit()
            button.frame.origin = NSPoint(x: x, y: 5)
            bar.addSubview(button)
            x += button.frame.width + 8
        }
        return bar
    }

    // MARK: - 标注

    private func setAnnotateMode(_ active: Bool) {
        annotateMode = active
        canvas.isAnnotating = active
        if active {
            let bar = annotateBar ?? ScrollResultAnnotateBar()
            if bar.superview == nil {
                bar.onSelectTool = { [weak self] kind in
                    self?.canvas.tool = kind
                    self?.annotateBar?.setTool(kind)
                }
                bar.onCycleColor = { [weak self] in self?.cycleColor() }
                bar.onUndo = { [weak self] in self?.undo() }
                bar.onFinish = { [weak self] in self?.setAnnotateMode(false) }
                contentView?.addSubview(bar)
                annotateBar = bar
            }
            layoutAnnotateBar()
            bar.isHidden = false
            bar.setTool(canvas.tool)
        } else {
            annotateBar?.isHidden = true
        }
        windowDidChangeAnnotateMode()
    }

    private func layoutAnnotateBar() {
        guard let bar = annotateBar, let container = contentView else { return }
        let size = bar.intrinsicContentSize
        bar.frame = NSRect(
            x: max(0, (container.bounds.width - size.width) / 2),
            y: 44,
            width: size.width,
            height: size.height
        )
    }

    private func windowDidChangeAnnotateMode() {
        invalidateShadow()
    }

    private func cycleColor() {
        let palette = Array(RGBAColor.palette.prefix(12))
        let current = canvas.style.color
        let next = palette.firstIndex(of: current).map { palette[($0 + 1) % palette.count] } ?? palette[0]
        canvas.style.color = next
        annotateBar?.setColor(next)
    }

    private func undo() {
        guard !canvas.annotations.isEmpty else { return }
        canvas.annotations.removeLast()
        annotateBar?.setCanUndo(!canvas.annotations.isEmpty)
    }

    // MARK: - 输出

    /// 有标注时先合成再输出，与截图主链路共用 `AnnotationExport`。
    private func flattenedImage() -> CGImage {
        guard !annotations.isEmpty else { return image }
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return AnnotationExport.flatten(
            base: image,
            cropRectPx: full,
            annotations: annotations,
            scale: scale
        ) ?? image
    }

    @objc private func copyTapped() {
        _ = ClipboardService.copyToPasteboard(flattenedImage(), scale: scale)
    }

    @objc private func saveTapped() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "滚动截图.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = ImageOutput.pngData(from: flattenedImage()) else { return }
        try? data.write(to: url)
    }

    @objc private func pinTapped() {
        onPin?(flattenedImage(), scale)
    }

    @objc private func annotateTapped() {
        setAnnotateMode(!annotateMode)
    }

    @objc private func closeTapped() {
        close()
    }
}

// MARK: - 画布

/// 长图画布：绘制底图与标注，标注模式下接管鼠标画形状。
@MainActor
final class ScrollResultCanvas: NSView {
    private let image: CGImage
    private let scale: CGFloat

    var annotations: [Annotation] = [] { didSet { needsDisplay = true } }
    var draft: Annotation? { didSet { needsDisplay = true } }
    var style = Style(color: RGBAColor.palette[0], pen: .p3)
    var tool: ShapeKind = .rect
    var isAnnotating = false { didSet { needsDisplay = true } }

    private var startPoint: CGPoint?

    init(image: CGImage, scale: CGFloat, pointSize: NSSize) {
        self.image = image
        self.scale = scale
        super.init(frame: NSRect(origin: .zero, size: pointSize))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 视图不翻转：坐标原点在左下、y 向上，与标注画布坐标一致。
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // 底图整幅画进 bounds；CoreGraphics 会把图像顶行放在 maxY 侧，视觉上正立。
        ctx.draw(image, in: bounds)
        guard !annotations.isEmpty || draft != nil else { return }
        let input = RenderInput(
            base: image,
            cropOriginPx: .zero,
            canvasSize: bounds.size,
            scale: scale
        )
        AnnotationRenderer.draw(annotations, draft: draft, input: input, into: ctx)
    }

    // MARK: 画标注

    override func mouseDown(with event: NSEvent) {
        guard isAnnotating else { return super.mouseDown(with: event) }
        let point = canvasPoint(event)
        startPoint = point
        draft = Annotation(shape: draftShape(from: point, to: point), style: style)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isAnnotating, let start = startPoint else { return super.mouseDragged(with: event) }
        let point = canvasPoint(event)
        draft?.shape = draftShape(from: start, to: point)
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard isAnnotating, let start = startPoint, let draft else {
            return super.mouseUp(with: event)
        }
        startPoint = nil
        let point = canvasPoint(event)
        let shape = draftShape(from: start, to: point)
        self.draft = nil
        // 微动不算一笔，误触不会在图上留下小点。
        guard hypot(point.x - start.x, point.y - start.y) > 2 else { return }
        annotations.append(Annotation(shape: shape, style: style))
    }

    private func canvasPoint(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func draftShape(from start: CGPoint, to point: CGPoint) -> Shape {
        switch tool {
        case .ellipse:
            return .ellipse(RectMath.normalizedRect(from: start, to: point))
        case .arrow:
            return .arrow(from: start, to: point)
        case .brush, .marker:
            if case .brush(var points)? = draft?.shape {
                points.append(point)
                return .brush(points)
            }
            return .brush([start, point])
        default:
            return .rect(RectMath.normalizedRect(from: start, to: point))
        }
    }
}

// MARK: - 标注底栏

/// 标注模式底栏：形状、颜色、撤销与完成。
@MainActor
final class ScrollResultAnnotateBar: NSView {
    var onSelectTool: ((ShapeKind) -> Void)?
    var onCycleColor: (() -> Void)?
    var onUndo: (() -> Void)?
    var onFinish: (() -> Void)?

    private static let tools: [ShapeKind] = [.rect, .ellipse, .arrow, .brush]
    private var toolButtons: [ShapeKind: NSButton] = [:]
    private lazy var colorButton = makeButton("paintpalette", "标注颜色", #selector(colorTapped))
    private lazy var undoButton = makeButton("arrow.uturn.backward", "撤销标注", #selector(undoTapped))

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.9).cgColor
        layer?.cornerRadius = 6

        var views: [NSView] = []
        for kind in Self.tools {
            guard let entry = ShapeCatalog.entry(for: kind) else { continue }
            let button = makeButton(entry.symbol, entry.title, #selector(toolTapped(_:)))
            button.tag = Self.tools.firstIndex(of: kind) ?? 0
            toolButtons[kind] = button
            views.append(button)
        }
        views.append(separator())
        views.append(colorButton)
        views.append(undoButton)
        views.append(makeButton("checkmark", "完成标注", #selector(finishTapped)))
        views.append(separator())

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        undoButton.isEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: subviews.first?.fittingSize.width ?? 240, height: 34)
    }

    func setTool(_ kind: ShapeKind) {
        for (candidate, button) in toolButtons {
            button.contentTintColor = candidate == kind ? .white : NSColor(white: 1, alpha: 0.55)
        }
    }

    func setColor(_ color: RGBAColor) {
        let side: CGFloat = 12
        let swatch = NSImage(size: NSSize(width: side, height: side))
        swatch.lockFocus()
        NSColor(cgColor: color.cgColor)?.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: side, height: side)).fill()
        swatch.unlockFocus()
        colorButton.image = swatch
    }

    func setCanUndo(_ canUndo: Bool) {
        undoButton.isEnabled = canUndo
    }

    private func makeButton(_ symbol: String, _ title: String, _ action: Selector) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.toolTip = title
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        button.contentTintColor = NSColor(white: 1, alpha: 0.55)
        return button
    }

    private func separator() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 1, alpha: 0.15).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return view
    }

    @objc private func toolTapped(_ sender: NSButton) {
        guard Self.tools.indices.contains(sender.tag) else { return }
        onSelectTool?(Self.tools[sender.tag])
    }

    @objc private func colorTapped() { onCycleColor?() }
    @objc private func undoTapped() { onUndo?() }
    @objc private func finishTapped() { onFinish?() }
}
