import CoreGraphics
import Foundation
import Testing
@testable import YaosnapCore

struct WhiteboardBackgroundTests {
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

    private func alpha(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> UInt8 {
        bytes[(y * width + x) * 4 + 3]
    }

    @Test func parsesTransparentAndClear() {
        #expect(WhiteboardBackground.parse("transparent") == .transparent)
        #expect(WhiteboardBackground.parse("clear") == .transparent)
        #expect(WhiteboardBackground.parse(" Transparent ") == .transparent)
        #expect(WhiteboardBackground.parse("CLEAR") == .transparent)
    }

    @Test func parsesColorsAsSolid() throws {
        #expect(WhiteboardBackground.parse("red") == .solid(.red))
        #expect(WhiteboardBackground.parse("#112233") == .solid(try #require(WhiteboardColor.parse("#112233"))))
        #expect(WhiteboardBackground.parse(" White ") == .solid(.white))
    }

    @Test func invalidBackgroundFallsBackToWhite() {
        for raw in ["", "mauve", "#123", "transparency", "#GGGGGG"] {
            #expect(WhiteboardBackground.parse(raw) == nil)
            #expect(WhiteboardBackground.parseOrDefault(raw) == .solid(.white))
        }
    }

    @Test func transparentImageHasZeroAlphaEverywhere() throws {
        let image = try #require(WhiteboardImage.make(width: 8, height: 6, background: .transparent))
        let bytes = try #require(rgbaBytes(image))
        for (x, y) in [(0, 0), (7, 0), (0, 5), (7, 5), (4, 3)] {
            #expect(alpha(bytes, width: image.width, x: x, y: y) == 0)
        }
    }

    @Test func solidImageHasOpaqueAlphaEverywhere() throws {
        let image = try #require(WhiteboardImage.make(width: 8, height: 6, background: .solid(.red)))
        let bytes = try #require(rgbaBytes(image))
        for (x, y) in [(0, 0), (7, 0), (0, 5), (7, 5), (4, 3)] {
            #expect(alpha(bytes, width: image.width, x: x, y: y) == 255)
        }
    }

    @Test func decodesLegacyColorField() throws {
        let json = #"{"enabled":true,"color":{"r":0.2,"g":0.4,"b":0.6,"a":1}}"#
        let settings = try JSONDecoder().decode(WhiteboardSettings.self, from: Data(json.utf8))
        #expect(settings.enabled)
        guard case .solid(let color) = settings.background else {
            Issue.record("旧 color 字段应回退为纯色背景")
            return
        }
        #expect(abs(color.r - 0.2) < 1e-9)
        #expect(abs(color.g - 0.4) < 1e-9)
        #expect(abs(color.b - 0.6) < 1e-9)
        #expect(color.a == 1)
    }

    @Test func decodesNewBackgroundField() throws {
        let transparent = try JSONDecoder().decode(
            WhiteboardSettings.self,
            from: Data(#"{"enabled":false,"background":"transparent"}"#.utf8)
        )
        #expect(transparent.background == .transparent)

        let solid = try JSONDecoder().decode(
            WhiteboardSettings.self,
            from: Data(#"{"enabled":true,"background":{"r":0.1,"g":0.2,"b":0.3,"a":1}}"#.utf8)
        )
        guard case .solid(let color) = solid.background else {
            Issue.record("background 颜色对象应解码为纯色背景")
            return
        }
        #expect(abs(color.r - 0.1) < 1e-9)
        #expect(abs(color.g - 0.2) < 1e-9)
        #expect(abs(color.b - 0.3) < 1e-9)
    }

    @Test func missingFieldsFallBackToWhite() throws {
        let settings = try JSONDecoder().decode(
            WhiteboardSettings.self,
            from: Data(#"{"enabled":true}"#.utf8)
        )
        #expect(settings.enabled)
        #expect(settings.background == .solid(.white))
    }

    @Test func encodesOnlyNewBackgroundField() throws {
        let settings = WhiteboardSettings(enabled: true, background: .transparent)
        let data = try JSONEncoder().encode(settings)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["color"] == nil)
        #expect(object["background"] as? String == "transparent")
        #expect(object["enabled"] as? Bool == true)
    }
}
