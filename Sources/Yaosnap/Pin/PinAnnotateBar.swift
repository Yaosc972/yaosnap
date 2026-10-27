import AppKit
import YaosnapCore

/// 标注模式底栏：形状、颜色、撤销与完成取消。仅在标注模式显示。
@MainActor
final class PinAnnotateBar: NSView {
    var onSelectTool: ((ShapeKind) -> Void)?
    var onCycleColor: (() -> Void)?
    var onUndo: (() -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    /// 工具顺序即显示顺序，与第一版支持的五种形状一致。
    static let tools: [ShapeKind] = [.rect, .ellipse, .arrow, .brush, .text]

    private var toolButtons: [ShapeKind: NSButton] = [:]
    private lazy var colorButton = PinToolbar.button("paintpalette", "标注颜色", #selector(colorTapped), target: self)
    private lazy var undoButton = PinToolbar.button("arrow.uturn.backward", "撤销标注", #selector(undoTapped), target: self)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.88).cgColor
        layer?.cornerRadius = 6

        var views: [NSView] = []
        for kind in Self.tools {
            guard let entry = ShapeCatalog.entry(for: kind) else { continue }
            let button = PinToolbar.button(entry.symbol, entry.title, #selector(toolTapped(_:)), target: self)
            toolButtons[kind] = button
            views.append(button)
        }
        views.append(PinToolbar.separator())
        views.append(colorButton)
        views.append(PinToolbar.separator())
        views.append(undoButton)
        views.append(PinToolbar.button("checkmark", "完成标注", #selector(finishTapped), target: self))
        views.append(PinToolbar.button("xmark", "取消标注", #selector(cancelTapped), target: self))

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = PinToolbar.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PinToolbar.padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PinToolbar.padding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: PinToolbar.padding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -PinToolbar.padding),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未使用")
    }

    /// 同步当前工具高亮、颜色圆点与撤销可用性。
    func updateState(tool: ShapeKind, color: RGBAColor, canUndo: Bool) {
        for (kind, button) in toolButtons {
            button.contentTintColor = kind == tool
                ? .white
                : NSColor(white: 1, alpha: 0.55)
        }
        colorButton.image = Self.swatchImage(color)
        undoButton.isEnabled = canUndo
    }

    private static func swatchImage(_ color: RGBAColor) -> NSImage {
        let side = CGFloat(12)
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor(cgColor: color.cgColor)?.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: side, height: side)).fill()
        image.unlockFocus()
        return image
    }

    @objc private func toolTapped(_ sender: NSButton) {
        guard let kind = toolButtons.first(where: { $0.value === sender })?.key else { return }
        onSelectTool?(kind)
    }

    @objc private func colorTapped() { onCycleColor?() }
    @objc private func undoTapped() { onUndo?() }
    @objc private func finishTapped() { onFinish?() }
    @objc private func cancelTapped() { onCancel?() }
}
