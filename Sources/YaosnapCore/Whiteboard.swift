import CoreGraphics
import Foundation

public struct WhiteboardSettings: Equatable, Codable {
    public static let standard = WhiteboardSettings()

    public var enabled: Bool
    public var color: RGBAColor

    public init(enabled: Bool = false, color: RGBAColor = .white) {
        self.enabled = enabled
        self.color = color
    }
}

public enum WhiteboardImage {
    /// 生成与冻结帧同像素尺寸的纯色图。尺寸一致，选区裁剪与缩放计算可以原样复用。
    public static func make(width: Int, height: Int, color: RGBAColor) -> CGImage? {
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        let color = color.clamped()
        context.setFillColor(red: color.r, green: color.g, blue: color.b, alpha: color.a)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

extension RGBAColor {
    public static let white = RGBAColor(r: 1, g: 1, b: 1)
    public static let black = RGBAColor(r: 0, g: 0, b: 0)

    public func clamped() -> RGBAColor {
        RGBAColor(
            r: min(max(r, 0), 1),
            g: min(max(g, 0), 1),
            b: min(max(b, 0), 1),
            a: min(max(a, 0), 1)
        )
    }
}
