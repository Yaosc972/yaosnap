import CoreGraphics

/// 标注工具条的摆放规则。纯函数，单测覆盖三种回退分支与钳制。
public enum ToolbarPlacement {
    /// 优先级：选区下方外侧、上方外侧、选区内右下。
    /// x 对齐选区右缘，钳制在 bounds 内 4pt 边距。
    public static func origin(
        toolbarSize: CGSize,
        selection: CGRect,
        within bounds: CGRect
    ) -> CGPoint {
        let margin: CGFloat = 4
        let gap: CGFloat = 6
        var origin = CGPoint(
            x: selection.maxX - toolbarSize.width,
            y: selection.minY - toolbarSize.height - gap
        )
        if origin.y < bounds.minY + margin {
            origin.y = selection.maxY + gap
            if origin.y + toolbarSize.height > bounds.maxY - margin {
                // 上下外侧都放不下：退回选区内右下
                origin.y = selection.minY + gap
            }
        }
        origin.x = min(max(origin.x, bounds.minX + margin), bounds.maxX - toolbarSize.width - margin)
        return origin
    }
}
