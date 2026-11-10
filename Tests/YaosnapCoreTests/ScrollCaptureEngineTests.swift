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

private final class RecordingEstimator: ScrollOffsetEstimating {
    let offset: CGFloat
    let confidence: Float
    private(set) var previousFrames: [CGImage] = []

    init(offset: CGFloat, confidence: Float) {
        self.offset = offset
        self.confidence = confidence
    }

    func estimate(current: CGImage, previous: CGImage) -> ScrollOffsetEstimate? {
        previousFrames.append(previous)
        return ScrollOffsetEstimate(offsetPx: offset, confidence: confidence)
    }
}


/// 与上一帧配准失败一次、但宽窗口重建能成功的估计器。
private final class FailsOnceThenEstimator: ScrollOffsetEstimating {
    private let offset: CGFloat
    private var didFail = false

    init(offset: CGFloat) { self.offset = offset }

    func estimate(current: CGImage, previous: CGImage) -> ScrollOffsetEstimate? {
        guard didFail else {
            didFail = true
            return nil
        }
        return ScrollOffsetEstimate(offsetPx: offset, confidence: 0.9)
    }

    func estimateForReconnect(current: CGImage, previous: CGImage) -> ScrollOffsetEstimate? {
        ScrollOffsetEstimate(offsetPx: offset, confidence: 0.9)
    }
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

    @Test func rejectedFrameStillAdvancesReference() {
        // 偏移 2 落在默认死区（3）内，拼接器会拒绝该帧；但参考帧必须前进到最新帧，
        // 否则一旦某帧配准失败，后续帧会永远和一张旧参考比较，整条链路停摆。
        let estimator = RecordingEstimator(offset: 2, confidence: 0.9)
        let engine = ScrollCaptureEngine(estimator: estimator)
        let first = makeImage(width: 20, height: 100)
        engine.start(first: first)

        let second = makeImage(width: 20, height: 100)
        let state = engine.consume(frame: second)
        #expect(state?.changed == false)
        #expect(engine.image?.height == 100)
        #expect(engine.frameCount == 1)

        let third = makeImage(width: 20, height: 100)
        engine.consume(frame: third)
        #expect(estimator.previousFrames.count == 2)
        #expect(estimator.previousFrames[0] === first)
        #expect(estimator.previousFrames[1] === second)
        #expect(engine.frameCount == 1)
    }

    /// 断链重建：与上一帧配准失败时，同一帧必须靠宽窗口与最后一个已拼接帧接回长图。
    @Test func reconnectsAfterFailedFrame() {
        let estimator = FailsOnceThenEstimator(offset: 40)
        let engine = ScrollCaptureEngine(estimator: estimator)
        engine.start(first: makeImage(width: 20, height: 100))
        let state = engine.consume(frame: makeImage(width: 20, height: 100))
        #expect(state?.changed == true)
        #expect(engine.image?.height == 140)
    }
}