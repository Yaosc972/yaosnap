import CoreGraphics
import Foundation
import Testing

@testable import YaosnapCore

struct ScrollOffsetEstimatorTests {
    /// 构造「像截图一样」的页面：每行一个基准亮度、行内再加细纹理。
    ///
    /// 早期版本用的是纯随机噪声，那是为 Vision 配准准备的素材；
    /// 现在的估计器按「行剖面」工作，依据的是行的结构（文本行/留白交替），
    /// 纯噪声在 24 列平均后每行都趋同，反而不具备可配准的行结构。
    private func makePagePixels(width: Int, height: Int, seed: UInt32) -> [UInt8] {
        var state = seed
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            state = state &* 1_664_525 &+ 1_013_904_223
            // 行基准亮度：模拟文本行与行间留白的交替
            let base = Int((state >> 16) % 180)
            for x in 0..<width {
                let i = (y * width + x) * 4
                let tint = ((x / 3) % 7) * 5
                let value = UInt8(clamping: base + tint)
                data[i] = value
                data[i + 1] = value
                data[i + 2] = value
                data[i + 3] = 255
            }
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

    private func makePage(width: Int, height: Int, seed: UInt32) -> CGImage {
        makeImage(width: width, height: height, pixels: makePagePixels(width: width, height: height, seed: seed))
    }

    private func frame(_ page: CGImage, offset: Int, height: Int) -> CGImage {
        page.cropping(to: CGRect(x: 0, y: offset, width: page.width, height: height))!
    }

    @Test func estimatesDownwardScroll() throws {
        let page = makePage(width: 320, height: 900, seed: 7)
        let previous = frame(page, offset: 0, height: 400)
        let current = frame(page, offset: 60, height: 400)
        let estimate = try #require(ScrollOffsetEstimator().estimate(current: current, previous: previous))
        #expect(abs(estimate.offsetPx - 60) <= 2)
    }

    @Test func rejectsDifferentSizes() {
        let a = makePage(width: 320, height: 400, seed: 1)
        let b = makePage(width: 300, height: 400, seed: 2)
        #expect(ScrollOffsetEstimator().estimate(current: b, previous: a) == nil)
    }

    /// 两帧内容无关：不能硬凑出一个位移。
    @Test func rejectsUnrelatedFrames() {
        let a = makePage(width: 320, height: 400, seed: 11)
        let b = makePage(width: 320, height: 400, seed: 99)
        #expect(ScrollOffsetEstimator().estimate(current: b, previous: a) == nil)
    }

    /// 原地不动必须返回 0，不能因为「所有位移都差不多」而挑一个极端值。
    @Test func staticFramesReportZero() throws {
        let frameImage = makePage(width: 320, height: 400, seed: 5)
        let estimate = try #require(ScrollOffsetEstimator().estimate(current: frameImage, previous: frameImage))
        #expect(estimate.offsetPx == 0)
    }

    /// 固定顶部条（粘性标题栏）不应导致合法滚动帧被误拒。
    @Test func estimatesScrollWithFixedHeader() throws {
        let pair = frameWithFixedTop(
            width: 320, frameHeight: 400, header: 100, shift: 60,
            pageSeed: 7, pageHeight: 900
        )
        let estimate = try #require(
            ScrollOffsetEstimator().estimate(current: pair.current, previous: pair.previous)
        )
        #expect(abs(estimate.offsetPx - 60) <= 2)
    }

