import AppKit
import UniformTypeIdentifiers
import YaosnapCore

/// 选区标注工具条：选择、形状选择、颜色/笔尖弹层、复制/提取文字/识别码/保存/取消。
/// 单行布局：[选择][分隔][形状按钮][分隔][颜色][笔尖][分隔][复制][提取文字][识别码][保存][取消]。
@MainActor
final class AnnotateToolbar: NSView {
    var onSelectTool: ((ShapeKind) -> Void)?
    var onSelectMode: (() -> Void)?
    var onStyleChange: ((Style) -> Void)?
    var onCopy: (() -> Void)?
    var onExtractText: (() -> Void)?
    var onScanBarcode: (() -> Void)?
    var onSave: (() -> Void)?
    /// ⌘ + 保存按钮：写快捷保存目录。
    var onQuickSave: (() -> Void)?
    var onShare: (() -> Void)?
    var onCancel: (() -> Void)?

    private enum Metrics {
        static let buttonSide: CGFloat = 30
        static let spacing: CGFloat = 2
        static let padding: CGFloat = 7
        static let separatorWidth: CGFloat = 1
        static let separatorGap: CGFloat = 6
        static let ratioLabelWidth: CGFloat = 36
        static let height: CGFloat = buttonSide + padding * 2
        // 复杂表达式拆开，编译器在单表达式里推不动
        private static let toolRow: CGFloat = CGFloat(ShapeCatalog.p2.count) * buttonSide
            + CGFloat(ShapeCatalog.p2.count - 1) * spacing
        private static let styleRow: CGFloat = buttonSide * 4 + spacing * 3
        private static let actionRow: CGFloat = ratioLabelWidth + spacing
            + buttonSide * 6 + spacing * 5
        private static let separators: CGFloat = (separatorGap + separatorWidth + separatorGap) * 3
        static let width: CGFloat = padding * 2 + buttonSide + toolRow + styleRow + actionRow + separators
    }

    private(set) var selectedKind: ShapeKind = .rect
    private(set) var isSelectMode = false
    private(set) var currentStyle: Style
    private let initialAspectRatio: SelectionAspectRatio
    private let paletteStore: PaletteStore
    private var paletteModel: PaletteModel
    /// 暴露给验收 harness 程序化点击。
    private(set) var selectButton: HoverButton!
    private(set) var toolButtons: [ShapeKind: HoverButton] = [:]
    private(set) var colorButton: HoverButton!
    private(set) var penButton: HoverButton!
    private(set) var lineStyleButton: HoverButton!
    private(set) var backgroundButton: HoverButton!
    private(set) var textButton: HoverButton!
    private(set) var barcodeButton: HoverButton!
    private(set) var saveButton: HoverButton!
    private(set) var shareButton: HoverButton!
    private(set) var ratioLabel: NSTextField!
    private(set) var colorPopover: NSPopover?
    private(set) var penPopover: NSPopover?
    /// 识别结果提示，盖在按钮上，1.6 秒后自动隐藏。
    private lazy var messageLabel: PassthroughLabel = {
        let label = PassthroughLabel(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor(white: 0, alpha: 0.78).cgColor
        label.layer?.cornerRadius = 6
        label.isHidden = true
        return label
    }()
    private var messageToken = 0

    /// 提示条只是显示层，不吃点击，避免覆盖期间下面的按钮点不动。
    private final class PassthroughLabel: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    init(
        initialKind: ShapeKind,
        initialStyle: Style,
        initialAspectRatio: SelectionAspectRatio = .free,
        paletteStore: PaletteStore = PaletteStore()
    ) {
        selectedKind = initialKind
        currentStyle = initialStyle
        self.initialAspectRatio = initialAspectRatio
        self.paletteStore = paletteStore
        paletteModel = paletteStore.load()
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.height))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        layer?.cornerRadius = 8
        layoutButtons()
        addSubview(messageLabel)
        refreshStyleButtons()
        refreshSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 吞掉容器空白区的点击，避免落到覆盖视图上开始新拖拽。
    override func mouseDown(with event: NSEvent) {}

