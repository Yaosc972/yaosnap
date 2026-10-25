import CoreGraphics

/// 导出图加柔和投影：四周留透明边距，图像居中，阴影画在图像下层。
public enum ImageShadow {
    public static let defaultMargin: CGFloat = 24
    public static let defaultBlur: CGFloat = 12

    /// 输出为 RGBA、沿用底图色彩空间，尺寸为原图加四周 margin。
    /// margin / blur 非法或结果尺寸无效时返回 nil。
    public static func apply(
        to image: CGImage,
        margin: CGFloat = defaultMargin,
        blur: CGFloat = defaultBlur
    ) -> CGImage? {
        guard margin.isFinite, blur.isFinite, margin >= 0, blur >= 0,
              margin <= CGFloat(Int.max) / 4 else { return nil }
        let marginPx = Int(margin.rounded())
        let width = image.width + marginPx * 2
        let height = image.height + marginPx * 2
        guard width > 0, height > 0 else { return nil }

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))

        ctx.setShadow(
            offset: .zero,
            blur: blur,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35)
        )
        ctx.draw(image, in: CGRect(
            x: marginPx,
            y: marginPx,
            width: image.width,
            height: image.height
        ))
        return ctx.makeImage()
    }
}
