import CoreGraphics

/// 选区宽高比。持久化用 rawValue，界面显示用 title，拖拽数学用 value。
public enum SelectionAspectRatio: String, CaseIterable, Codable {
    case free
    case square
    case fourThree
    case sixteenNine
    case sixteenTen
    case threeTwo

    public var title: String {
        switch self {
        case .free: return "自由"
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .sixteenNine: return "16:9"
        case .sixteenTen: return "16:10"
        case .threeTwo: return "3:2"
        }
    }

    /// 宽 / 高。自由比例返回 nil，调用方据此走不受约束的拖拽路径。
    public var value: CGFloat? {
        switch self {
        case .free: return nil
        case .square: return 1
        case .fourThree: return 4.0 / 3.0
        case .sixteenNine: return 16.0 / 9.0
        case .sixteenTen: return 16.0 / 10.0
        case .threeTwo: return 3.0 / 2.0
        }
    }
}
