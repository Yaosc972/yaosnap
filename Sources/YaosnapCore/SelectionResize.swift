import CoreGraphics

/// 选区八向调整手柄：四条边与四个角。
/// 视图坐标原点在左下、y 向上，因此 top 对应 rect.maxY，bottom 对应 rect.minY。
public enum SelectionEdge: CaseIterable, Equatable {
    case top
    case bottom
    case left
    case right
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    /// 命中检测：点落在 rect 外扩 tolerance 的环带内才算命中；四角优先于四边。
    /// 命中四边时，另一轴投影必须落在该边端点之间（含 tolerance）。
    public static func hit(point: CGPoint, in rect: CGRect, tolerance: CGFloat) -> SelectionEdge? {
        guard !rect.isEmpty else { return nil }
        let tolerance = max(0, tolerance)

        let corners: [(edge: SelectionEdge, point: CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.minY)),
        ]
        for corner in corners
        where abs(point.x - corner.point.x) <= tolerance
            && abs(point.y - corner.point.y) <= tolerance {
            return corner.edge
        }

        if abs(point.y - rect.maxY) <= tolerance,
           point.x >= rect.minX - tolerance, point.x <= rect.maxX + tolerance {
            return .top
        }
        if abs(point.y - rect.minY) <= tolerance,
           point.x >= rect.minX - tolerance, point.x <= rect.maxX + tolerance {
            return .bottom
        }
        if abs(point.x - rect.minX) <= tolerance,
           point.y >= rect.minY - tolerance, point.y <= rect.maxY + tolerance {
            return .left
        }
        if abs(point.x - rect.maxX) <= tolerance,
           point.y >= rect.minY - tolerance, point.y <= rect.maxY + tolerance {
            return .right
        }
        return nil
    }

    /// 按拖动点生成新矩形：只改命中的那条边或那两条边，对边保持不动；
    /// 拖过对边时钳在 minimum 处而不翻转；结果宽高不小于 minimum，并最终裁进 bounds。
    /// rect 为空时原样返回。
    public static func resized(
        _ rect: CGRect,
        edge: SelectionEdge,
        to point: CGPoint,
        minimum: CGFloat,
        within bounds: CGRect
    ) -> CGRect {
        guard !rect.isEmpty else { return rect }
        let minimum = max(0, minimum)

        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch edge {
        case .left, .topLeft, .bottomLeft:
            minX = min(point.x, maxX - minimum)
        case .right, .topRight, .bottomRight:
            maxX = max(point.x, minX + minimum)
        case .top, .bottom:
            break
        }
        switch edge {
        case .top, .topLeft, .topRight:
            maxY = max(point.y, minY + minimum)
        case .bottom, .bottomLeft, .bottomRight:
            minY = min(point.y, maxY - minimum)
        case .left, .right:
            break
        }

        // bounds 优先于 minimum：先裁掉越界部分（只动拖动侧），再补最小尺寸。
        minX = max(minX, bounds.minX)
        maxX = min(maxX, bounds.maxX)
        minY = max(minY, bounds.minY)
        maxY = min(maxY, bounds.maxY)

        if maxX - minX < minimum {
            maxX = min(bounds.maxX, minX + minimum)
            minX = max(bounds.minX, maxX - minimum)
        }
        if maxY - minY < minimum {
            maxY = min(bounds.maxY, minY + minimum)
            minY = max(bounds.minY, maxY - minimum)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
