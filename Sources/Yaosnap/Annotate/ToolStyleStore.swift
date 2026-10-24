import Foundation
import YaosnapCore

/// 每形状独立记忆颜色与笔尖。切工具读回该工具上次样式，改样式写回当前工具；
/// 没改过的工具取 ShapeCatalog 默认值。
struct ToolStyleStore {
    private(set) var currentKind: ShapeKind = .rect
    private var styles: [ShapeKind: Style] = [:]

    var currentStyle: Style { style(for: currentKind) }

    func style(for kind: ShapeKind) -> Style {
        styles[kind] ?? ShapeCatalog.entry(for: kind)?.defaultStyle
            ?? Style(color: RGBAColor.palette[0], pen: .p3)
    }

    /// 切换当前工具，返回该工具的记忆样式。
    @discardableResult
    mutating func select(_ kind: ShapeKind) -> Style {
        currentKind = kind
        return currentStyle
    }

    /// 把样式写回当前工具。
    mutating func update(_ style: Style) {
        styles[currentKind] = style
    }
}
