import CoreGraphics
import Foundation

/// 一次成功输出的截图，仅供本次进程内的历史回放。
/// displaySize 是当时选区的逻辑尺寸，用它从像素尺寸反推缩放比。
public struct CaptureHistoryEntry {
    public let image: CGImage
    public let displaySize: CGSize
    public let createdAt: Date
    /// 选区在源屏上的位置，重复上次区域时使用。
    public let region: CaptureRegion?
    /// 当时的整屏冻结帧，回放时铺满屏幕；来源不是整屏时为 nil。
    public let fullFrame: CGImage?
    /// 这张截图上画过的标注。回放时按原坐标还原，可以继续编辑；
    /// 不存的话回放只能看到未标注的整屏帧，与 Snipaste 的行为不一致。
    public let annotations: [Annotation]

    public init(
        image: CGImage,
        displaySize: CGSize,
        createdAt: Date = Date(),
        region: CaptureRegion? = nil,
        fullFrame: CGImage? = nil,
        annotations: [Annotation] = []
    ) {
        self.image = image
        self.displaySize = displaySize
        self.createdAt = createdAt
        self.region = region
        self.fullFrame = fullFrame
        self.annotations = annotations
    }

    public var scaleX: CGFloat {
        displaySize.width > 0 ? CGFloat(image.width) / displaySize.width : 1
    }

    public var scaleY: CGFloat {
        displaySize.height > 0 ? CGFloat(image.height) / displaySize.height : 1
    }
}

/// 菜单栏「截图历史」的展示投影。历史数组本身按时间倒序，菜单保持同一顺序。
public enum CaptureHistoryMenu {
    public static let limit = 10

    public struct Item: Equatable {
        public let index: Int
        public let title: String

        public init(index: Int, title: String) {
            self.index = index
            self.title = title
        }
    }

    public static func items(from entries: [CaptureHistoryEntry]) -> [Item] {
        entries.prefix(limit).enumerated().map {
            Item(index: $0.offset, title: title(for: $0.element))
        }
    }

    public static func title(for entry: CaptureHistoryEntry) -> String {
        "\(timeFormatter.string(from: entry.createdAt)) · \(entry.image.width)×\(entry.image.height)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
