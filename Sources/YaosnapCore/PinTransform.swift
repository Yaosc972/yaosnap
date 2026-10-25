import CoreGraphics

/// 贴图窗口的全部可变状态：缩放、旋转、翻转、透明度、缩略图、图像效果与裁剪。
/// 窗口尺寸与绘制尺寸都只从这里推导，两处各算一套会走样。
public struct PinTransform: Equatable {
    public private(set) var scale: CGFloat
    public private(set) var quarterTurns: Int
    public private(set) var flipHorizontal: Bool
    public private(set) var flipVertical: Bool
    public private(set) var opacity: CGFloat
    public private(set) var isThumbnail: Bool
    public private(set) var isGrayscale: Bool
    public private(set) var isInverted: Bool
    /// 原图像素坐标（左上原点）内的保留区域，nil 表示未裁剪。原图本身永远不动。
    public private(set) var cropRect: CGRect?

    public static let identity = PinTransform()
    public static let thumbnailLongSide: CGFloat = 96

    private static let scaleRange: ClosedRange<CGFloat> = 0.1...8
    private static let opacityRange: ClosedRange<CGFloat> = 0.1...1

    public init(
        scale: CGFloat = 1,
        quarterTurns: Int = 0,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false,
        opacity: CGFloat = 1,
        isThumbnail: Bool = false,
        isGrayscale: Bool = false,
        isInverted: Bool = false,
        cropRect: CGRect? = nil
    ) {
        self.scale = Self.clamp(scale, to: Self.scaleRange)
        self.quarterTurns = Self.normalizedTurns(quarterTurns)
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.opacity = Self.clamp(opacity, to: Self.opacityRange)
        self.isThumbnail = isThumbnail
        self.isGrayscale = isGrayscale
        self.isInverted = isInverted
        self.cropRect = cropRect
    }

    public var rotationDegrees: Int { quarterTurns * 90 }

    public mutating func rotate(byQuarterTurns turns: Int) {
        quarterTurns = Self.normalizedTurns(quarterTurns + turns)
    }

    public mutating func toggleFlipHorizontal() { flipHorizontal.toggle() }
    public mutating func toggleFlipVertical() { flipVertical.toggle() }

    public mutating func setScale(_ value: CGFloat) {
        scale = Self.clamp(value, to: Self.scaleRange)
    }

    public mutating func adjustScale(by delta: CGFloat) {
        setScale(scale + delta)
    }

    public mutating func setOpacity(_ value: CGFloat) {
        opacity = Self.clamp(value, to: Self.opacityRange)
    }

    public mutating func adjustOpacity(by delta: CGFloat) {
        setOpacity(opacity + delta)
    }

    public mutating func toggleThumbnail() { isThumbnail.toggle() }

    public mutating func toggleGrayscale() { isGrayscale.toggle() }
    public mutating func toggleInverted() { isInverted.toggle() }

    public mutating func setCrop(_ rect: CGRect?) { cropRect = rect }

    public mutating func reset() { self = .identity }

    /// 裁剪后贴图按原图比例缩小。原图尺寸拿来算比例，窗口基准尺寸随之收缩。
    public func displayedSize(original: CGSize, imagePixelSize: CGSize) -> CGSize {
        guard let cropRect,
              imagePixelSize.width > 0, imagePixelSize.height > 0 else { return original }
        let size = CGSize(
            width: original.width * cropRect.width / imagePixelSize.width,
            height: original.height * cropRect.height / imagePixelSize.height
        )
        return CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
    }

    /// 旋转前的图像尺寸。缩略图按长边缩到 96，但绝不放大。
    public func unrotatedSize(base: CGSize) -> CGSize {
        let raw: CGSize
        if isThumbnail {
            let longest = max(base.width, base.height)
            let factor = longest > Self.thumbnailLongSide ? Self.thumbnailLongSide / longest : 1
            raw = CGSize(width: base.width * factor, height: base.height * factor)
        } else {
            raw = CGSize(width: base.width * scale, height: base.height * scale)
        }
        return CGSize(
            width: max(1, raw.width.rounded()),
            height: max(1, raw.height.rounded())
        )
    }

    /// 窗口尺寸。四分之一圈为奇数时宽高互换，窗口才能包住旋转后的图。
    public func windowSize(base: CGSize) -> CGSize {
        let size = unrotatedSize(base: base)
        return quarterTurns % 2 == 1
            ? CGSize(width: size.height, height: size.width)
            : size
    }

    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func normalizedTurns(_ turns: Int) -> Int {
        ((turns % 4) + 4) % 4
    }
}
