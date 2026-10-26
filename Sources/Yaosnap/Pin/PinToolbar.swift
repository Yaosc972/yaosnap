import AppKit

/// 贴图窗口顶部的悬浮工具条。鼠标进入窗口时出现，离开后隐藏。
@MainActor
final class PinToolbar: NSView {
    var onZoomOut: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onRotateLeft: (() -> Void)?
    var onRotateRight: (() -> Void)?
    var onFlipHorizontal: (() -> Void)?
    var onFlipVertical: (() -> Void)?
    var onGrayscale: (() -> Void)?
    var onInverted: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?

    private static let buttonSide: CGFloat = 22
    private static let padding: CGFloat = 6
    private static let spacing: CGFloat = 2

    private let sizeLabel = NSTextField(labelWithString: "大小: 100%")
    private var stack: NSStackView!

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.88).cgColor
        layer?.cornerRadius = 6

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        sizeLabel.textColor = NSColor(white: 1, alpha: 0.85)
        sizeLabel.alignment = .right

        let views: [NSView] = [
            button("minus.magnifyingglass", "缩小", #selector(zoomOutTapped)),
            button("plus.magnifyingglass", "放大", #selector(zoomInTapped)),
            separator(),
            button("rotate.left", "向左旋转", #selector(rotateLeftTapped)),
            button("rotate.right", "向右旋转", #selector(rotateRightTapped)),
            button("flip.horizontal", "水平翻转", #selector(flipHorizontalTapped)),
            button("flip.vertical", "垂直翻转", #selector(flipVerticalTapped)),
            separator(),
            button("circle.lefthalf.filled", "灰度", #selector(grayscaleTapped)),
            button("circle.righthalf.filled", "反色", #selector(invertedTapped)),
            separator(),
            button("doc.on.doc", "复制图像", #selector(copyTapped)),
            button("square.and.arrow.down", "另存为", #selector(saveTapped)),
            button("xmark", "关闭", #selector(closeTapped)),
            sizeLabel,
        ]

        stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Self.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding),
        ])
        sizeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未使用")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: stack.fittingSize.width + Self.padding * 2,
            height: Self.buttonSide + Self.padding * 2
        )
    }

    func updateStyle(scale: CGFloat) {
        sizeLabel.stringValue = "大小: \(Int((scale * 100).rounded()))%"
    }

    private func button(_ symbol: String, _ title: String, _ action: Selector) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageOnly
        button.contentTintColor = NSColor(white: 1, alpha: 0.9)
        button.toolTip = title
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.buttonSide),
            button.heightAnchor.constraint(equalToConstant: Self.buttonSide),
        ])
        return button
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return line
    }

    @objc private func zoomOutTapped() { onZoomOut?() }
    @objc private func zoomInTapped() { onZoomIn?() }
    @objc private func rotateLeftTapped() { onRotateLeft?() }
    @objc private func rotateRightTapped() { onRotateRight?() }
    @objc private func flipHorizontalTapped() { onFlipHorizontal?() }
    @objc private func flipVerticalTapped() { onFlipVertical?() }
    @objc private func grayscaleTapped() { onGrayscale?() }
    @objc private func invertedTapped() { onInverted?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func saveTapped() { onSave?() }
    @objc private func closeTapped() { onClose?() }
}
