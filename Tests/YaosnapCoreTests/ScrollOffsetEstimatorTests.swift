import CoreGraphics
import Foundation
import Testing

@testable import YaosnapCore

struct ScrollOffsetEstimatorTests {
    /// 确定性伪随机噪声：Vision 对纯色或重复纹理无法配准。
    private func makeNoisePixels(width: Int, height: Int, seed: UInt32) -> [UInt8] {
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
        return data
    }

    private func makeImage(width: Int, height: Int, pixels: [UInt8]) -> CGImage {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    private func makeNoiseImage(width: Int, height: Int, seed: UInt32) -> CGImage {
        makeImage(width: width, height: height, pixels: makeNoisePixels(width: width, height: height, seed: seed))
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

    /// 固定顶部条（粘性标题栏）不应导致合法滚动帧被误拒。
    @Test func estimatesScrollWithFixedHeader() throws {
        let width = 320
        let frameHeight = 400
        let headerHeight = 100
        let bytesPerRow = width * 4
        let bigPixels = makeNoisePixels(width: width, height: 900, seed: 7)
        let previous = makeImage(width: width, height: 900, pixels: bigPixels)
            .cropping(to: CGRect(x: 0, y: 0, width: width, height: frameHeight))!

        // 当前帧内容整体来自下移 60px 的视口，但顶部 100px 与上一帧完全相同。
        var currentPixels = [UInt8](repeating: 0, count: bytesPerRow * frameHeight)
        for row in 0..<frameHeight {
            let source = (row + 60) * bytesPerRow
            let destination = row * bytesPerRow
            currentPixels.replaceSubrange(
                destination..<destination + bytesPerRow,
                with: bigPixels[source..<source + bytesPerRow]
            )
        }
        for row in 0..<headerHeight {
            let source = row * bytesPerRow
            let destination = row * bytesPerRow
            currentPixels.replaceSubrange(
                destination..<destination + bytesPerRow,
                with: bigPixels[source..<source + bytesPerRow]
            )
        }
        let current = makeImage(width: width, height: frameHeight, pixels: currentPixels)

        let estimate = VisionScrollOffsetEstimator().estimate(current: current, previous: previous)
        let offset = try #require(estimate).offsetPx
        #expect(abs(offset - 60) <= 2)
    }

    /// 大面积黑底 + 少量异位亮块：两帧无关，不能靠全局均值稀释蒙混过关。
    @Test func rejectsSparseDarkUnrelatedFrames() {
        let width = 320
        let height = 400
        func sparsePixels(squares: [(x: Int, y: Int)]) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: width * height * 4)
            for i in stride(from: 3, to: data.count, by: 4) {
                data[i] = 255
            }
            for square in squares {
                for y in square.y..<(square.y + 10) {
                    for x in square.x..<(square.x + 10) {
                        let i = (y * width + x) * 4
                        data[i] = 255
                        data[i + 1] = 255
                        data[i + 2] = 255
                    }
                }
            }
            return data
        }
        let a = makeImage(
            width: width,
            height: height,
            pixels: sparsePixels(squares: [(20, 30), (120, 90), (250, 200), (60, 300), (200, 350)])
        )
        let b = makeImage(
            width: width,
            height: height,
            pixels: sparsePixels(squares: [(40, 70), (150, 20), (60, 220), (230, 300), (280, 120)])
        )
        #expect(VisionScrollOffsetEstimator().estimate(current: b, previous: a) == nil)
    }
}
