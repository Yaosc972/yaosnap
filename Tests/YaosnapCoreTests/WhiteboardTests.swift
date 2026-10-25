import CoreGraphics
import Testing
@testable import YaosnapCore

struct WhiteboardTests {
    private func rgbaBytes(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = context.data else { return nil }
        return Array(UnsafeBufferPointer(
            start: base.assumingMemoryBound(to: UInt8.self),
            count: width * height * 4
        ))
    }

    private func pixel(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> [UInt8] {
        let offset = (y * width + x) * 4
        return Array(bytes[offset..<(offset + 4)])
    }

    @Test func imageKeepsRequestedPixelSize() throws {
        let image = try #require(WhiteboardImage.make(width: 160, height: 90, background: .solid(.white)))
        #expect(image.width == 160)
        #expect(image.height == 90)
    }

    @Test func everyPixelUsesTheRequestedColor() throws {
        let color = RGBAColor(r: 0.2, g: 0.4, b: 0.6, a: 1)
        let image = try #require(WhiteboardImage.make(width: 32, height: 24, background: .solid(color)))
        let bytes = try #require(rgbaBytes(image))
        for (x, y) in [(0, 0), (31, 0), (0, 23), (15, 12), (31, 23)] {
            let actual = pixel(bytes, width: image.width, x: x, y: y)
            #expect(abs(Int(actual[0]) - 51) <= 1)
            #expect(abs(Int(actual[1]) - 102) <= 1)
            #expect(abs(Int(actual[2]) - 153) <= 1)
            #expect(actual[3] == 255)
        }
    }

    @Test func defaultWhiteboardColorIsWhite() throws {
        let image = try #require(WhiteboardImage.make(
            width: 8,
            height: 8,
            background: WhiteboardSettings.standard.background
        ))
        let bytes = try #require(rgbaBytes(image))
        #expect(pixel(bytes, width: image.width, x: 4, y: 4) == [255, 255, 255, 255])
    }

    @Test func transparentColorKeepsAlphaZero() throws {
        let transparent = RGBAColor(r: 1, g: 0, b: 0, a: 0)
        let image = try #require(WhiteboardImage.make(width: 4, height: 4, background: .solid(transparent)))
        let bytes = try #require(rgbaBytes(image))
        #expect(pixel(bytes, width: image.width, x: 2, y: 2)[3] == 0)
    }

    @Test func parsesNamedColorsCaseInsensitively() {
        #expect(WhiteboardColor.parse("black") == .black)
        #expect(WhiteboardColor.parse("White") == .white)
        #expect(WhiteboardColor.parse(" red ") == .red)
        #expect(WhiteboardColor.parse("green") == .green)
        #expect(WhiteboardColor.parse("blue") == .blue)
        #expect(WhiteboardColor.parse("yellow") == .yellow)
        #expect(WhiteboardColor.parse("gray") == .gray)
        #expect(WhiteboardColor.parse("grey") == .gray)
    }

    @Test func parsesHexColor() throws {
        let color = try #require(WhiteboardColor.parse("#112233"))
        #expect(abs(color.r - 17.0 / 255) < 1e-9)
        #expect(abs(color.g - 34.0 / 255) < 1e-9)
        #expect(abs(color.b - 51.0 / 255) < 1e-9)
        #expect(color.a == 1)
    }

    @Test func invalidColorFallsBackToWhite() {
        for raw in ["", "mauve", "#123", "#GGGGGG", "001122", "#1122334"] {
            #expect(WhiteboardColor.parse(raw) == nil)
            #expect(WhiteboardBackground.parseOrDefault(raw) == .solid(.white))
        }
    }

    @Test func hexStringRoundTripsParsedColor() throws {
        let color = try #require(WhiteboardColor.parse("#0a1B2c"))
        #expect(color.hexString == "#0a1b2c")
        #expect(WhiteboardColor.parse(color.hexString) == color)
    }

    @Test func whiteboardEscapeNeverExitsSession() {
        #expect(WhiteboardInteraction.escapeAction(
            isWhiteboardMode: true, hasSelectedAnnotations: false
        ) == .ignore)
        #expect(WhiteboardInteraction.escapeAction(
            isWhiteboardMode: true, hasSelectedAnnotations: true
        ) == .dismissAnnotations)
    }

    @Test func normalEscapeStillExitsSession() {
        #expect(WhiteboardInteraction.escapeAction(
            isWhiteboardMode: false, hasSelectedAnnotations: false
        ) == .exitSession)
        #expect(WhiteboardInteraction.escapeAction(
            isWhiteboardMode: false, hasSelectedAnnotations: true
        ) == .dismissAnnotations)
    }
}
