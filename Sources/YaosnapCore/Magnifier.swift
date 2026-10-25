import CoreGraphics

/// 放大镜取到的一枚屏幕像素。
public struct PixelColor: Equatable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// 统一大写两位十六进制，例如 `#FF8800`。
    public var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    public var rgbString: String {
        "rgb(\(red), \(green), \(blue))"
    }
}

/// 取色复制格式。Shift 在两种格式间切换。
public enum ColorFormat: Equatable {
    case hex
    case rgb

    public func string(for color: PixelColor) -> String {
        switch self {
        case .hex: return color.hexString
        case .rgb: return color.rgbString
        }
    }

    public var toggled: ColorFormat {
        self == .hex ? .rgb : .hex
    }
}

/// 放大镜的尺寸与落点。坐标约定与 OverlayView 一致：左下原点、y 向上、单位点。
public enum MagnifierGeometry {
    public static let side: CGFloat = 120
    public static let borderWidth: CGFloat = 2
    public static let cornerRadius: CGFloat = 10
    /// 放大镜与光标的间距，避免贴着脸挡住光标下的像素。
    public static let cursorInset: CGFloat = 12
    /// 一个源像素放大成几个输出像素；点在点坐标下恰好也是点对点的放大倍数。
    public static let zoom: Int = 5

    /// 光标右下侧；右侧或下侧放不下时翻到另一侧，最后再钳进屏幕。
    public static func frame(cursor: CGPoint, in bounds: CGRect) -> CGRect {
        var origin = CGPoint(
            x: cursor.x + cursorInset,
            y: cursor.y - cursorInset - side
        )
        if origin.x + side > bounds.maxX {
            origin.x = cursor.x - cursorInset - side
        }
        if origin.y < bounds.minY {
            origin.y = cursor.y + cursorInset
        }
        origin.x = min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - side))
        origin.y = min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - side))
        return CGRect(origin: origin, size: CGSize(width: side, height: side))
    }

    public static func interiorRect(in frame: CGRect) -> CGRect {
        frame.insetBy(dx: borderWidth, dy: borderWidth)
    }

    /// 采样边长取奇数，让光标像素落在正中。
    public static func samplePixelCount(scale: CGFloat) -> Int {
        let points = side - borderWidth * 2
        let raw = Int((points * max(scale, 1) / CGFloat(zoom)).rounded())
        return max(3, raw % 2 == 0 ? raw + 1 : raw)
    }
}

/// 从冻结帧按画布点取色并生成放大图。
/// 画布点（左下原点、y 向上、单位点）到帧像素（左上原点）的翻转只在像素换算里做一次。
public struct MagnifierSampler {
    public struct Magnified {
        public let image: CGImage
        public let zoom: Int
        /// 光标像素中心在放大图里的位置，单位输出像素、左上原点。
        public let crosshair: CGPoint

        public var outputSide: Int { image.width }
    }

    private let image: CGImage
    private let canvasSize: CGSize
    private let scaleX: CGFloat
    private let scaleY: CGFloat
    /// 图像在画布里的左下原点。默认铺满画布；历史回放按等比缩放居中时传入实际显示矩形原点。
    private let imageOrigin: CGPoint

    public init(image: CGImage, canvasSize: CGSize, scale: CGFloat) {
        self.init(image: image, canvasSize: canvasSize, scaleX: scale, scaleY: scale)
    }

    /// 宽高缩放不一致时使用，例如历史截图按等比缩放后显示。
    public init(
        image: CGImage,
        canvasSize: CGSize,
        scaleX: CGFloat,
        scaleY: CGFloat,
        origin: CGPoint = .zero
    ) {
        self.image = image
        self.canvasSize = canvasSize
        self.scaleX = scaleX > 0 ? scaleX : 1
        self.scaleY = scaleY > 0 ? scaleY : 1
        self.imageOrigin = origin
    }

    /// 画布点 → 帧像素下标。落在图像外时钳到最近的边缘像素。
    public func pixelIndex(at canvasPoint: CGPoint) -> (x: Int, y: Int)? {
        guard image.width > 0, image.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let displayedHeight = CGFloat(image.height) / scaleY
        let px = Int(((canvasPoint.x - imageOrigin.x) * scaleX).rounded(.down))
        let py = Int(((imageOrigin.y + displayedHeight - canvasPoint.y) * scaleY).rounded(.down))
        return (
            min(max(px, 0), image.width - 1),
            min(max(py, 0), image.height - 1)
        )
    }

    public func color(at canvasPoint: CGPoint) -> PixelColor? {
        guard let index = pixelIndex(at: canvasPoint) else { return nil }
        return colorAt(x: index.x, y: index.y)
    }

    /// 以光标像素为中心裁一块 sourcePixels 见方，最近邻放大到 sourcePixels * zoom。
    /// 屏幕边缘钳制裁剪原点而不是缩小采样范围，放大倍数保持固定。
    public func magnified(at canvasPoint: CGPoint, sourcePixels: Int, zoom: Int) -> Magnified? {
        guard sourcePixels > 0, zoom > 0, let index = pixelIndex(at: canvasPoint) else { return nil }
        let side = min(sourcePixels, image.width, image.height)
        guard side > 0 else { return nil }
        let cropX = min(max(index.x - side / 2, 0), image.width - side)
        let cropY = min(max(index.y - side / 2, 0), image.height - side)
        guard let crop = ImageOutput.crop(
            image,
            to: CGRect(x: cropX, y: cropY, width: side, height: side)
        ) else { return nil }

        let outputSide = side * zoom
        guard let ctx = CGContext(
            data: nil,
            width: outputSide,
            height: outputSide,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        AnnotationRenderer.drawUpright(
            crop,
            in: CGRect(x: 0, y: 0, width: outputSide, height: outputSide),
            ctx: ctx
        )
        guard let output = ctx.makeImage() else { return nil }
        return Magnified(
            image: output,
            zoom: zoom,
            crosshair: CGPoint(
                x: (CGFloat(index.x - cropX) + 0.5) * CGFloat(zoom),
                y: (CGFloat(index.y - cropY) + 0.5) * CGFloat(zoom)
            )
        )
    }

    /// 单像素读取：把目标像素平移到 1x1 上下文的原点。比逐像素遍历整帧便宜。
    private func colorAt(x: Int, y: Int) -> PixelColor? {
        guard let ctx = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        // 上下文 y 向上，帧顶行画在 rect.maxY；目标行 y 在上下文中对应 image.height - 1 - y。
        ctx.draw(image, in: CGRect(
            x: -CGFloat(x),
            y: -CGFloat(image.height - 1 - y),
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        ))
        guard let data = ctx.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return PixelColor(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes[3])
    }
}
