import CoreGraphics

/// 颜色的纯数据形式。Core 不依赖 AppKit，窗口再把这里的值转成 CGColor 绘制。
public struct PinRGBA: Equatable {
    public let red: CGFloat
    public let green: CGFloat
    public let blue: CGFloat
    public let alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// 贴图窗口的背景模式。每张贴图各自持有一份，默认透明。
public enum PinBackground: String, CaseIterable, Equatable {
    case transparent
    case pseudoTransparent
    case darkCheckerboard
    case lightCheckerboard

    public static let checkerCellSize: CGFloat = 8

    public var title: String {
        switch self {
        case .transparent: return "透明"
        case .pseudoTransparent: return "伪透明"
        case .darkCheckerboard: return "暗色棋盘"
        case .lightCheckerboard: return "亮色棋盘"
        }
    }

    /// 铺满窗口的底色；透明模式没有背景。
    public var fill: PinRGBA? {
        switch self {
        case .transparent: return nil
        case .pseudoTransparent: return PinRGBA(red: 1, green: 1, blue: 1, alpha: 0.72)
        case .darkCheckerboard: return PinRGBA(red: 0.16, green: 0.16, blue: 0.16, alpha: 1)
        case .lightCheckerboard: return PinRGBA(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        }
    }

    /// 棋盘格在底色的交错格上再画的第二色；非棋盘模式为 nil。
    public var checkerAlternate: PinRGBA? {
        switch self {
        case .darkCheckerboard: return PinRGBA(red: 0.26, green: 0.26, blue: 0.26, alpha: 1)
        case .lightCheckerboard: return PinRGBA(red: 0.84, green: 0.84, blue: 0.84, alpha: 1)
        case .transparent, .pseudoTransparent: return nil
        }
    }

    public func next() -> PinBackground {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self) else { return .transparent }
        return all[(index + 1) % all.count]
    }
}
