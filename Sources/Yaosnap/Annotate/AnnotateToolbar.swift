import AppKit
import YaosnapCore

/// 选区标注工具条：形状选择、颜色/笔尖弹层、复制/保存/取消。
/// 单行布局：[形状按钮][分隔][颜色][笔尖][分隔][复制][保存][取消]。
@MainActor
final class AnnotateToolbar: NSView {
    var onSelectTool: ((ShapeKind) -> Void)?
    var onStyleChange: ((Style) -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
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
        private static let actionRow: CGFloat = buttonSide * 3 + spacing * 2
        private static let separators: CGFloat = (separatorGap + separatorWidth + separatorGap) * 2
        static let width: CGFloat = padding * 2 + toolRow + styleRow + actionRow + separators
    }

    private(set) var selectedKind: ShapeKind = .rect
    private(set) var currentStyle: Style
    /// 暴露给验收 harness 程序化点击。
    private(set) var toolButtons: [ShapeKind: HoverButton] = [:]
    private(set) var colorButton: HoverButton!
    private(set) var penButton: HoverButton!
    private(set) var colorPopover: NSPopover?
    private(set) var penPopover: NSPopover?

    init(initialKind: ShapeKind, initialStyle: Style) {
        selectedKind = initialKind
        currentStyle = initialStyle
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.height))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        layer?.cornerRadius = 8
        layoutButtons()
        refreshStyleButtons()
        refreshSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 吞掉容器空白区的点击，避免落到覆盖视图上开始新拖拽。
    override func mouseDown(with event: NSEvent) {}

    /// 选中形状按钮。快捷键与点击共用，幂等。
    func select(_ kind: ShapeKind) {
        selectedKind = kind
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
        place(colorButton)
        penButton = makeHoverButton(symbol: nil, title: "笔尖", action: #selector(penTapped))
        place(penButton)
        separator()
        place(makeHoverButton(symbol: "doc.on.doc", title: "复制", action: #selector(copyTapped)))
        place(makeHoverButton(symbol: "square.and.arrow.down", title: "保存", action: #selector(saveTapped)))
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
        NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1)
    }

    /// 刷新形状按钮高亮：当前工具描白圈。
    private func refreshSelection() {
        for (kind, button) in toolButtons {
            button.layer?.backgroundColor = kind == selectedKind
                ? NSColor(white: 1, alpha: 0.22).cgColor
                : NSColor.clear.cgColor
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
            self.currentStyle.color = color
            self.refreshStyleButtons()
            self.onStyleChange?(self.currentStyle)
            popover?.performClose(nil)
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

    @objc private func toolTapped(_ sender: NSButton) {
        let kind = ShapeCatalog.p2[sender.tag].kind
        select(kind)
        onSelectTool?(kind)
    }

    @objc private func copyTapped() { onCopy?() }
    @objc private func saveTapped() { onSave?() }
    @objc private func cancelTapped() { onCancel?() }
}

/// 无边框图标按钮，带悬停高亮。工具条与弹层共用。
@MainActor
final class HoverButton: NSButton {
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

/// 12 色圆点网格，4 列。swatches 暴露给验收 harness 程序化点击。
@MainActor
final class ColorPaletteView: NSView {
    var onPick: ((RGBAColor) -> Void)?
    private(set) var swatches: [HoverButton] = []

    private enum Metrics {
        static let side: CGFloat = 26
        static let columns = 4
        static let padding: CGFloat = 10
        static let spacing: CGFloat = 6
    }

    init(selected: RGBAColor) {
        let rows = (RGBAColor.palette.count + Metrics.columns - 1) / Metrics.columns
        let width = Metrics.padding * 2
            + CGFloat(Metrics.columns) * Metrics.side
            + CGFloat(Metrics.columns - 1) * Metrics.spacing
        let height = Metrics.padding * 2
            + CGFloat(rows) * Metrics.side
            + CGFloat(rows - 1) * Metrics.spacing
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.14, alpha: 0.96).cgColor
        layer?.cornerRadius = 6

        for (index, color) in RGBAColor.palette.enumerated() {
            let column = index % Metrics.columns
            let row = index / Metrics.columns
            let button = HoverButton()
            button.isBordered = false
            button.refusesFirstResponder = true
            button.image = AnnotateToolbar.dotImage(
                diameter: 18,
                color: AnnotateToolbar.nsColor(color),
                ringed: color == selected
            )
            button.toolTip = "颜色 \(index + 1)"
            button.target = self
            button.action = #selector(picked(_:))
            button.tag = index
            button.frame = NSRect(
                x: Metrics.padding + CGFloat(column) * (Metrics.side + Metrics.spacing),
                y: height - Metrics.padding - Metrics.side - CGFloat(row) * (Metrics.side + Metrics.spacing),
                width: Metrics.side,
                height: Metrics.side
            )
            addSubview(button)
            swatches.append(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func picked(_ sender: NSButton) {
        onPick?(RGBAColor.palette[sender.tag])
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
