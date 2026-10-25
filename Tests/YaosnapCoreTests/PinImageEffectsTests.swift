import CoreGraphics
import Testing
@testable import YaosnapCore

struct PinImageEffectsTests {
    private static let width = 12
    private static let height = 10
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private func sample(_ image: CGImage) -> (r: Int, g: Int, b: Int) {
        guard let bytes = PixelBuffer.srgbBytes(image, width: Self.width, height: Self.height) else {
            Issue.record("无法读取像素")
            return (0, 0, 0)
        }
        return PixelBuffer.pixel(bytes, x: 6, y: 5, width: Self.width)
    }

    private func original() -> CGImage {
        PixelBuffer.solidImage(
            width: Self.width,
            height: Self.height,
            colorSpace: Self.sRGB,
            rects: [(CGRect(x: 0, y: 0, width: Self.width, height: Self.height), PixelBuffer.rgb(0.8, 0.2, 0.4))]
        )
    }

    @Test func grayscaleMakesChannelsEqual() {
        let output = PinImageEffects.render(original(), crop: nil, grayscale: true, inverted: false)
        let pixel = sample(output)
        #expect(pixel.r == pixel.g)
        #expect(pixel.g == pixel.b)
    }

    @Test func invertFlipsChannels() {
        let source = sample(original())
        let output = PinImageEffects.render(original(), crop: nil, grayscale: false, inverted: true)
        let pixel = sample(output)
        #expect(abs(pixel.r - (255 - source.r)) <= 1)
        #expect(abs(pixel.g - (255 - source.g)) <= 1)
        #expect(abs(pixel.b - (255 - source.b)) <= 1)
    }

    @Test func grayscaleAndInvertStack() {
        let gray = sample(PinImageEffects.render(original(), crop: nil, grayscale: true, inverted: false))
        let stacked = sample(PinImageEffects.render(original(), crop: nil, grayscale: true, inverted: true))
        #expect(abs(stacked.r - (255 - gray.r)) <= 1)
        #expect(stacked.r == stacked.g)
        #expect(stacked.g == stacked.b)
    }

    @Test func cropKeepsOnlySelectedPixels() {
        let output = PinImageEffects.render(
            original(),
            crop: CGRect(x: 2, y: 3, width: 5, height: 4),
            grayscale: false,
            inverted: false
        )
        #expect(output.width == 5)
        #expect(output.height == 4)
    }

    @Test func selectionClampsToMinimumSideAndBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)
        let tiny = PinCrop.clampedSelection(CGRect(x: 10, y: 10, width: 2, height: 1), in: bounds)
        #expect(tiny?.width == PinCrop.minimumSide)
        #expect(tiny?.height == PinCrop.minimumSide)

        let edge = PinCrop.clampedSelection(CGRect(x: 96, y: 76, width: 3, height: 3), in: bounds)
        #expect(edge?.maxX == bounds.maxX)
        #expect(edge?.maxY == bounds.maxY)
        #expect(edge?.width == PinCrop.minimumSide)
        #expect(edge?.height == PinCrop.minimumSide)
    }

    @Test func viewRectMapsToImagePixels() {
        let imageSize = CGSize(width: 400, height: 200)
        let base = CGSize(width: 200, height: 100)
        // 视图左上四分之一，因 y 轴反向应落在原图顶部。
        let rect = PinCrop.pixelRect(
            fromViewRect: CGRect(x: 0, y: 50, width: 100, height: 50),
            viewSize: base,
            imagePixelSize: imageSize,
            transform: .identity,
            basePointSize: base
        )
        #expect(rect == CGRect(x: 0, y: 0, width: 200, height: 100))
    }

    @Test func rotationMapsViewRectToOriginalPixels() {
        let imageSize = CGSize(width: 40, height: 30)
        let base = imageSize
        let transform = PinTransform(quarterTurns: 1)
        let rect = PinCrop.pixelRect(
            fromViewRect: CGRect(x: 0, y: 0, width: 15, height: 20),
            viewSize: CGSize(width: 30, height: 40),
            imagePixelSize: imageSize,
            transform: transform,
            basePointSize: base
        )
        #expect(rect == CGRect(x: 20, y: 15, width: 20, height: 15))
    }

    @Test func secondCropOffsetsByExistingCropRect() {
        let imageSize = CGSize(width: 400, height: 300)
        let crop = CGRect(x: 100, y: 50, width: 200, height: 150)
        let transform = PinTransform(cropRect: crop)
        let rect = PinCrop.pixelRect(
            fromViewRect: CGRect(x: 0, y: 0, width: 200, height: 150),
            viewSize: CGSize(width: 200, height: 150),
            imagePixelSize: imageSize,
            transform: transform,
            basePointSize: imageSize
        )
        #expect(rect == crop)
    }

    @Test func displayedSizeFollowsCropRatio() {
        let size = PinTransform(cropRect: CGRect(x: 0, y: 0, width: 200, height: 150))
            .displayedSize(
                original: CGSize(width: 400, height: 300),
                imagePixelSize: CGSize(width: 400, height: 300)
            )
        #expect(size == CGSize(width: 200, height: 150))
    }

    @Test func resetClearsCropAndEffects() {
        var transform = PinTransform(
            isGrayscale: true,
            isInverted: true,
            cropRect: CGRect(x: 0, y: 0, width: 4, height: 4)
        )
        transform.reset()
        #expect(transform == .identity)
    }
}
