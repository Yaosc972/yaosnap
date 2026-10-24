import CoreGraphics
import Foundation

/// 标注颜色。固定 sRGB 语义：渲染时交给 CG 按目标上下文色彩空间匹配，
/// P3 底图上不会偏色。
public struct RGBAColor: Equatable, Codable, Hashable {
    public var r: CGFloat
    public var g: CGFloat
    public var b: CGFloat
    public var a: CGFloat

    public init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// 工具条调色板顺序，12 色固定 sRGB 值。
    public static let palette: [RGBAColor] = [
        RGBAColor(r: 0.96, g: 0.26, b: 0.24),   // 红（默认标注色）
        RGBAColor(r: 0.96, g: 0.55, b: 0.10),   // 橙
        RGBAColor(r: 0.98, g: 0.78, b: 0.10),   // 黄
        RGBAColor(r: 0.22, g: 0.68, b: 0.31),   // 绿
        RGBAColor(r: 0.15, g: 0.68, b: 0.72),   // 青
        RGBAColor(r: 0.20, g: 0.44, b: 0.94),   // 蓝
        RGBAColor(r: 0.55, g: 0.35, b: 0.88),   // 紫
        RGBAColor(r: 0.92, g: 0.30, b: 0.58),   // 粉
        RGBAColor(r: 0.62, g: 0.44, b: 0.30),   // 棕
        RGBAColor(r: 0.10, g: 0.10, b: 0.12),   // 黑
        RGBAColor(r: 0.55, g: 0.55, b: 0.58),   // 灰
        RGBAColor(r: 1.00, g: 1.00, b: 1.00),   // 白
    ]

    /// 画进 CGContext 的颜色。固定用 sRGB 空间构造，CG 负责匹配到上下文空间。
    public var cgColor: CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

/// 笔尖档位。每档同时定义线条宽度与马赛克块尺寸，两套映射互不干扰。
public enum PenSize: Int, CaseIterable, Codable {
    case p1 = 1
    case p2 = 2
    case p3 = 3
    case p4 = 4
    case p5 = 5

    /// 线条类形状（画笔、记号笔、直线、箭头）的宽度，单位点。
    public var lineWidth: CGFloat { Self.lineWidths[rawValue - 1] }

    /// 马赛克块边长，单位点。
    public var mosaicBlock: CGFloat { Self.mosaicBlocks[rawValue - 1] }

    private static let lineWidths: [CGFloat] = [2, 3.5, 5, 7, 10]
    private static let mosaicBlocks: [CGFloat] = [8, 12, 16, 24, 32]
}

/// 形状种类。从 Shape 派生，同时是"每形状记忆颜色与笔尖"的键。
public enum ShapeKind: String, Codable, CaseIterable {
    case rect
    case roundedRect
    case ellipse
    case line
    case arrow
    case brush
    case marker
    case mosaic
}

/// 标注形状。坐标一律是画布点坐标：原点在选区左下角，y 向上。
public enum Shape: Equatable, Codable {
    case rect(CGRect)
    case roundedRect(CGRect, radius: CGFloat)
    case ellipse(CGRect)
    case line(from: CGPoint, to: CGPoint)
    case arrow(from: CGPoint, to: CGPoint)
    case brush([CGPoint])
    case marker([CGPoint])
    case mosaic([CGPoint])

    public var kind: ShapeKind {
        switch self {
        case .rect: return .rect
        case .roundedRect: return .roundedRect
        case .ellipse: return .ellipse
        case .line: return .line
        case .arrow: return .arrow
        case .brush: return .brush
        case .marker: return .marker
        case .mosaic: return .mosaic
        }
    }

    /// 画布坐标系下的包围盒。渲染裁剪与未来命中测试都用它。
    public var bounds: CGRect {
        switch self {
        case .rect(let rect), .roundedRect(let rect, _), .ellipse(let rect):
            return rect
        case .line(let from, let to), .arrow(let from, let to):
            return RectMath.normalizedRect(from: from, to: to)
        case .brush(let points), .marker(let points), .mosaic(let points):
            guard let first = points.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x)
                maxX = max(maxX, point.x)
                minY = min(minY, point.y)
                maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }
}

public struct Style: Equatable, Codable {
    public var color: RGBAColor
    public var pen: PenSize

    public init(color: RGBAColor, pen: PenSize) {
        self.color = color
        self.pen = pen
    }
}

/// 一条标注。id 稳定不变，二次编辑（下一批）靠它定位。
public struct Annotation: Identifiable, Equatable, Codable {
    public let id: UUID
    public var shape: Shape
    public var style: Style

    public init(id: UUID = UUID(), shape: Shape, style: Style) {
        self.id = id
        self.shape = shape
        self.style = style
    }
}
