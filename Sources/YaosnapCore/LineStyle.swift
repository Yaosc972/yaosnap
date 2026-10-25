import CoreGraphics

/// 描边线型。只作用于描边类形状，实线不设 dash，导出与旧版本逐像素一致。
public enum LineStyle: String, Codable, CaseIterable {
    case solid
    case dashed
    case dotted

    /// 工具条按钮的循环顺序。
    public var next: LineStyle {
        switch self {
        case .solid: return .dashed
        case .dashed: return .dotted
        case .dotted: return .solid
        }
    }

    /// 间隔随线宽缩放，粗笔画的虚线与点线不会连成一片。实线返回 nil，渲染时不设 dash。
    /// 圆头会让每段两端各外扩半个线宽，虚线可见间隔因此比字面 gap 窄一个线宽。
    public func dashPattern(lineWidth: CGFloat) -> [CGFloat]? {
        switch self {
        case .solid: return nil
        case .dashed: return [lineWidth, lineWidth * 2]
        case .dotted: return [lineWidth * 0.1, lineWidth * 2.4]
        }
    }
}

extension ShapeKind {
    /// 自由笔画、填充类与文字不走描边路径，改线型对它们没有视觉意义。
    public var supportsLineStyle: Bool {
        switch self {
        case .rect, .roundedRect, .ellipse, .line, .arrow, .polyline: return true
        case .brush, .marker, .mosaic, .blur, .text, .serial, .eraser: return false
        }
    }
}
