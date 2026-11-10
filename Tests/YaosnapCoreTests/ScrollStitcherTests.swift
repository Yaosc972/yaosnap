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
        // 既有行 0..99 必须原样保留且方向不变（行 0 仍在顶部）。
        #expect(pixel(stitcher.image!, x: 0, y: 0) == 0)
        #expect(pixel(stitcher.image!, x: 0, y: 99) == 99)
    }

    @Test func deadZoneIgnored() {
        let stitcher = ScrollStitcher()
        stitcher.start(first: makeImage(width: 20, height: 100) { UInt8($0) })
        let state = stitcher.ingest(frame: makeImage(width: 20, height: 100) { UInt8($0) }, offsetPx: 2)
        #expect(state?.changed == false)
        #expect(stitcher.image?.height == 100)
    }

    /// 向上滚动（内容向下移动）：新内容从顶部出现，必须前插到长图顶部，不能裁剪。
    @Test func upwardScrollPrependsTopStrip() {
        let stitcher = ScrollStitcher()
        // 首帧灰度 100...199
        stitcher.start(first: makeImage(width: 20, height: 100) { UInt8($0 + 100) })
        // 向上滚 40：新帧顶部 40 行是更早的内容（灰度 60...99），其余与首帧顶部对齐
        let frame = makeImage(width: 20, height: 100) { row in
            row < 40 ? UInt8(row + 60) : UInt8(row - 40 + 100)
        }
        let state = stitcher.ingest(frame: frame, offsetPx: -40)
        #expect(state?.changed == true)
        #expect(stitcher.image?.height == 140)
        // 顶部 40 行来自新帧顶部
        #expect(pixel(stitcher.image!, x: 0, y: 0) == 60)
        #expect(pixel(stitcher.image!, x: 0, y: 39) == 99)
        // 原有画面整体下移 40 行
        #expect(pixel(stitcher.image!, x: 0, y: 40) == 100)
        #expect(pixel(stitcher.image!, x: 0, y: 139) == 199)
    }

    /// 上下都滚：两个方向都要能累积。
    @Test func bothDirectionsAccumulate() {
        let stitcher = ScrollStitcher()
        stitcher.start(first: makeImage(width: 20, height: 100) { UInt8($0) })
        stitcher.ingest(frame: makeImage(width: 20, height: 100) { UInt8($0 + 100) }, offsetPx: 50)
        #expect(stitcher.image?.height == 150)
        stitcher.ingest(frame: makeImage(width: 20, height: 100) { UInt8($0) }, offsetPx: -30)
        #expect(stitcher.image?.height == 180)
    }

    /// 顶部固定条带（标题栏）不得被重复前插。
    @Test func stickyTopExcludedWhenPrepending() {
        let stitcher = ScrollStitcher()
        stitcher.start(first: makeImage(width: 20, height: 100) { UInt8($0) })
        // 新帧顶部 20 行固定不动，其下 30 行才是新内容
        let frame = makeImage(width: 20, height: 100) { row in
            row < 20 ? UInt8(row) : (row < 50 ? UInt8(row + 200) : UInt8(row - 30))
        }
        let state = stitcher.ingest(frame: frame, offsetPx: -30, stickyTopPx: 20)
        #expect(state?.changed == true)
        #expect(stitcher.image?.height == 130)
        // 前插的是固定条带下方那 30 行（frame 第 20 行 = 20 + 200 = 220）
        #expect(pixel(stitcher.image!, x: 0, y: 0) == 220)
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