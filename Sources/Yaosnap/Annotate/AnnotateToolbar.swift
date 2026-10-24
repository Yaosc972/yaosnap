import AppKit
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
    var onCancel: (() -> Void)?

    private enum Metrics {
        static let buttonSide: CGFloat = 30
        static let spacing: CGFloat = 2
        static let padding: CGFloat = 7
        static let separatorWidth: CGFloat = 1
        static let separatorGap: CGFloat = 6
        static let height: CGFloat = buttonSide + padding * 2
        // 复杂表达式拆开，编译器在单表达式里推不动
        private static let toolRow: CGFloat = CGFloat(ShapeCatalog.p2.count) * buttonSide
            + CGFloat(ShapeCatalog.p2.count - 1) * spacing
        private static let styleRow: CGFloat = buttonSide * 2 + spacing
        private static let actionRow: CGFloat = buttonSide * 5 + spacing * 4
        private static let separators: CGFloat = (separatorGap + separatorWidth + separatorGap) * 3
        static let width: CGFloat = padding * 2 + buttonSide + toolRow + styleRow + actionRow + separators
    }

    private(set) var selectedKind: ShapeKind = .rect
    private(set) var isSelectMode = false
    private(set) var currentStyle: Style
    /// 暴露给验收 harness 程序化点击。
    private(set) var selectButton: HoverButton!
    private(set) var toolButtons: [ShapeKind: HoverButton] = [:]
    private(set) var colorButton: HoverButton!
    private(set) var penButton: HoverButton!
    private(set) var textButton: HoverButton!
    private(set) var barcodeButton: HoverButton!
    private(set) var saveButton: HoverButton!
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

    init(initialKind: ShapeKind, initialStyle: Style) {
        selectedKind = initialKind
        currentStyle = initialStyle
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
        separator()
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

    /// 刷新颜色/笔尖按钮上的圆点，反映当前样式。
    private func refreshStyleButtons() {
        colorButton.image = Self.dotImage(diameter: 16, color: Self.nsColor(currentStyle.color))
        penButton.image = Self.dotImage(
            diameter: Self.penDotDiameter(currentStyle.pen),
            color: .white
        )
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
        let palette = ColorPaletteView(selected: currentStyle.color)
        let popover = NSPopover()
        popover.behavior = .transient
        palette.onPick = { [weak self, weak popover] color in
            guard let self else { return }
            // 换色不改已选透明度，透明度由分组统一持有。
            var picked = color
            picked.a = self.currentStyle.color.a
            self.currentStyle.color = picked
            self.refreshStyleButtons()
            self.onStyleChange?(self.currentStyle)
            popover?.performClose(nil)
        }
        palette.onPickAlpha = { [weak self] alpha in
            guard let self else { return }
            self.currentStyle.color.a = alpha
            self.refreshStyleButtons()
            self.onStyleChange?(self.currentStyle)
        }
        let controller = NSViewController()
        controller.view = palette
        popover.contentViewController = controller
        colorPopover = popover
        popover.show(relativeTo: colorButton.bounds, of: colorButton, preferredEdge: .maxY)
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
}

/// 无边框图标按钮，带悬停高亮。工具条与弹层共用。
@MainActor
final class HoverButton: NSButton {
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

/// 12 色圆点网格加一排透明度档位。swatches / alphaSwatches 暴露给验收 harness 程序化点击。
@MainActor
final class ColorPaletteView: NSView {
    var onPick: ((RGBAColor) -> Void)?
    var onPickAlpha: ((CGFloat) -> Void)?
    private(set) var swatches: [HoverButton] = []
    private(set) var alphaSwatches: [HoverButton] = []

    /// 透明度档位。记号笔另有固定 0.45 渲染叠加，这里的 alpha 是用户可见的那一档。
    static let alphaPresets: [CGFloat] = [1, 0.8, 0.6, 0.4, 0.25]

    private enum Metrics {
        static let side: CGFloat = 26
        static let columns = 4
        static let padding: CGFloat = 10
        static let spacing: CGFloat = 6
        static let alphaGap: CGFloat = 8
    }

    init(selected: RGBAColor) {
        let rows = (RGBAColor.palette.count + Metrics.columns - 1) / Metrics.columns
        let gridWidth = CGFloat(Metrics.columns) * Metrics.side
            + CGFloat(Metrics.columns - 1) * Metrics.spacing
        let alphaWidth = CGFloat(ColorPaletteView.alphaPresets.count) * Metrics.side
            + CGFloat(ColorPaletteView.alphaPresets.count - 1) * Metrics.spacing
        let width = Metrics.padding * 2 + max(gridWidth, alphaWidth)
        let height = Metrics.padding * 2
            + CGFloat(rows) * Metrics.side
            + CGFloat(rows - 1) * Metrics.spacing
            + Metrics.alphaGap + Metrics.side
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.14, alpha: 0.96).cgColor
        layer?.cornerRadius = 6

        let gridX = Metrics.padding + (width - Metrics.padding * 2 - gridWidth) / 2
        for (index, color) in RGBAColor.palette.enumerated() {
            let column = index % Metrics.columns
            let row = index / Metrics.columns
            let swatch = HoverButton()
            swatch.isBordered = false
            swatch.refusesFirstResponder = true
            swatch.image = AnnotateToolbar.dotImage(
                diameter: 18,
                color: AnnotateToolbar.nsColor(color),
                ringed: Self.sameRGB(color, selected)
            )
            swatch.toolTip = "颜色 \(index + 1)"
            swatch.target = self
            swatch.action = #selector(picked(_:))
            swatch.tag = index
            swatch.frame = NSRect(
                x: gridX + CGFloat(column) * (Metrics.side + Metrics.spacing),
                y: height - Metrics.padding - Metrics.side
                    - CGFloat(row) * (Metrics.side + Metrics.spacing),
                width: Metrics.side,
                height: Metrics.side
            )
            addSubview(swatch)
            swatches.append(swatch)
        }

        for (index, alpha) in ColorPaletteView.alphaPresets.enumerated() {
            var shade = selected
            shade.a = alpha
            let swatch = HoverButton()
            swatch.isBordered = false
            swatch.refusesFirstResponder = true
            swatch.image = AnnotateToolbar.dotImage(
                diameter: 18,
                color: AnnotateToolbar.nsColor(shade),
                ringed: abs(selected.a - alpha) < 0.001
            )
            swatch.toolTip = "透明度 \(Int((alpha * 100).rounded()))%"
            swatch.target = self
            swatch.action = #selector(pickedAlpha(_:))
            swatch.tag = index
            swatch.frame = NSRect(
                x: Metrics.padding + CGFloat(index) * (Metrics.side + Metrics.spacing),
                y: Metrics.padding,
                width: Metrics.side,
                height: Metrics.side
            )
            addSubview(swatch)
            alphaSwatches.append(swatch)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func sameRGB(_ lhs: RGBAColor, _ rhs: RGBAColor) -> Bool {
        lhs.r == rhs.r && lhs.g == rhs.g && lhs.b == rhs.b
    }

    @objc private func picked(_ sender: NSButton) {
        onPick?(RGBAColor.palette[sender.tag])
    }

    @objc private func pickedAlpha(_ sender: NSButton) {
        onPickAlpha?(ColorPaletteView.alphaPresets[sender.tag])
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
