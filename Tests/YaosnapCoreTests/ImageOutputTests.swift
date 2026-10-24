import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import YaosnapCore

struct ImageOutputTests {
    private func makeImage(width: Int = 100, height: Int = 50) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    @Test func cropProducesRequestedSize() {
        let cropped = ImageOutput.crop(makeImage(), to: CGRect(x: 10, y: 10, width: 30, height: 20))
        #expect(cropped?.width == 30)
        #expect(cropped?.height == 20)
    }

    @Test func cropOutOfBoundsReturnsNil() {
        #expect(ImageOutput.crop(makeImage(), to: CGRect(x: 200, y: 200, width: 10, height: 10)) == nil)
    }

    // 部分越界钳制到图像内；只有完全不相交或无效尺寸才返回 nil
    @Test func cropPartiallyOutOfBoundsClamps() {
        let cropped = ImageOutput.crop(makeImage(), to: CGRect(x: 90, y: 40, width: 30, height: 20))
        #expect(cropped?.width == 10)
        #expect(cropped?.height == 10)
    }

    @Test func cropZeroSizeReturnsNil() {
        #expect(ImageOutput.crop(makeImage(), to: .zero) == nil)
    }

    @Test func pngDataIsDecodablePNG() throws {
        let data = try #require(ImageOutput.pngData(from: makeImage()))
        #expect(Array(data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 100)
        #expect(decoded.height == 50)
    }

    @Test func defaultFileNameFormat() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var comps = DateComponents()
        comps.year = 2026; comps.month = 10; comps.day = 24
        comps.hour = 22; comps.minute = 30; comps.second = 15
        let date = calendar.date(from: comps)!

        #expect(ImageOutput.defaultFileName(now: date) == "Yaosnap_2026-10-24_22-30-15.png")
    }
}
