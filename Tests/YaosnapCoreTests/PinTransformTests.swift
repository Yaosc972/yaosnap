import CoreGraphics
import Testing
@testable import YaosnapCore

struct PinTransformTests {
    @Test func scaleMultipliesBaseSize() {
        var transform = PinTransform()
        transform.setScale(2)
        #expect(
            transform.windowSize(base: CGSize(width: 40, height: 30))
                == CGSize(width: 80, height: 60)
        )
    }

    @Test func quarterTurnSwapsSize() {
        var odd = PinTransform(quarterTurns: 1)
        #expect(
            odd.windowSize(base: CGSize(width: 40, height: 30))
                == CGSize(width: 30, height: 40)
        )
        #expect(odd.rotationDegrees == 90)

        var even = PinTransform(quarterTurns: 2)
        #expect(
            even.windowSize(base: CGSize(width: 40, height: 30))
                == CGSize(width: 40, height: 30)
        )
        #expect(even.rotationDegrees == 180)
    }

    @Test func flipsToggleBack() {
        var transform = PinTransform()
        transform.toggleFlipHorizontal()
        #expect(transform.flipHorizontal)
        transform.toggleFlipHorizontal()
        #expect(!transform.flipHorizontal)

        transform.toggleFlipVertical()
        #expect(transform.flipVertical)
        transform.toggleFlipVertical()
        #expect(!transform.flipVertical)
    }

    @Test func opacityClamps() {
        #expect(PinTransform(opacity: 0).opacity == 0.1)
        #expect(PinTransform(opacity: 5).opacity == 1)
        var transform = PinTransform()
        transform.setOpacity(0.5)
        #expect(transform.opacity == 0.5)
    }

    @Test func resetRestoresIdentity() {
        var transform = PinTransform()
        transform.setScale(3)
        transform.rotate(byQuarterTurns: 1)
        transform.toggleFlipHorizontal()
        transform.toggleFlipVertical()
        transform.setOpacity(0.4)
        transform.toggleThumbnail()
        transform.reset()
        #expect(transform == .identity)
    }

    @Test func quarterTurnsNormalize() {
        #expect(PinTransform(quarterTurns: -1).quarterTurns == 3)
        #expect(PinTransform(quarterTurns: 5).quarterTurns == 1)
        var transform = PinTransform(quarterTurns: 3)
        transform.rotate(byQuarterTurns: 2)
        #expect(transform.quarterTurns == 1)
    }

    @Test func thumbnailFitsLongSideWithoutUpscaling() {
        var transform = PinTransform()
        transform.setScale(2)
        let base = CGSize(width: 200, height: 100)
        #expect(transform.unrotatedSize(base: base) == CGSize(width: 400, height: 200))

        transform.toggleThumbnail()
        #expect(transform.unrotatedSize(base: base) == CGSize(width: 96, height: 48))

        transform.toggleThumbnail()
        #expect(transform.unrotatedSize(base: base) == CGSize(width: 400, height: 200))
    }

    @Test func scaleClamps() {
        #expect(PinTransform(scale: 0).scale == 0.1)
        #expect(PinTransform(scale: 100).scale == 8)
    }
}
