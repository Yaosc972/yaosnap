import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 截图输出纯逻辑：裁剪与 PNG 编码，不依赖 AppKit 状态。
public enum ImageOutput {
    /// 按图像像素坐标（左上原点）裁剪。越界部分钳制到图像内；
    /// 完全不相交或无效尺寸返回 nil。
    public static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let integral = rect.integral.intersection(
            CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        guard !integral.isNull, integral.width >= 1, integral.height >= 1 else { return nil }
        return image.cropping(to: integral)
    }

    public static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// 形如 `Yaosnap_2026-10-24_22-30-15.png`，固定公历与 24 小时制，不受系统语言影响。
    public static func defaultFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "Yaosnap_\(formatter.string(from: now)).png"
    }
}
