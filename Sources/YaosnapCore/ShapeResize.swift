import CoreGraphics

/// 面状形状的四角缩放控制点。
public enum ShapeHandle: CaseIterable, Equatable {
    case topLeft
    case topRight
    case bottomRight
    case bottomLeft

    public func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.minY)
        }
    }

    var opposite: ShapeHandle {
        switch self {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomRight: return .topLeft
        case .bottomLeft: return .topRight
        }
    }
}

public enum ShapeResize {
    /// 拖 corner 到 point，对角保持不动。越界拖过对角时包围盒翻到另一侧，
    /// 任一边小于 minimum 时按拖动方向钳在 minimum，避免零尺寸形状。
    public static func resizedBox(
        _ rect: CGRect,
        corner: ShapeHandle,
        to point: CGPoint,
        minimum: CGFloat
    ) -> CGRect {
        let anchor = corner.opposite.point(in: rect)
        let width = max(minimum, abs(point.x - anchor.x))
        let height = max(minimum, abs(point.y - anchor.y))
        return CGRect(
            x: point.x >= anchor.x ? anchor.x : anchor.x - width,
            y: point.y >= anchor.y ? anchor.y : anchor.y - height,
            width: width,
            height: height
        )
    }
}

extension Shape {
    /// 只有包围盒即几何的面状形状能缩放；线状形状与文字走各自的交互。
    public var supportsResizeHandles: Bool {
        switch self {
        case .rect, .roundedRect, .ellipse: return true
        default: return false
        }
    }

    /// 把包围盒换成新矩形。圆角半径保持原值，渲染层会按内缩后的短边再钳制。
    public func resized(to rect: CGRect) -> Shape {
        switch self {
        case .rect: return .rect(rect)
        case .roundedRect(_, let radius): return .roundedRect(rect, radius: radius)
        case .ellipse: return .ellipse(rect)
        default: return self
        }
    }
}