    /// 固定标题栏 + 固定底栏（聊天输入框这类）同时存在时，位移仍要估对，
    /// 并报出底部固定条带高度供拼接器剔除。
    @Test func estimatesScrollWithStickyHeaderAndFooter() throws {
        let pair = frameWithFixedTopAndBottom(
            width: 320, frameHeight: 500, header: 80, footer: 120, shift: 70,
            pageSeed: 21, pageHeight: 1400
        )
        let estimate = try #require(
            ScrollOffsetEstimator().estimate(current: pair.current, previous: pair.previous)
        )
        #expect(abs(estimate.offsetPx - 70) <= 2)
        #expect(estimate.stickyBottomPx >= 116)
    }

    /// 常规路径限制在 60% 位移内：位移太接近整帧时重叠区太小，任何位移都能凑出低代价。
    @Test func estimatesShiftWithinWindow() throws {
        let page = makePage(width: 320, height: 1400, seed: 33)
        let previous = frame(page, offset: 0, height: 500)
        let current = frame(page, offset: 250, height: 500)
        let estimate = try #require(ScrollOffsetEstimator().estimate(current: current, previous: previous))
        #expect(abs(estimate.offsetPx - 250) <= 2)
    }

    /// 超出常规窗口的位移由宽窗口估计器承担（断链重建专用）。
    @Test func wideEstimatorHandlesLargeShift() throws {
        let page = makePage(width: 320, height: 1400, seed: 33)
        let previous = frame(page, offset: 0, height: 500)
        let current = frame(page, offset: 400, height: 500)
        let wide = ScrollOffsetEstimator(minimumOverlapFraction: 0.15)
        let estimate = try #require(wide.estimate(current: current, previous: previous))
        #expect(abs(estimate.offsetPx - 400) <= 2)
    }

    /// 向上滚动：当前帧内容来自页面更靠前的位置，位移应为负。
    @Test func estimatesUpwardScroll() throws {
        let page = makePage(width: 320, height: 900, seed: 3)
        let previous = frame(page, offset: 300, height: 400)
        let current = frame(page, offset: 100, height: 400)
        let estimate = try #require(ScrollOffsetEstimator().estimate(current: current, previous: previous))
        #expect(abs(estimate.offsetPx + 200) <= 2)
    }

    // MARK: - 构造固定头/尾的画面

    /// 直接从像素缓冲拼帧：顶部 header 行固定不动，其余行来自页面 shift 之后的位置。
    /// 用像素拷贝而不是 CGContext 绘制，避免方向/插值让测试素材本身失真。
    private func frameWithFixedTop(
        width: Int,
        frameHeight: Int,
        header: Int,
        shift: Int,
        pageSeed: UInt32,
        pageHeight: Int
    ) -> (previous: CGImage, current: CGImage) {
        let pagePixels = makePagePixels(width: width, height: pageHeight, seed: pageSeed)
        let bytesPerRow = width * 4
        var currentPixels = [UInt8](repeating: 0, count: bytesPerRow * frameHeight)
        for y in 0..<frameHeight {
            let sourceRow = y < header ? y : y + shift
            let source = sourceRow * bytesPerRow
            let destination = y * bytesPerRow
            currentPixels.replaceSubrange(
                destination..<destination + bytesPerRow,
                with: pagePixels[source..<source + bytesPerRow]
            )
        }
        let previous = makeImage(
            width: width,
            height: frameHeight,
            pixels: Array(pagePixels[0..<(bytesPerRow * frameHeight)])
        )
        let current = makeImage(width: width, height: frameHeight, pixels: currentPixels)
        return (previous, current)
    }

    /// 顶部 header 与底部 footer 都固定不动，中间是滚动内容。
    private func frameWithFixedTopAndBottom(
        width: Int,
        frameHeight: Int,
        header: Int,
        footer: Int,
        shift: Int,
        pageSeed: UInt32,
        pageHeight: Int
    ) -> (previous: CGImage, current: CGImage) {
        let pagePixels = makePagePixels(width: width, height: pageHeight, seed: pageSeed)
        let bytesPerRow = width * 4
        var currentPixels = [UInt8](repeating: 0, count: bytesPerRow * frameHeight)
        for y in 0..<frameHeight {
            let sourceRow: Int
            if y < header {
                sourceRow = y
            } else if y >= frameHeight - footer {
                sourceRow = y
            } else {
                sourceRow = y + shift
            }
            let source = sourceRow * bytesPerRow
            let destination = y * bytesPerRow
            currentPixels.replaceSubrange(
                destination..<destination + bytesPerRow,
                with: pagePixels[source..<source + bytesPerRow]
            )
        }
        let previous = makeImage(
            width: width,
            height: frameHeight,
            pixels: Array(pagePixels[0..<(bytesPerRow * frameHeight)])
        )
        let current = makeImage(width: width, height: frameHeight, pixels: currentPixels)
        return (previous, current)
    }
}