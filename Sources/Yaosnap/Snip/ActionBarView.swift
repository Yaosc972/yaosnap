import AppKit

/// 选区右下角的操作工具条：复制 / 保存 / 取消。
@MainActor
final class ActionBarView: NSView {
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    private static let buttonSide: CGFloat = 30
    private static let spacing: CGFloat = 2
    private static let padding: CGFloat = 5
    static let height: CGFloat = buttonSide + padding * 2
    static let width: CGFloat = padding * 2 + buttonSide * 3 + spacing * 2

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        layer?.cornerRadius = 8

        let specs: [(String, String, Selector)] = [
            ("doc.on.doc", "复制", #selector(copyTapped)),
            ("square.and.arrow.down", "保存", #selector(saveTapped)),
            ("xmark", "取消", #selector(cancelTapped)),
        ]
        for (index, spec) in specs.enumerated() {
            let button = HoverButton()
            button.isBordered = false
            button.refusesFirstResponder = true
            button.image = NSImage(
                systemSymbolName: spec.0,
                accessibilityDescription: spec.1
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            )
            button.contentTintColor = .white
            button.toolTip = spec.1
            button.target = self
            button.action = spec.2
            button.frame = NSRect(
                x: Self.padding + CGFloat(index) * (Self.buttonSide + Self.spacing),
                y: Self.padding,
                width: Self.buttonSide,
                height: Self.buttonSide
            )
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 吞掉容器空白区的点击，避免落到覆盖视图上开始新拖拽。
    override func mouseDown(with event: NSEvent) {}

    @objc private func copyTapped() { onCopy?() }
    @objc private func saveTapped() { onSave?() }
    @objc private func cancelTapped() { onCancel?() }
}

/// 无边框图标按钮，带悬停高亮。
@MainActor
private final class HoverButton: NSButton {
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
