import CoreGraphics
import Testing
@testable import YaosnapCore

struct ImageShadowTests {
    // 40x30 图像加 24pt 边距后成 88x78，四周留透明
    @Test func addsTransparentMarginAroundImage() throws {
        let image = PixelBuffer.solidImage(width: 40, height: 30, rects: [])
        let shadowed = try #require(ImageShadow.apply(to: image, margin: 24, blur: 12))
        #expect(shadowed.width == 88)
        #expect(shadowed.height == 78)

        let bytes = try #require(PixelBuffer.srgbBytes(shadowed, width: 88, height: 78))
        let corners = [(0, 0), (87, 0), (0, 77), (87, 77)]
        for (x, y) in corners {
            #expect(bytes[(y * 88 + x) * 4 + 3] == 0, "corner (\(x),\(y)) should be transparent")
        }
    }
}