    /// 选中形状按钮并同步该工具的记忆样式。快捷键、Tab 与点击共用，幂等。
    func select(_ kind: ShapeKind, style: Style) {
        selectedKind = kind
        currentStyle = style
        isSelectMode = false
        refreshSelection()
        refreshStyleButtons()
    }

    /// 外部（滚轮 / 数字键）改了样式后同步按钮显示，不再回调 onStyleChange 避免回环。
    func updateStyle(_ style: Style) {
        currentStyle = style
        refreshStyleButtons()
    }

    /// 选区比例变了只更新标签；拖拽数学由 OverlayView 持有设置值自行计算。
    func updateAspectRatio(_ ratio: SelectionAspectRatio) {
        ratioLabel.stringValue = ratio.title
    }

    /// 切到选择工具。形状按钮全部取消高亮。
    func selectMode() {
        isSelectMode = true
        refreshSelection()
    }

    // MARK: - 布局

    private func layoutButtons() {
        let side = Metrics.buttonSide
        var x = Metrics.padding
        func place(_ button: NSButton) {
            button.frame = NSRect(x: x, y: Metrics.padding, width: side, height: side)
            addSubview(button)
            x += side + Metrics.spacing
        }
        func separator() {
            x += Metrics.separatorGap - Metrics.spacing
            let bar = NSView(frame: NSRect(
                x: x, y: Metrics.padding + 5,
                width: Metrics.separatorWidth, height: side - 10
            ))
            bar.wantsLayer = true
            bar.layer?.backgroundColor = NSColor(white: 1, alpha: 0.25).cgColor
            addSubview(bar)
            x += Metrics.separatorWidth + Metrics.separatorGap
        }

        selectButton = makeHoverButton(
            symbol: "cursorarrow",
            title: "选择",
            action: #selector(selectModeTapped)
        )
        place(selectButton)
        separator()
        for (index, entry) in ShapeCatalog.p2.enumerated() {
            let button = makeHoverButton(
                symbol: entry.symbol,
                title: entry.title,
                action: #selector(toolTapped(_:))
            )
            button.tag = index
            place(button)
            toolButtons[entry.kind] = button
        }
        separator()
        colorButton = makeHoverButton(symbol: nil, title: "颜色", action: #selector(colorTapped))
        colorButton.onScroll = { [weak self] deltaY in self?.stepAlpha(deltaY) }
        place(colorButton)
        penButton = makeHoverButton(symbol: nil, title: "笔尖", action: #selector(penTapped))
        place(penButton)
        lineStyleButton = makeHoverButton(symbol: nil, title: "线型", action: #selector(lineStyleTapped))
        lineStyleButton.contentTintColor = .white
        place(lineStyleButton)
        backgroundButton = makeHoverButton(symbol: nil, title: "背景", action: #selector(backgroundTapped))
        place(backgroundButton)
        separator()
        ratioLabel = NSTextField(labelWithString: initialAspectRatio.title)
        ratioLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        ratioLabel.textColor = NSColor(white: 1, alpha: 0.7)
        ratioLabel.alignment = .center
        ratioLabel.frame = NSRect(
            x: x,
            y: Metrics.padding,
            width: Metrics.ratioLabelWidth,
            height: side
        )
        addSubview(ratioLabel)
        x += Metrics.ratioLabelWidth + Metrics.spacing
        place(makeHoverButton(symbol: "doc.on.doc", title: "复制", action: #selector(copyTapped)))
        textButton = makeHoverButton(
            symbol: "text.viewfinder",
            title: "提取文字",
            action: #selector(extractTextTapped)
        )
        place(textButton)
        barcodeButton = makeHoverButton(
            symbol: "qrcode.viewfinder",
            title: "识别码",
            action: #selector(scanBarcodeTapped)
        )
        place(barcodeButton)
        saveButton = makeHoverButton(
            symbol: "square.and.arrow.down",
            title: "保存",
            action: #selector(saveTapped)
        )
        place(saveButton)
        shareButton = makeHoverButton(
            symbol: "square.and.arrow.up",
            title: "分享",
            action: #selector(shareTapped)
        )
        place(shareButton)
        place(makeHoverButton(symbol: "xmark", title: "取消", action: #selector(cancelTapped)))
    }

    private func makeHoverButton(
        symbol: String?,
        title: String,
        action: Selector
    ) -> HoverButton {
        let button = HoverButton()
        button.isBordered = false
        button.refusesFirstResponder = true
        if let symbol {
            button.image = NSImage(
                systemSymbolName: symbol,
                accessibilityDescription: title
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            )
            button.contentTintColor = .white
        }
        button.toolTip = title
        button.target = self
        button.action = action
        return button
    }

    /// 实心圆点图标，颜色/笔尖按钮与弹层色块共用。
    static func dotImage(diameter: CGFloat, color: NSColor, ringed: Bool = false) -> NSImage {
        let inset: CGFloat = 3
        let size = NSSize(width: diameter + inset * 2, height: diameter + inset * 2)
        let image = NSImage(size: size)
        image.lockFocus()
        let circle = NSBezierPath(ovalIn: NSRect(
            x: inset, y: inset, width: diameter, height: diameter
        ))
        color.setFill()
        circle.fill()
        if ringed {
            NSColor.white.setStroke()
            circle.lineWidth = 2
            circle.stroke()
        }
        image.unlockFocus()
        return image
    }

    /// 颜色按钮上滚轮调透明度。档位从 100% 递减排列，向上滚往更不透明走。
    private func stepAlpha(_ deltaY: CGFloat) {
        guard deltaY != 0 else { return }
        let presets = ColorPaletteView.alphaPresets
        let current = currentStyle.color.a
        let nearest = presets.enumerated().min {
            abs($0.element - current) < abs($1.element - current)
        }?.offset ?? 0
        let next = min(max(nearest + (deltaY > 0 ? -1 : 1), 0), presets.count - 1)
        guard presets[next] != current else { return }
        currentStyle.color.a = presets[next]
        refreshStyleButtons()
        onStyleChange?(currentStyle)
    }

    private static func penDotDiameter(_ pen: PenSize) -> CGFloat {
        4 + CGFloat(pen.rawValue - 1) * 3
    }

    /// 刷新颜色/笔尖/线型/背景按钮，反映当前样式。非描边类形状禁用电线型按钮。
    private func refreshStyleButtons() {
        colorButton.image = Self.dotImage(diameter: 16, color: Self.nsColor(currentStyle.color))
        penButton.image = Self.dotImage(
            diameter: Self.penDotDiameter(currentStyle.pen),
            color: .white
        )
        lineStyleButton.image = Self.lineStyleImage(currentStyle.lineStyle)
        lineStyleButton.isEnabled = selectedKind.supportsLineStyle
        backgroundButton.attributedTitle = Self.backgroundTitle(
            BackgroundCycle.of(currentStyle.background)
        )
    }

    /// 背景按钮无图标，用标题表示当前档位。
    private static func backgroundTitle(_ cycle: BackgroundCycle) -> NSAttributedString {
        NSAttributedString(
            string: cycle.title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            ]
        )
    }

    /// 背景按钮的四档循环：无 → 白 → 黑 → 文字色。档位只由样式反推，不另存状态。
    private enum BackgroundCycle: CaseIterable {
        case none, white, black, text

        static let whiteColor = RGBAColor(r: 1, g: 1, b: 1, a: 0.85)
        static let blackColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.70)

        var title: String {
            switch self {
            case .none: return "背景"
            case .white: return "白"
            case .black: return "黑"
            case .text: return "彩"
            }
        }

        /// 当前样式落在哪一档。非白非黑的自定义背景按文字色档处理。
        static func of(_ background: RGBAColor?) -> BackgroundCycle {
            guard let background else { return .none }
            if background == whiteColor { return .white }
            if background == blackColor { return .black }
            return .text
        }

        var next: BackgroundCycle {
            let all = Self.allCases
            let index = all.firstIndex(of: self) ?? 0
            return all[(index + 1) % all.count]
        }

        func color(textColor: RGBAColor) -> RGBAColor? {
            switch self {
            case .none: return nil
            case .white: return Self.whiteColor
            case .black: return Self.blackColor
            case .text:
                var tint = textColor
                tint.a = 0.40
                return tint
            }
        }
    }

    /// 线型按钮的横线样本，与实际渲染共用同一套 dash 参数。
    static func lineStyleImage(_ style: LineStyle) -> NSImage {
        let size = NSSize(width: 22, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 2, y: size.height / 2))
        line.line(to: NSPoint(x: size.width - 2, y: size.height / 2))
        line.lineWidth = 2
        line.lineCapStyle = .round
        if let pattern = style.dashPattern(lineWidth: 2) {
            line.setLineDash(pattern, count: pattern.count, phase: 0)
        }
        NSColor.white.setStroke()
        line.stroke()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    static func nsColor(_ color: RGBAColor) -> NSColor {
        NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a)
    }

    /// 刷新形状按钮高亮：当前工具描白圈。
    private func refreshSelection() {
        for (kind, button) in toolButtons {
            button.layer?.backgroundColor = !isSelectMode && kind == selectedKind
                ? NSColor(white: 1, alpha: 0.22).cgColor
                : NSColor.clear.cgColor
        }
        selectButton.layer?.backgroundColor = isSelectMode
            ? NSColor(white: 1, alpha: 0.22).cgColor
            : NSColor.clear.cgColor
    }

    /// 识别结果在工具条上短暂提示。后一次提示会让前一次的隐藏计时失效。
    func showMessage(_ text: String) {
        guard !text.isEmpty else { return }
        messageLabel.stringValue = text
        let height: CGFloat = 24
        let fitting = messageLabel.attributedStringValue.size().width
        let width = min(bounds.width - Metrics.padding * 2, ceil(fitting) + 24)
        messageLabel.frame = NSRect(
            x: (bounds.width - width) / 2,
            y: (bounds.height - height) / 2,
            width: width,
            height: height
        )
        messageLabel.isHidden = false
        messageToken += 1
        let token = messageToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.messageToken == token else { return }
            self.messageLabel.isHidden = true
        }
    }

    // MARK: - 弹层

    @objc private func colorTapped() {
        // transient 弹层被点外部关闭后引用仍在，按 isShown 判断而不是非 nil
        if colorPopover?.isShown == true {
            colorPopover?.performClose(nil)
            return
        }
        dismissPopovers()
        let palette = ColorPaletteView(model: paletteModel, selected: currentStyle.color)
        let popover = NSPopover()
        popover.behavior = .transient
        palette.onPick = { [weak self, weak popover] color in
            guard let self else { return }
            // 内置色不带 alpha，换色时沿用当前透明度。
            var picked = color
            picked.a = self.currentStyle.color.a
            self.applyPickedColor(picked)
            popover?.performClose(nil)
        }
        palette.onPickCustom = { [weak self, weak popover] color in
            guard let self else { return }
            // 自定义色自带 alpha，选它就把透明度一起带过来。
            self.applyPickedColor(color)
            popover?.performClose(nil)
        }
        palette.onAddCustom = { [weak self] color in
            guard let self else { return }
            // 面板还在开着，继续调色时要一直跟随，不关弹层。
            self.applyPickedColor(color)
        }
        palette.onPickAlpha = { [weak self] alpha in
            guard let self else { return }
            self.currentStyle.color.a = alpha
            self.refreshStyleButtons()
            self.onStyleChange?(self.currentStyle)
        }
        palette.onPaletteChange = { [weak self] model in
            guard let self else { return }
            self.paletteModel = model
            self.paletteStore.save(model)
        }
        let controller = NSViewController()
        controller.view = palette
        palette.onSizeChange = { [weak controller] size in
            controller?.preferredContentSize = size
        }
        popover.contentViewController = controller
        colorPopover = popover
        popover.show(relativeTo: colorButton.bounds, of: colorButton, preferredEdge: .maxY)
    }

    private func applyPickedColor(_ color: RGBAColor) {
        currentStyle.color = color
        refreshStyleButtons()
        onStyleChange?(currentStyle)
    }

    @objc private func penTapped() {
        if penPopover?.isShown == true {
            penPopover?.performClose(nil)
            return
        }
        dismissPopovers()
        let sizes = PenSizeView(selected: currentStyle.pen)
        let popover = NSPopover()
        popover.behavior = .transient
        sizes.onPick = { [weak self, weak popover] pen in
            guard let self else { return }
            self.currentStyle.pen = pen
            self.refreshStyleButtons()
            self.onStyleChange?(self.currentStyle)
            popover?.performClose(nil)
        }
        let controller = NSViewController()
        controller.view = sizes
        popover.contentViewController = controller
        penPopover = popover
        popover.show(relativeTo: penButton.bounds, of: penButton, preferredEdge: .maxY)
    }

    @objc private func lineStyleTapped() {
        currentStyle.lineStyle = currentStyle.lineStyle.next
        refreshStyleButtons()
        onStyleChange?(currentStyle)
    }

    @objc private func backgroundTapped() {
        let next = BackgroundCycle.of(currentStyle.background).next
        currentStyle.background = next.color(textColor: currentStyle.color)
        refreshStyleButtons()
        onStyleChange?(currentStyle)
    }

    private func dismissPopovers() {
        colorPopover?.performClose(nil)
        penPopover?.performClose(nil)
    }

    // MARK: - 动作

    @objc private func selectModeTapped() {
        selectMode()
        onSelectMode?()
    }

    @objc private func toolTapped(_ sender: NSButton) {
        let kind = ShapeCatalog.p2[sender.tag].kind
        // 样式回读由 OverlayView 统一做，这里只上抛选中的工具。
        onSelectTool?(kind)
    }

    @objc private func copyTapped() { onCopy?() }
    @objc private func extractTextTapped() { onExtractText?() }
    @objc private func scanBarcodeTapped() { onScanBarcode?() }
    @objc private func saveTapped() {
        if saveButton.currentModifiers().contains(.command) {
            onQuickSave?()
        } else {
            onSave?()
        }
    }
    @objc private func cancelTapped() { onCancel?() }
    @objc private func shareTapped() { onShare?() }
}

/// 无边框图标按钮，带悬停高亮。工具条与弹层共用。
@MainActor
class HoverButton: NSButton {
    /// 需要滚轮交互的按钮（颜色按钮调透明度）挂在这里，其余按钮滚轮照常向上传递。
    var onScroll: ((CGFloat) -> Void)?
    /// 点击时的修饰键。生产读全局状态，验收 harness 注入 ⌘ 模拟快捷保存。
    var currentModifiers: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }

    override func scrollWheel(with event: NSEvent) {
        guard let onScroll else {
            super.scrollWheel(with: event)
            return
        }
        onScroll(event.scrollingDeltaY)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
        layer?.cornerRadius = 5
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

/// 调色板弹层：有序色块网格、透明度档位、自定义入口与导入导出。
/// swatches / alphaSwatches / 四个动作按钮暴露给验收 harness 程序化点击。
@MainActor
final class ColorPaletteView: NSView {
    var onPick: ((RGBAColor) -> Void)?
    var onPickCustom: ((RGBAColor) -> Void)?
    /// 颜色面板里选完立即应用，但不关闭调色板弹层。
    var onAddCustom: ((RGBAColor) -> Void)?
    var onPickAlpha: ((CGFloat) -> Void)?
    /// 色块内容或顺序变化后回调，供外部持久化。
    var onPaletteChange: ((PaletteModel) -> Void)?
    var onSizeChange: ((NSSize) -> Void)?

    private(set) var model: PaletteModel
    private(set) var swatches: [HoverButton] = []
    private(set) var alphaSwatches: [HoverButton] = []
    private(set) var customButton: HoverButton!
    private(set) var exportButton: HoverButton!
    private(set) var importButton: HoverButton!
    private(set) var resetButton: HoverButton!

    /// 透明度档位。记号笔另有固定 0.45 渲染叠加，这里的 alpha 是用户可见的那一档。
    static let alphaPresets: [CGFloat] = [1, 0.8, 0.6, 0.4, 0.25]

    private enum Metrics {
        static let side: CGFloat = 26
        static let columns = 4
        static let padding: CGFloat = 10
        static let spacing: CGFloat = 6
        static let alphaGap: CGFloat = 8
        static let actionGap: CGFloat = 8
        static let actionHeight: CGFloat = 22
        static let rowGap: CGFloat = 6
        static let bottomActionWidths: [CGFloat] = [42, 42, 56]
    }

    private var selectedColor: RGBAColor

    init(model: PaletteModel, selected: RGBAColor) {
        self.model = model
        selectedColor = selected
        super.init(frame: NSRect(origin: .zero, size: Self.size(for: model)))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.14, alpha: 0.96).cgColor
        layer?.cornerRadius = 6
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func computeWidth() -> CGFloat {
        let gridWidth = CGFloat(Metrics.columns) * Metrics.side
            + CGFloat(Metrics.columns - 1) * Metrics.spacing
        let alphaWidth = CGFloat(alphaPresets.count) * Metrics.side
            + CGFloat(alphaPresets.count - 1) * Metrics.spacing
        return Metrics.padding * 2 + max(gridWidth, alphaWidth)
    }

    private static func size(for model: PaletteModel) -> NSSize {
        let rows = max(1, (model.colors.count + Metrics.columns - 1) / Metrics.columns)
        let gridHeight = CGFloat(rows) * Metrics.side + CGFloat(rows - 1) * Metrics.spacing
        let height = Metrics.padding * 2 + gridHeight
            + Metrics.alphaGap + Metrics.side
            + Metrics.actionGap + Metrics.actionHeight * 2 + Metrics.rowGap
        return NSSize(width: computeWidth(), height: height)
    }

    /// 色块增删与排序都会重建，数量变化时同步弹层尺寸。
    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        swatches.removeAll()
        alphaSwatches.removeAll()
        frame.size = Self.size(for: model)
        onSizeChange?(frame.size)

        let gridWidth = CGFloat(Metrics.columns) * Metrics.side
            + CGFloat(Metrics.columns - 1) * Metrics.spacing
        let gridX = (frame.width - gridWidth) / 2
        let top = frame.height - Metrics.padding
        for (index, color) in model.colors.enumerated() {
            let column = index % Metrics.columns
            let row = index / Metrics.columns
            let swatch = PaletteSwatchButton()
            swatch.isBordered = false
            swatch.refusesFirstResponder = true
            swatch.image = AnnotateToolbar.dotImage(
                diameter: 18,
                color: AnnotateToolbar.nsColor(color),
                ringed: Self.sameRGB(color, selectedColor)
            )
            swatch.toolTip = model.isCustom(at: index) ? "自定义颜色" : "颜色 \(index + 1)"
            swatch.target = self
            swatch.action = #selector(picked(_:))
            swatch.tag = index
            swatch.swatchIndex = index
            swatch.palette = self
            swatch.frame = NSRect(
                x: gridX + CGFloat(column) * (Metrics.side + Metrics.spacing),
                y: top - Metrics.side - CGFloat(row) * (Metrics.side + Metrics.spacing),
                width: Metrics.side,
                height: Metrics.side
            )
            addSubview(swatch)
            swatches.append(swatch)
        }

        let alphaY = Metrics.padding + Metrics.rowGap + Metrics.actionHeight * 2 + Metrics.actionGap
        let alphaWidth = CGFloat(Self.alphaPresets.count) * Metrics.side
            + CGFloat(Self.alphaPresets.count - 1) * Metrics.spacing
        let alphaX = (frame.width - alphaWidth) / 2
        for (index, alpha) in Self.alphaPresets.enumerated() {
            var shade = selectedColor
            shade.a = alpha
            let swatch = HoverButton()
            swatch.isBordered = false
            swatch.refusesFirstResponder = true
            swatch.image = AnnotateToolbar.dotImage(
                diameter: 18,
                color: AnnotateToolbar.nsColor(shade),
                ringed: abs(selectedColor.a - alpha) < 0.001
            )
            swatch.toolTip = "透明度 \(Int((alpha * 100).rounded()))%"
            swatch.target = self
            swatch.action = #selector(pickedAlpha(_:))
            swatch.tag = index
            swatch.frame = NSRect(
                x: alphaX + CGFloat(index) * (Metrics.side + Metrics.spacing),
                y: alphaY,
                width: Metrics.side,
                height: Metrics.side
            )
            addSubview(swatch)
            alphaSwatches.append(swatch)
        }

        let innerWidth = frame.width - Metrics.padding * 2
        let bottomY = Metrics.padding
        let bottomWidth = Metrics.bottomActionWidths.reduce(0, +)
            + CGFloat(Metrics.bottomActionWidths.count - 1) * Metrics.spacing
        var x = (frame.width - bottomWidth) / 2
        var buttons: [HoverButton] = []
        let bottomActions: [(String, String, Selector)] = [
            ("导出", "导出调色板 JSON", #selector(exportTapped)),
            ("导入", "导入调色板 JSON", #selector(importTapped)),
            ("恢复默认", "恢复默认调色板", #selector(resetTapped)),
        ]
        for (index, entry) in bottomActions.enumerated() {
            let button = makeActionButton(entry.0, toolTip: entry.1, action: entry.2)
            button.frame = NSRect(
                x: x,
                y: bottomY,
                width: Metrics.bottomActionWidths[index],
                height: Metrics.actionHeight
            )
            addSubview(button)
            buttons.append(button)
            x += Metrics.bottomActionWidths[index] + Metrics.spacing
        }
        let custom = makeActionButton("自定义颜色…", toolTip: "自定义颜色…", action: #selector(customTapped))
        custom.frame = NSRect(
            x: Metrics.padding,
            y: bottomY + Metrics.actionHeight + Metrics.rowGap,
            width: innerWidth,
            height: Metrics.actionHeight
        )
        addSubview(custom)

        customButton = custom
        exportButton = buttons[0]
        importButton = buttons[1]
        resetButton = buttons[2]
    }

    private func makeActionButton(_ title: String, toolTip: String, action: Selector) -> HoverButton {
        let button = HoverButton()
        button.isBordered = false
        button.refusesFirstResponder = true
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            ]
        )
        button.toolTip = toolTip
        button.target = self
        button.action = action
        return button
    }

    private static func sameRGB(_ lhs: RGBAColor, _ rhs: RGBAColor) -> Bool {
        lhs.r == rhs.r && lhs.g == rhs.g && lhs.b == rhs.b
    }

    /// 颜色面板选色与验收注入共用：加入自定义色后立即应用。
    func addCustomColor(_ color: RGBAColor) {
        guard PaletteModel.isValid(color) else { return }
        selectedColor = color
        let added = model.addCustom(color)
        rebuild()
        if added { onPaletteChange?(model) }
        onAddCustom?(color)
    }

    fileprivate func dropSwatch(from source: Int, at windowPoint: NSPoint) {
        let point = convert(windowPoint, from: nil)
        guard let destination = swatches.firstIndex(where: { $0.frame.contains(point) }),
              destination != source else { return }
        model.move(from: source, to: destination)
        rebuild()
        onPaletteChange?(model)
    }

    @objc private func picked(_ sender: NSButton) {
        guard model.colors.indices.contains(sender.tag) else { return }
        let color = model.colors[sender.tag]
        selectedColor = color
        if model.isCustom(at: sender.tag) {
            onPickCustom?(color)
        } else {
            onPick?(color)
        }
    }

    @objc private func pickedAlpha(_ sender: NSButton) {
        onPickAlpha?(ColorPaletteView.alphaPresets[sender.tag])
    }

    @objc private func customTapped() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        // 连续模式会在拖色时灌进几十个中间色，提交时再收一个。
        panel.isContinuous = false
        panel.color = AnnotateToolbar.nsColor(selectedColor)
        ColorPanelRouter.shared.palette = self
        panel.setTarget(ColorPanelRouter.shared)
        panel.setAction(#selector(ColorPanelRouter.colorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func exportTapped() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "yaosnap-palette.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? model.jsonData() else { return }
        try? data.write(to: url, options: .atomic)
    }

    @objc private func importTapped() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let imported = PaletteModel.decode(data) else { return }
        model = imported
        rebuild()
        onPaletteChange?(model)
    }

    @objc private func resetTapped() {
        model.reset()
        rebuild()
        onPaletteChange?(model)
    }
}

/// 色块拖拽：按下记录起点，松开时按落点换位。拖拽期间不重建视图，
/// 避免正在接收鼠标事件的按钮被移出层级。
@MainActor
private final class PaletteSwatchButton: HoverButton {
    weak var palette: ColorPaletteView?
    var swatchIndex = 0
    private var dragOrigin: NSPoint?
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - origin.x, point.y - origin.y) > 3 {
            dragged = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragOrigin = nil
            dragged = false
        }
        if dragged {
            palette?.dropSwatch(from: swatchIndex, at: event.locationInWindow)
        } else {
            performClick(nil)
        }
    }
}

/// NSColorPanel 是单例，target 固定在常驻 router 上，
/// 弹层销毁后 weak palette 自动失效，不会留下悬空 target。
@MainActor
private final class ColorPanelRouter: NSObject {
    static let shared = ColorPanelRouter()
    weak var palette: ColorPaletteView?

    @objc func colorChanged(_ sender: NSColorPanel) {
        guard let converted = sender.color.usingColorSpace(.sRGB) else { return }
        palette?.addCustomColor(RGBAColor(
            r: converted.redComponent,
            g: converted.greenComponent,
            b: converted.blueComponent,
            a: converted.alphaComponent
        ))
    }
}

/// 5 档笔尖圆点，横排从小到大。
@MainActor
final class PenSizeView: NSView {
    var onPick: ((PenSize) -> Void)?
    private(set) var swatches: [HoverButton] = []

    private enum Metrics {
        static let side: CGFloat = 26
        static let padding: CGFloat = 10
        static let spacing: CGFloat = 6
    }

    init(selected: PenSize) {
        let width = Metrics.padding * 2
            + CGFloat(PenSize.allCases.count) * Metrics.side
            + CGFloat(PenSize.allCases.count - 1) * Metrics.spacing
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Metrics.side + Metrics.padding * 2))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.14, alpha: 0.96).cgColor
        layer?.cornerRadius = 6

        for pen in PenSize.allCases {
            let index = pen.rawValue - 1
            let button = HoverButton()
            button.isBordered = false
            button.refusesFirstResponder = true
            button.image = AnnotateToolbar.dotImage(
                diameter: 4 + CGFloat(index) * 3,
                color: .white,
                ringed: pen == selected
            )
            button.toolTip = "笔尖 \(pen.rawValue)"
            button.target = self
            button.action = #selector(picked(_:))
            button.tag = index
            button.frame = NSRect(
                x: Metrics.padding + CGFloat(index) * (Metrics.side + Metrics.spacing),
                y: Metrics.padding,
                width: Metrics.side,
                height: Metrics.side
            )
            addSubview(button)
            swatches.append(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func picked(_ sender: NSButton) {
        onPick?(PenSize(rawValue: sender.tag + 1) ?? .p3)
    }
}
