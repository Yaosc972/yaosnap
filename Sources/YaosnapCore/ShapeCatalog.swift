import Foundation

/// 形状入库阶段。工具条只显示当前阶段之前的形状，P5 加新形状时改 phase 即可，不过滤架构。
public enum CatalogPhase: Comparable, Codable {
    case p2
    case p5
}

/// 工具条上一个条目的静态描述。
public struct ShapeEntry {
    public let kind: ShapeKind
    public let title: String
    public let symbol: String
    public let shortcut: String
    public let defaultStyle: Style
    /// 该形状属于哪个交付阶段；工具条按当前阶段过滤。
    public let phase: CatalogPhase

    public init(
        kind: ShapeKind,
        title: String,
        symbol: String,
        shortcut: String,
        defaultStyle: Style,
        phase: CatalogPhase
    ) {
        self.kind = kind
        self.title = title
        self.symbol = symbol
        self.shortcut = shortcut
        self.defaultStyle = defaultStyle
        self.phase = phase
    }
}

/// 形状目录。数组顺序即工具条顺序；样式记忆按 kind 查 defaultStyle 兜底。
public enum ShapeCatalog {
    public static let entries: [ShapeEntry] = [
        ShapeEntry(
            kind: .rect,
            title: "矩形",
            symbol: "rectangle",
            shortcut: "R",
            defaultStyle: Style(color: RGBAColor.palette[0], pen: .p3),
            phase: .p2
        ),
        ShapeEntry(
            kind: .roundedRect,
            title: "圆角矩形",
            symbol: "rectangle.roundedtop",
            shortcut: "RR",
            defaultStyle: Style(color: RGBAColor.palette[0], pen: .p3),
            phase: .p2
        ),
        ShapeEntry(
            kind: .ellipse,
            title: "椭圆",
            symbol: "circle",
            shortcut: "O",
            defaultStyle: Style(color: RGBAColor.palette[0], pen: .p3),
            phase: .p2
        ),
        ShapeEntry(
            kind: .line,
            title: "直线",
            symbol: "line.diagonal",
            shortcut: "L",
            defaultStyle: Style(color: RGBAColor.palette[0], pen: .p3),
            phase: .p2
        ),
        ShapeEntry(
            kind: .arrow,
            title: "箭头",
            symbol: "arrow.up.right",
            shortcut: "A",
            defaultStyle: Style(color: RGBAColor.palette[0], pen: .p3),
            phase: .p2
        ),
        ShapeEntry(
            kind: .brush,
            title: "画笔",
            symbol: "pencil.tip",
            shortcut: "B",
            defaultStyle: Style(color: RGBAColor.palette[0], pen: .p3),
            phase: .p2
        ),
        ShapeEntry(
            kind: .marker,
            title: "记号笔",
            symbol: "highlighter",
            shortcut: "H",
            defaultStyle: Style(color: RGBAColor.palette[8], pen: .p4),
            phase: .p2
        ),
        ShapeEntry(
            kind: .mosaic,
            title: "马赛克",
            symbol: "squareshape.split.2x2",
            shortcut: "M",
            defaultStyle: Style(color: RGBAColor.palette[0], pen: .p3),
            phase: .p2
        ),
    ]

    /// P2 阶段工具条应显示的条目。P5 形状入库时标 .p5，这里自动过滤。
    public static var p2: [ShapeEntry] {
        entries.filter { $0.phase <= .p2 }
    }

    public static func entry(for kind: ShapeKind) -> ShapeEntry? {
        entries.first { $0.kind == kind }
    }
}
