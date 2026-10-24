import CoreGraphics

/// 一次成功输出的截图，仅供本次进程内的历史回放。
/// displaySize 是当时选区的逻辑尺寸，用它从像素尺寸反推缩放比。
public struct CaptureHistoryEntry {
    public let image: CGImage
    public let displaySize: CGSize

    public init(image: CGImage, displaySize: CGSize) {
        self.image = image
        self.displaySize = displaySize
    }

    public var scaleX: CGFloat {
        displaySize.width > 0 ? CGFloat(image.width) / displaySize.width : 1
    }

    public var scaleY: CGFloat {
        displaySize.height > 0 ? CGFloat(image.height) / displaySize.height : 1
    }
}
