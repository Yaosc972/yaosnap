import CoreGraphics
import Foundation
import Testing

@testable import YaosnapCore

struct ScrollOffsetEstimatorTests {
    /// 确定性伪随机噪声：Vision 对纯色或重复纹理无法配准。
    private func makeNoiseImage(width: Int, height: Int, seed: UInt32) -> CGImage {
        var state = seed
        func next() -> UInt8 {
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8((state >> 16) & 0xFF)
        }
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        for i in stride(from: 0, to: data.count, by: 4) {
            let value = next()
            data[i] = value
            data[i + 1] = value
            data[i + 2] = value
            data[i + 3] = 255
        }
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    @Test func estimatesDownwardScroll() throws {
        let big = makeNoiseImage(width: 320, height: 900, seed: 7)
        let previous = big.cropping(to: CGRect(x: 0, y: 0, width: 320, height: 400))!
        let current = big.cropping(to: CGRect(x: 0, y: 60, width: 320, height: 400))!
        let estimate = VisionScrollOffsetEstimator().estimate(current: current, previous: previous)
        let offset = try #require(estimate).offsetPx
        #expect(abs(offset - 60) <= 2)
    }

    @Test func rejectsDifferentSizes() {
        let a = makeNoiseImage(width: 320, height: 400, seed: 1)
        let b = makeNoiseImage(width: 300, height: 400, seed: 2)
        #expect(VisionScrollOffsetEstimator().estimate(current: b, previous: a) == nil)
    }

    @Test func rejectsUnrelatedFrames() {
        let a = makeNoiseImage(width: 320, height: 400, seed: 11)
        let b = makeNoiseImage(width: 320, height: 400, seed: 99)
        let estimate = VisionScrollOffsetEstimator().estimate(current: b, previous: a)
        #expect(estimate == nil || estimate!.confidence < 0.3)
    }
}
