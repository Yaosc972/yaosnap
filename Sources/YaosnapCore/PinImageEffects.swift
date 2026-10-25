import CoreGraphics
import CoreImage

/// 贴图的像素效果与裁剪换算。显示、导出都从这里取同一张成品图。
public enum PinImageEffects {
    public static func render(
        _ image: CGImage,
        crop: CGRect?,
        grayscale: Bool,
        inverted: Bool
    ) -> CGImage {
        let base = crop.flatMap { croppedImage(image, to: $0) } ?? image
        guard grayscale || inverted else { return base }
        return filtered(base, grayscale: grayscale, inverted: inverted) ?? base
    }

    public static func croppedImage(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = rect.integral.intersection(bounds)
        guard clipped.width >= 1, clipped.height >= 1 else { return nil }
        return image.cropping(to: clipped)
    }

    public static func filtered(
        _ image: CGImage,
        grayscale: Bool,
        inverted: Bool
    ) -> CGImage? {
        var output = CIImage(cgImage: image)
        if grayscale {
            output = output.applyingFilter(
                "CIColorControls",
                parameters: [kCIInputSaturationKey: 0]
            )
        }
        if inverted {
            output = output.applyingFilter("CIColorInvert")
        }
        // 不做色彩管理，反色才能保持 255 - 原值；否则线性工作空间会带来舍入偏差。
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        return context.createCGImage(
            output,
            from: output.extent,
            format: .RGBA8,
            colorSpace: image.colorSpace
        )
    }
}

/// 视图坐标到原图像素坐标的换算，以及裁剪框的最小尺寸钳制。
public enum PinCrop {
    public static let minimumSide: CGFloat = 8

    /// 拖出的矩形先标准化、裁进视图，再保证两边不小于 minimumSide。
    public static func clampedSelection(_ raw: CGRect, in bounds: CGRect) -> CGRect? {
        let clipped = raw.standardized.intersection(bounds)
        guard clipped.width > 0, clipped.height > 0 else { return nil }
        var rect = CGRect(
            x: clipped.minX,
            y: clipped.minY,
            width: max(clipped.width, min(minimumSide, bounds.width)),
            height: max(clipped.height, min(minimumSide, bounds.height))
        )
        if rect.maxX > bounds.maxX { rect.origin.x = bounds.maxX - rect.width }
        if rect.maxY > bounds.maxY { rect.origin.y = bounds.maxY - rect.height }
        rect.origin.x = max(bounds.minX, rect.origin.x)
        rect.origin.y = max(bounds.minY, rect.origin.y)
        return rect
    }

    /// 视图坐标（左下原点）映射到原图（左上原点像素）。旋转与翻转都按绘制时的逆变换还原。
    public static func pixelRect(
        fromViewRect rect: CGRect,
        viewSize: CGSize,
        imagePixelSize: CGSize,
        transform: PinTransform,
        basePointSize: CGSize
    ) -> CGRect? {
        guard viewSize.width > 0, viewSize.height > 0,
              imagePixelSize.width >= 1, imagePixelSize.height >= 1 else { return nil }
        // 第二次裁剪时视图只显示已裁剪区域，换算必须以当前显示尺寸为准。
        let displayedBase = transform.displayedSize(
            original: basePointSize,
            imagePixelSize: imagePixelSize
        )
        let unrotated = transform.unrotatedSize(base: displayedBase)
        guard unrotated.width > 0, unrotated.height > 0 else { return nil }
        let cropOrigin = transform.cropRect?.origin ?? .zero
        let cropSize = transform.cropRect?.size ?? imagePixelSize

        func imagePoint(_ point: CGPoint) -> CGPoint {
            var x = point.x - viewSize.width / 2
            var y = point.y - viewSize.height / 2
            if transform.flipHorizontal { x = -x }
            if transform.flipVertical { y = -y }
            switch transform.quarterTurns {
            case 1: (x, y) = (-y, x)
            case 2: (x, y) = (-x, -y)
            case 3: (x, y) = (y, -x)
            default: break
            }
            let u = (x + unrotated.width / 2) / unrotated.width
            let v = (y + unrotated.height / 2) / unrotated.height
            return CGPoint(
                x: cropOrigin.x + u * cropSize.width,
                y: cropOrigin.y + (1 - v) * cropSize.height
            )
        }

        let a = imagePoint(CGPoint(x: rect.minX, y: rect.minY))
        let b = imagePoint(CGPoint(x: rect.maxX, y: rect.maxY))
        let raw = CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
        let clipped = raw.integral.intersection(
            CGRect(origin: cropOrigin, size: cropSize)
        )
        guard clipped.width >= 1, clipped.height >= 1 else { return nil }
        return clipped
    }
}
