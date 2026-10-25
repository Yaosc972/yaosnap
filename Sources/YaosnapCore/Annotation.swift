import CoreGraphics
import Foundation

/// 标注颜色。固定 sRGB 语义：渲染时交给 CG 按目标上下文色彩空间匹配，
/// P3 底图上不会偏色。
public struct RGBAColor: Equatable, Codable, Hashable, Sendable {
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

    /// 文字工具字号，单位点。
    public var textFontSize: CGFloat { Self.textFontSizes[rawValue - 1] }

    /// 序号标记半径，单位点。数字要留在圆内，不能直接跟线条宽度走。
    public var serialRadius: CGFloat { Self.serialRadii[rawValue - 1] }

    /// 模糊半径，单位点。与马赛克共用一档强度，只是效果从块化换成平滑。
    public var blurRadius: CGFloat { mosaicBlock }

    private static let lineWidths: [CGFloat] = [2, 3.5, 5, 7, 10]
    private static let mosaicBlocks: [CGFloat] = [8, 12, 16, 24, 32]
    private static let textFontSizes: [CGFloat] = [14, 18, 22, 28, 36]
    private static let serialRadii: [CGFloat] = [10, 12, 14, 18, 22]
}

/// 形状种类。从 Shape 派生，同时是"每形状记忆颜色与笔尖"的键。
public enum ShapeKind: String, Codable, CaseIterable {
    case rect
    case roundedRect
    case ellipse
    case line
    case arrow
    case polyline
    case brush
    case marker
    case mosaic
    case blur
    case text
    case serial
    case eraser
}

/// 标注形状。坐标一律是画布点坐标：原点在选区左下角，y 向上。
public enum Shape: Equatable, Codable {
    case rect(CGRect)
    case roundedRect(CGRect, radius: CGFloat)
    case ellipse(CGRect)
    case line(from: CGPoint, to: CGPoint)
    case arrow(from: CGPoint, to: CGPoint)
    case polyline([CGPoint])
    case brush([CGPoint])
    case marker([CGPoint])
    case mosaic([CGPoint])
    case blur([CGPoint])
    /// origin 为文本基线起点，画布点坐标。字号独立于 PenSize 的线条宽度。
    /// rotation 是绕未旋转包围盒中心的弧度，0 表示水平。
    case text(String, origin: CGPoint, fontSize: CGFloat, rotation: CGFloat)
    /// 序号标记：实心圆加居中数字。value 由创建顺序决定，radius 由笔尖档位决定。
    case serial(value: Int, center: CGPoint, radius: CGFloat)

    public var kind: ShapeKind {
        switch self {
        case .rect: return .rect
        case .roundedRect: return .roundedRect
        case .ellipse: return .ellipse
        case .line: return .line
        case .arrow: return .arrow
        case .polyline: return .polyline
        case .brush: return .brush
        case .marker: return .marker
        case .mosaic: return .mosaic
        case .blur: return .blur
        case .text: return .text
        case .serial: return .serial
        }
    }

