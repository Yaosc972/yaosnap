import CoreGraphics
import Foundation

/// 选中文字的五个控制点。四角用于缩放，rotate 是顶部旋转圆点。
public enum TextHandle: CaseIterable, Equatable {
    case topLeft
    case topRight
    case bottomRight
    case bottomLeft
    case rotate

    public var isCorner: Bool { self != .rotate }
}

/// 文字未旋转包围盒加旋转角，负责控制点位置、旋转后包围盒与命中坐标换算。
public struct TextGeometry: Equatable {
    /// 未旋转的文字包围盒，中心即旋转中心。
    public let rect: CGRect
    public let rotation: CGFloat

    /// 旋转圆点与上边缘的距离，单位点。
    public static let rotationHandleOffset: CGFloat = 24
    public static let minimumFontSize: CGFloat = 6

    public init(rect: CGRect, rotation: CGFloat) {
        self.rect = rect
        self.rotation = rotation
    }

    public var center: CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    public func point(for handle: TextHandle) -> CGPoint {
        let anchor: CGPoint
        switch handle {
        case .topLeft:
            anchor = CGPoint(x: rect.minX, y: rect.maxY)
        case .topRight:
            anchor = CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottomRight:
            anchor = CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft:
            anchor = CGPoint(x: rect.minX, y: rect.minY)
        case .rotate:
            anchor = CGPoint(x: rect.midX, y: rect.maxY + Self.rotationHandleOffset)
        }
        return Self.rotate(anchor, around: center, by: rotation)
    }

    /// 顺时针顺序的四角，直接连成选中框。
    public var corners: [CGPoint] {
        [point(for: .topLeft), point(for: .topRight), point(for: .bottomRight), point(for: .bottomLeft)]
    }

    /// 旋转后的轴对齐包围盒。未旋转时原样返回，避免浮点漂移改变已有 bounds。
    public var rotatedBounds: CGRect {
        guard rotation != 0 else { return rect }
        // 由中心与半轴投影直接算，不经过四个角，平移时数值更稳定。
        let halfWidth = rect.width / 2
        let halfHeight = rect.height / 2
        let cosine = abs(cos(rotation))
        let sine = abs(sin(rotation))
        let extentX = halfWidth * cosine + halfHeight * sine
        let extentY = halfWidth * sine + halfHeight * cosine
        return CGRect(
            x: center.x - extentX,
            y: center.y - extentY,
            width: extentX * 2,
            height: extentY * 2
        )
    }

    /// 世界坐标 → 文字本地坐标。
    public func unrotate(_ point: CGPoint) -> CGPoint {
        Self.rotate(point, around: center, by: -rotation)
    }

    /// 中心不动时按鼠标到中心的距离比缩放字号。
    public static func scaledFontSize(
        _ fontSize: CGFloat,
        from startDistance: CGFloat,
        to currentDistance: CGFloat,
        minimum: CGFloat = TextGeometry.minimumFontSize
    ) -> CGFloat {
        guard startDistance > 0 else { return fontSize }
        return max(minimum, fontSize * currentDistance / startDistance)
    }

    public static func rotate(_ point: CGPoint, around center: CGPoint, by angle: CGFloat) -> CGPoint {
        guard angle != 0 else { return point }
        let dx = point.x - center.x
        let dy = point.y - center.y
        let cosine = cos(angle)
        let sine = sin(angle)
        return CGPoint(
            x: center.x + dx * cosine - dy * sine,
            y: center.y + dx * sine + dy * cosine
        )
    }
}
