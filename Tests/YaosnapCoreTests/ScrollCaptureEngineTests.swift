import CoreGraphics
import Foundation
import Testing

@testable import YaosnapCore

private struct FixedEstimator: ScrollOffsetEstimating {
    let offset: CGFloat
    let confidence: Float

    func estimate(current: CGImage, previous: CGImage) -> ScrollOffsetEstimate? {
        ScrollOffsetEstimate(offsetPx: offset, confidence: confidence)
    }
}

private struct NeverEstimator: ScrollOffsetEstimating {
    func estimate(current: CGImage, previous: CGImage) -> ScrollOffsetEstimate? { nil }
}

struct ScrollCaptureEngineTests {
    private func makeImage(width: Int, height: Int) -> CGImage {
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 200, count: bytesPerRow * height)
        for i in stride(from: 3, to: data.count, by: 4) { data[i] = 255 }
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    @Test func growsByEstimatedOffset() {
        let engine = ScrollCaptureEngine(estimator: FixedEstimator(offset: 30, confidence: 0.9))
        engine.start(first: makeImage(width: 20, height: 100))
        engine.consume(frame: makeImage(width: 20, height: 100))
        engine.consume(frame: makeImage(width: 20, height: 100))
        #expect(engine.image?.height == 160)
        #expect(engine.frameCount == 3)
    }

    @Test func lowConfidenceFrameSkipped() {
        let engine = ScrollCaptureEngine(estimator: FixedEstimator(offset: 30, confidence: 0.1))
        engine.start(first: makeImage(width: 20, height: 100))
        #expect(engine.consume(frame: makeImage(width: 20, height: 100)) == nil)
        #expect(engine.image?.height == 100)
    }

    @Test func missingEstimateSkipped() {
        let engine = ScrollCaptureEngine(estimator: NeverEstimator())
        engine.start(first: makeImage(width: 20, height: 100))
        #expect(engine.consume(frame: makeImage(width: 20, height: 100)) == nil)
        #expect(engine.image?.height == 100)
    }
}