    /// 画布坐标系下的包围盒。渲染裁剪与未来命中测试都用它。
    public var bounds: CGRect {
        switch self {
        case .rect(let rect), .roundedRect(let rect, _), .ellipse(let rect):
            return rect
        case .line(let from, let to), .arrow(let from, let to):
            return RectMath.normalizedRect(from: from, to: to)
        case .brush(let points), .marker(let points), .mosaic(let points), .blur(let points),
             .polyline(let points):
            guard let first = points.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x)
                maxX = max(maxX, point.x)
                minY = min(minY, point.y)
                maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .text(let string, let origin, let fontSize, let rotation):
            return TextGeometry(
                rect: TextMetrics.boundingRect(string, fontSize: fontSize, origin: origin),
                rotation: rotation
            ).rotatedBounds
        case .serial(_, let center, let radius):
            return CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        }
    }

    /// 命中测试。面状形状按包围盒（外扩 tolerance）判断，线状按到路径的距离判断。
    public func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch self {
        case .rect(let rect), .roundedRect(let rect, _):
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .ellipse(let rect):
            // 按椭圆方程判断，包围盒四角不算命中。
            let rx = rect.width / 2 + tolerance
            let ry = rect.height / 2 + tolerance
            guard rx > 0, ry > 0 else { return false }
            let nx = (point.x - rect.midX) / rx
            let ny = (point.y - rect.midY) / ry
            return nx * nx + ny * ny <= 1
        case .text(let string, let origin, let fontSize, let rotation):
            let rect = TextMetrics.boundingRect(string, fontSize: fontSize, origin: origin)
            // 反向旋转回本地坐标再按未旋转包围盒判断，旋转后的命中与视觉一致。
            let local = TextGeometry(rect: rect, rotation: rotation).unrotate(point)
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(local)
        case .line(let from, let to), .arrow(let from, let to):
            return Self.distance(from: point, toSegmentFrom: from, to: to) <= tolerance
        case .brush(let points), .marker(let points), .mosaic(let points), .blur(let points),
             .polyline(let points):
            guard let first = points.first else { return false }
            guard points.count > 1 else {
                return hypot(point.x - first.x, point.y - first.y) <= tolerance
            }
            // 单点笔画退化成点距离，多点是折线，任一相邻段命中即可。
            return zip(points, points.dropFirst()).contains { segment in
                Self.distance(from: point, toSegmentFrom: segment.0, to: segment.1) <= tolerance
            }
        case .serial(_, let center, let radius):
            return hypot(point.x - center.x, point.y - center.y) <= radius + tolerance
        }
    }

    /// 整体平移。文本的 origin 也要跟着走，否则包围盒会留在原位。
    public func translated(by delta: CGPoint) -> Shape {
        func moved(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x + delta.x, y: point.y + delta.y)
        }
        switch self {
        case .rect(let rect):
            return .rect(rect.offsetBy(dx: delta.x, dy: delta.y))
        case .roundedRect(let rect, let radius):
            return .roundedRect(rect.offsetBy(dx: delta.x, dy: delta.y), radius: radius)
        case .ellipse(let rect):
            return .ellipse(rect.offsetBy(dx: delta.x, dy: delta.y))
        case .line(let from, let to):
            return .line(from: moved(from), to: moved(to))
        case .arrow(let from, let to):
            return .arrow(from: moved(from), to: moved(to))
        case .polyline(let points):
            return .polyline(points.map(moved))
        case .brush(let points):
            return .brush(points.map(moved))
        case .marker(let points):
            return .marker(points.map(moved))
        case .mosaic(let points):
            return .mosaic(points.map(moved))
        case .blur(let points):
            return .blur(points.map(moved))
        case .text(let string, let origin, let fontSize, let rotation):
            return .text(string, origin: moved(origin), fontSize: fontSize, rotation: rotation)
        case .serial(let value, let center, let radius):
            return .serial(value: value, center: moved(center), radius: radius)
        }
    }

    /// 橡皮擦笔迹是否穿过本形状。先按包围盒排除，再沿路径按容差采样命中。
    /// tolerance 同时是橡皮擦笔宽，决定采样步长。
    public func intersects(path: [CGPoint], tolerance: CGFloat) -> Bool {
        guard let first = path.first else { return false }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in path.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        let box = bounds.insetBy(dx: -tolerance, dy: -tolerance)
        guard box.maxX >= minX, box.minX <= maxX, box.maxY >= minY, box.minY <= maxY else {
            return false
        }
        let step = max(1, tolerance / 2)
        for (start, end) in zip(path, path.dropFirst()) {
            let length = hypot(end.x - start.x, end.y - start.y)
            let divisions = max(1, Int(ceil(length / step)))
            for index in 0...divisions {
                let t = CGFloat(index) / CGFloat(divisions)
                let sample = CGPoint(
                    x: start.x + (end.x - start.x) * t,
                    y: start.y + (end.y - start.y) * t
                )
                if contains(sample, tolerance: tolerance) { return true }
            }
        }
        return contains(first, tolerance: tolerance)
    }

    /// 文字的未旋转包围盒与控制点几何。非文字形状为 nil。
    public var textGeometry: TextGeometry? {
        guard case .text(let string, let origin, let fontSize, let rotation) = self else { return nil }
        return TextGeometry(
            rect: TextMetrics.boundingRect(string, fontSize: fontSize, origin: origin),
            rotation: rotation
        )
    }

    /// 点到线段的距离。零长线段退化为点到点距离。
    private static func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }
}

public struct Style: Equatable, Codable {
    public var color: RGBAColor
    public var pen: PenSize
    public var lineStyle: LineStyle
    /// 文字背景填充，nil 不铺底。与文字色并列的独立属性，只有文字形状消费它。
    public var background: RGBAColor?

    public init(
        color: RGBAColor,
        pen: PenSize,
        lineStyle: LineStyle = .solid,
        background: RGBAColor? = nil
    ) {
        self.color = color
        self.pen = pen
        self.lineStyle = lineStyle
        self.background = background
    }

    private enum CodingKeys: String, CodingKey {
        case color, pen, lineStyle, background
    }

    /// 旧数据没有 lineStyle / background 字段，缺省按实线、无背景解码，保持既有标注外观。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        color = try container.decode(RGBAColor.self, forKey: .color)
        pen = try container.decode(PenSize.self, forKey: .pen)
        lineStyle = try container.decodeIfPresent(LineStyle.self, forKey: .lineStyle) ?? .solid
        background = try container.decodeIfPresent(RGBAColor.self, forKey: .background)
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
