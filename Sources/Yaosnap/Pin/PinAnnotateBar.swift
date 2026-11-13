import AppKit
import YaosnapCore

/// 贴图底栏只用到一次颜色转换，单独收一个入口，
/// 免得为了它把整个 AnnotateToolbar 拖进贴图 harness 的编译清单。
enum AnnotateToolbarColor {
    static func ns(_ color: RGBAColor) -> NSColor {
        NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a)
    }
}

/// 标注模式底栏：与截图主界面同一套工具（矩形/圆角/椭圆/直线/箭头/折线/画笔/记号笔/
/// 马赛克/矩形马赛克/模糊/放大镜/文字/序号/橡皮擦），外加颜色、笔宽、撤销与完成取消。
/// 仅在标注模式显示。
@MainActor
final class PinAnnotateBar: NSView {
    var onSelectTool: ((ShapeKind) -> Void)?
    var onCycleColor: (() -> Void)?
    var onCyclePen: (() -> Void)?
    var onUndo: (() -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    /// 顺序即显示顺序，两行排版：形状等宽，控制项放第二行末尾。
    private static let toolRows: [[ShapeKind]] = [
        [.rect, .roundedRect, .ellipse, .line, .arrow, .polyline, .brush, .marker],
        [.mosaic, .mosaicRect, .blur, .magnify, .text, .serial, .eraser],
    ]

    private var toolButtons: [ShapeKind: NSButton] = [:]

    /// 底栏必须覆盖截图主界面的全部工具，验收 harness 用它做完整性断言。
    var exposedTools: [ShapeKind] { Array(toolButtons.keys) }
    private lazy var colorButton = PinToolbar.glyphButton(
        .close, "标注颜色", #selector(colorTapped), target: self
    )
    private lazy var penButton = PinToolbar.glyphButton(
        .close, "笔宽", #selector(penTapped), target: self
    )
    private lazy var undoButton = PinToolbar.glyphButton(.undo, "撤销标注", #selector(undoTapped), target: self)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.9).cgColor
        layer?.cornerRadius = 6

        var rowViews: [NSView] = []
        for kinds in Self.toolRows {
            var views: [NSView] = []
            for kind in kinds {
                guard let entry = ShapeCatalog.entry(for: kind) else { continue }
                let button = PinToolbar.glyphButton(
                    ToolbarGlyph.shape(kind),
                    entry.title,
                    #selector(toolTapped(_:)),
                    target: self
                )
                button.tag = Self.tag(for: kind)
                toolButtons[kind] = button
                views.append(button)
            }
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = PinToolbar.spacing
            rowViews.append(row)
        }
        let controls = NSStackView(views: [
            PinToolbar.separator(),
            colorButton,
            penButton,
            PinToolbar.separator(),
            undoButton,
            PinToolbar.glyphButton(.check, "完成标注", #selector(finishTapped), target: self),
            PinToolbar.glyphButton(.close, "取消标注", #selector(cancelTapped), target: self),
        ])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = PinToolbar.spacing
        rowViews.append(controls)

        let stack = NSStackView(views: rowViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
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

    /// 底栏按内容自适应尺寸。
    ///
    /// 这一条不能少：PinWindow 用 `intrinsicContentSize` 给底栏定 frame，
    /// 缺了它 NSView 返回 (-1,-1)，底栏会被摆成 0×0——点了「标注」什么都不会出现。
    override var intrinsicContentSize: NSSize {
        guard let stack = subviews.first else { return NSSize(width: 320, height: 64) }
        let size = stack.fittingSize
        return NSSize(
            width: size.width + PinToolbar.padding * 2,
            height: size.height + PinToolbar.padding * 2
        )
    }

    /// 同步当前工具高亮、颜色圆点与撤销可用性。
    func updateState(tool: ShapeKind, color: RGBAColor, pen: PenSize, canUndo: Bool) {
        for (kind, button) in toolButtons {
            button.contentTintColor = kind == tool
                ? .white
                : NSColor(white: 1, alpha: 0.5)
        }
        colorButton.image = Self.swatchImage(color)
        penButton.image = ToolbarGlyph.penWidth(pen)
        penButton.toolTip = "笔宽 \(pen.rawValue)"
        undoButton.isEnabled = canUndo
        undoButton.alphaValue = canUndo ? 1 : 0.35
    }

    private static func tag(for kind: ShapeKind) -> Int {
        ShapeKind.allCases.firstIndex(of: kind) ?? 0
    }

    private static func kind(forTag tag: Int) -> ShapeKind? {
        ShapeKind.allCases.indices.contains(tag) ? ShapeKind.allCases[tag] : nil
    }

    /// 颜色按钮：与截图工具条同一套画法，带白圈才看得出是色块而不是普通圆点。
    private static func swatchImage(_ color: RGBAColor) -> NSImage {
        ToolbarGlyph.colorDot(AnnotateToolbarColor.ns(color))
    }

    @objc private func toolTapped(_ sender: NSButton) {
        guard let kind = Self.kind(forTag: sender.tag) else { return }
        onSelectTool?(kind)
    }

    @objc private func colorTapped() { onCycleColor?() }
    @objc private func penTapped() { onCyclePen?() }
    @objc private func undoTapped() { onUndo?() }
    @objc private func finishTapped() { onFinish?() }
    @objc private func cancelTapped() { onCancel?() }
}