import CoreGraphics
import Foundation

/// 位图像素断言的共享工具。
enum PixelBuffer {
    /// 把图像画进 sRGB RGBA8 缓冲区（顶部行在前），统一色彩空间后逐字节比较。
    static func srgbBytes(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = context.data else { return nil }
        return Array(UnsafeBufferPointer(
            start: base.assumingMemoryBound(to: UInt8.self),
            count: width * height * 4
        ))
    }

    /// 顶部行在前缓冲里的像素 (x, y)（y 从顶部数）。
    static func pixel(
        _ bytes: [UInt8],
        x: Int,
        y: Int,
        width: Int
    ) -> (r: Int, g: Int, b: Int) {
        let offset = (y * width + x) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// 纯色位图。先铺白底，rects 按顺序绘制，坐标是左下原点上下文坐标。
    static func solidImage(
        width: Int,
        height: Int,
        colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB(),
        rects: [(rect: CGRect, color: CGColor)]
    ) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for entry in rects {
            ctx.setFillColor(entry.color)
            ctx.fill(entry.rect)
        }
        return ctx.makeImage()!
    }
}
