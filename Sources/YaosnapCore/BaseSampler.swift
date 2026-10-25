import CoreGraphics
import CoreImage

/// 从冻结帧采样底图像素，供马赛克与模糊使用。
/// region 一律传画布点坐标；帧内像素换算集中在这里，避免调用方各自换算出错。
public struct BaseSampler {
    private static let ciContext = CIContext()
    private let base: CGImage
    private let cropOriginPx: CGPoint
    private let canvasSize: CGSize
    private let scale: CGFloat

    public init(base: CGImage, cropOriginPx: CGPoint, canvasSize: CGSize, scale: CGFloat) {
        self.base = base
        self.cropOriginPx = cropOriginPx
        self.canvasSize = canvasSize
        self.scale = scale > 0 ? scale : 1
    }

    /// 把 region 对应的底图区域按 blockPoints * scale 像素为一块做像素化。
    /// 输出尺寸与 region 的像素尺寸一致（越界部分先钳制）；region 落在帧外或块尺寸非法时返回 nil。
    public func pixelated(region: CGRect, blockPoints: CGFloat) -> CGImage? {
        guard blockPoints > 0, !region.isEmpty else { return nil }
        guard let (cropped, pixelRect) = croppedPixels(region: region) else { return nil }

        let blockPx = max(1, (blockPoints * scale).rounded())
        let cols = max(1, Int(ceil(pixelRect.width / blockPx)))
        let rows = max(1, Int(ceil(pixelRect.height / blockPx)))

        // 缩小用 .medium 做区域平均：块颜色是块内底图的均值，点采样只取单像素、
        // 块色会随机偏向某一像素；放大用 .none 最近邻，保持块边界锐利不引入中间色。
        guard let small = makeContext(width: cols, height: rows),
              let large = makeContext(width: Int(pixelRect.width), height: Int(pixelRect.height))
        else { return nil }
        small.interpolationQuality = .medium
        AnnotationRenderer.drawUpright(
            cropped,
            in: CGRect(x: 0, y: 0, width: cols, height: rows),
            ctx: small
        )
        guard let smallImage = small.makeImage() else { return nil }
        large.interpolationQuality = .none
        AnnotationRenderer.drawUpright(
            smallImage,
            in: CGRect(x: 0, y: 0, width: large.width, height: large.height),
            ctx: large
        )
        return large.makeImage()
    }

    /// 对 region 对应的底图区域做高斯模糊，输出尺寸与 region 的像素尺寸一致。
    /// 采样源是原始冻结帧，模糊不会把已画标注带进结果。
    public func blurred(region: CGRect, radiusPoints: CGFloat) -> CGImage? {
        guard radiusPoints > 0, !region.isEmpty else { return nil }
        guard let (cropped, _) = croppedPixels(region: region) else { return nil }
        let source = CIImage(cgImage: cropped)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        // 先钳制边缘再模糊，否则区域边界会采到透明像素而发黑。
        filter.setValue(source.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radiusPoints * scale, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        return Self.ciContext.createCGImage(
            output,
            from: source.extent,
            format: .RGBA8,
            colorSpace: base.colorSpace
        )
    }

    /// region 对应的原始底图像素图。放大镜拿它按倍率重新铺满镜框。
    public func cropped(region: CGRect) -> CGImage? {
        croppedPixels(region: region)?.image
    }

    /// 画布点 region → 帧内像素矩形，并把裁剪结果取出来。
    private func croppedPixels(region: CGRect) -> (image: CGImage, pixelRect: CGRect)? {
        // 画布点（y 向上）→ 帧像素（y 向下）：顶部像素 = cropOrigin.y + (canvasHeight - region.maxY) * scale
        let pixelRect = CGRect(
            x: cropOriginPx.x + region.minX * scale,
            y: cropOriginPx.y + (canvasSize.height - region.maxY) * scale,
            width: region.width * scale,
            height: region.height * scale
        )
        .integral
        .intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        guard let cropped = ImageOutput.crop(base, to: pixelRect) else { return nil }
        return (cropped, pixelRect)
    }

    private func makeContext(width: Int, height: Int) -> CGContext? {
        let colorSpace = base.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}
