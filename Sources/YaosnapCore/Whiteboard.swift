import CoreGraphics
import Foundation

/// 白板颜色输入的统一入口：命令行、URL、设置里的十六进制框都走这里。
/// 非法值回落到白色而不是报错，与 Snipaste 的宽松行为一致。
public enum WhiteboardColor {
    public static let named: [String: RGBAColor] = [
        "black": .black,
        "white": .white,
        "red": .red,
        "green": .green,
        "blue": .blue,
        "yellow": .yellow,
        "gray": .gray,
        "grey": .gray,
        "orange": .orange,
        "purple": .purple,
        "cyan": .cyan,
    ]

    public static func parse(_ raw: String) -> RGBAColor? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let named = named[trimmed] { return named }
        guard trimmed.count == 7, trimmed.hasPrefix("#") else { return nil }
        let digits = trimmed.dropFirst()
        guard digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else {
            return nil
        }
        return RGBAColor(
            r: Double((value >> 16) & 0xFF) / 255,
            g: Double((value >> 8) & 0xFF) / 255,
            b: Double(value & 0xFF) / 255
        )
    }

    public static func parseOrDefault(_ raw: String) -> RGBAColor {
        parse(raw) ?? .white
    }
}

/// 一次白板会话的解析结果。activeScreenOnly 只影响开哪几屏，颜色独立于全局设置。
public struct WhiteboardSession: Equatable {
    public var color: RGBAColor
    public var activeScreenOnly: Bool

    public init(color: RGBAColor = .white, activeScreenOnly: Bool = false) {
        self.color = color
        self.activeScreenOnly = activeScreenOnly
    }
}

/// 白板模式下 Esc 的语义：不退出会话，只清标注选中；其余状态什么都不做。
public enum WhiteboardEscapeAction: Equatable, Sendable {
    case exitSession
    case dismissAnnotations
    case ignore
}

public enum WhiteboardInteraction {
    public static func escapeAction(
        isWhiteboardMode: Bool,
        hasSelectedAnnotations: Bool
    ) -> WhiteboardEscapeAction {
        if hasSelectedAnnotations { return .dismissAnnotations }
        return isWhiteboardMode ? .ignore : .exitSession
    }
}

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
    public static let red = RGBAColor(r: 1, g: 0, b: 0)
    public static let green = RGBAColor(r: 0, g: 1, b: 0)
    public static let blue = RGBAColor(r: 0, g: 0, b: 1)
    public static let yellow = RGBAColor(r: 1, g: 1, b: 0)
    public static let gray = RGBAColor(r: 128.0 / 255, g: 128.0 / 255, b: 128.0 / 255)
    public static let orange = RGBAColor(r: 1, g: 165.0 / 255, b: 0)
    public static let purple = RGBAColor(r: 128.0 / 255, g: 0, b: 128.0 / 255)
    public static let cyan = RGBAColor(r: 0, g: 1, b: 1)

    /// 命令行与 URL 只需要 RGB，alpha 不参与序列化。
    public var hexString: String {
        let clamped = self.clamped()
        let red = Int((clamped.r * 255).rounded())
        let green = Int((clamped.g * 255).rounded())
        let blue = Int((clamped.b * 255).rounded())
        return String(format: "#%02x%02x%02x", red, green, blue)
    }

    public func clamped() -> RGBAColor {
        RGBAColor(
            r: min(max(r, 0), 1),
            g: min(max(g, 0), 1),
            b: min(max(b, 0), 1),
            a: min(max(a, 0), 1)
        )
    }
}
