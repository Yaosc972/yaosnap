import CoreGraphics
import Foundation
import Testing

@testable import YaosnapCore

struct ScrollStitcherTests {
    /// 每行一个灰度值，便于断言拼接后哪些行在哪个位置。
    private func makeImage(width: Int, height: Int, rowColor: (Int) -> UInt8) -> CGImage {
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bytesPerRow + x * 4
                data[i] = rowColor(y)
                data[i + 1] = rowColor(y)
                data[i + 2] = rowColor(y)
                data[i + 3] = 255
            }
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

    private func pixel(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        let bytesPerRow = image.width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let ctx = CGContext(
            data: &buffer,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer[y * bytesPerRow + x * 4]
    }

    @Test func startKeepsFirstFrame() {
        let stitcher = ScrollStitcher()
        let first = makeImage(width: 20, height: 100) { UInt8($0) }
        let state = stitcher.start(first: first)
        #expect(state.frameCount == 1)
        #expect(stitcher.image?.height == 100)
    }

    @Test func downwardScrollAppendsBottomStrip() {
        let stitcher = ScrollStitcher()
        let first = makeImage(width: 20, height: 100) { UInt8($0) }
        stitcher.start(first: first)
        let second = makeImage(width: 20, height: 100) { UInt8($0 + 100) }
        let state = stitcher.ingest(frame: second, offsetPx: 40)
        #expect(state?.changed == true)
        #expect(stitcher.image?.height == 140)
        // 底部 40 行来自新帧的底部 40 行（灰度 160...199）
        #expect(pixel(stitcher.image!, x: 0, y: 139) == 199)
        #expect(pixel(stitcher.image!, x: 0, y: 100) == 160)
    }

    @Test func deadZoneIgnored() {
        let stitcher = ScrollStitcher()
        stitcher.start(first: makeImage(width: 20, height: 100) { UInt8($0) })
        let state = stitcher.ingest(frame: makeImage(width: 20, height: 100) { UInt8($0) }, offsetPx: 2)
        #expect(state?.changed == false)
        #expect(stitcher.image?.height == 100)
    }

    @Test func reverseOffsetNeedsTwoConfirmations() {
        let stitcher = ScrollStitcher()
        stitcher.start(first: makeImage(width: 20, height: 100) { UInt8($0) })
        stitcher.ingest(frame: makeImage(width: 20, height: 100) { UInt8($0) }, offsetPx: 50)
        #expect(stitcher.image?.height == 150)

        let frame = makeImage(width: 20, height: 100) { UInt8($0) }
        let firstReverse = stitcher.ingest(frame: frame, offsetPx: -30)
        #expect(firstReverse?.changed == false)
        #expect(stitcher.image?.height == 150)

        let secondReverse = stitcher.ingest(frame: frame, offsetPx: -30)
        #expect(secondReverse?.changed == true)
        #expect(stitcher.image?.height == 120)
    }

    @Test func stopsAtMaxHeight() {
        let stitcher = ScrollStitcher(maxHeightPx: 120)
        stitcher.start(first: makeImage(width: 20, height: 100) { UInt8($0) })
        let state = stitcher.ingest(frame: makeImage(width: 20, height: 100) { UInt8($0) }, offsetPx: 50)
        #expect(stitcher.image?.height == 120)
        #expect(state?.reachedLimit == true)
    }

    @Test func widthMismatchIgnored() {
        let stitcher = ScrollStitcher()
        stitcher.start(first: makeImage(width: 20, height: 100) { UInt8($0) })
        let state = stitcher.ingest(frame: makeImage(width: 30, height: 100) { UInt8($0) }, offsetPx: 40)
        #expect(state?.changed == false)
        #expect(stitcher.image?.height == 100)
    }
}
