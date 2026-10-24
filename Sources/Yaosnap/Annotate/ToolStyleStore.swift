import Foundation
import YaosnapCore

/// 每形状独立记忆颜色与笔尖。切工具读回该工具上次样式，改样式写回当前工具；
/// 没改过的工具取 ShapeCatalog 默认值。
/// 透明度按 Snipaste 分组：记号笔独占一档，其余工具共用一档。
struct ToolStyleStore {
    private(set) var currentKind: ShapeKind = .rect
    private var styles: [ShapeKind: Style] = [:]
    private(set) var sharedAlpha: CGFloat = 1
    private(set) var markerAlpha: CGFloat = 1

    var currentStyle: Style { style(for: currentKind) }

    func alpha(for kind: ShapeKind) -> CGFloat {
        kind == .marker ? markerAlpha : sharedAlpha
    }

    func style(for kind: ShapeKind) -> Style {
        var style = styles[kind] ?? ShapeCatalog.entry(for: kind)?.defaultStyle
            ?? Style(color: RGBAColor.palette[0], pen: .p3)
        style.color.a = alpha(for: kind)
        return style
    }

    /// 切换当前工具，返回该工具的记忆样式。
    @discardableResult
    mutating func select(_ kind: ShapeKind) -> Style {
        currentKind = kind
        return currentStyle
    }

    /// 把颜色与笔尖写回当前工具。alpha 由分组统一持有，这里不复制调用方的值。
    mutating func update(_ style: Style) {
        var stored = style
        stored.color.a = alpha(for: currentKind)
        styles[currentKind] = stored
    }

    mutating func updateAlpha(_ alpha: CGFloat) {
        let clamped = min(max(alpha, 0.05), 1)
        if currentKind == .marker {
            markerAlpha = clamped
        } else {
            sharedAlpha = clamped
        }
    }
}
