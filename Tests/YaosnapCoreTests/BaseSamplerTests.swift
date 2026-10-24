import CoreGraphics
import Foundation
import Testing
@testable import YaosnapCore

struct BaseSamplerTests {
    private let red = PixelBuffer.rgb(1, 0, 0)
    private let blue = PixelBuffer.rgb(0, 0, 1)
    private let green = PixelBuffer.rgb(0, 1, 0)

    /// 底图 200x100：左半红右半蓝、上半绿下半红叠加。这里用简单构图：
    /// 左半红右半蓝（x 轴验证），另加一张上半绿下半蓝（y 轴验证）。
    private func horizontalImage() -> CGImage {
        PixelBuffer.solidImage(
            width: 200, height: 100,
            rects: [
                (CGRect(x: 0, y: 0, width: 100, height: 100), red),
                (CGRect(x: 100, y: 0, width: 100, height: 100), blue),
            ]
        )
    }

    private func sampler(base: CGImage) -> BaseSampler {
        // 画布 100x50 点，scale 2 → 帧内像素 200x100，cropOrigin 零
        BaseSampler(base: base, cropOriginPx: .zero, canvasSize: CGSize(width: 100, height: 50), scale: 2)
    }

    @Test func pixelatedFullRegionKeepsHorizontalSplit() throws {
        let output = try #require(
            sampler(base: horizontalImage()).pixelated(region: CGRect(x: 0, y: 0, width: 100, height: 50), blockPoints: 50)
        )
        #expect(output.width == 200)
        #expect(output.height == 100)
        let bytes = try #require(PixelBuffer.srgbBytes(output, width: 200, height: 100))
        // blockPx = 100 → 横向两块：左红右蓝
        let left = PixelBuffer.pixel(bytes, x: 50, y: 50, width: 200)
        #expect(left.r > 200 && left.b < 60)
        let right = PixelBuffer.pixel(bytes, x: 150, y: 50, width: 200)
        #expect(right.b > 200 && right.r < 60)
    }

    @Test func pixelatedBlockGridMatchesSource() throws {
        // blockPx = 25*2 = 50 → 横向 4 块 [红,红,蓝,蓝]，边界在 50/100/150
        let output = try #require(
            sampler(base: horizontalImage()).pixelated(region: CGRect(x: 0, y: 0, width: 100, height: 50), blockPoints: 25)
        )
        let bytes = try #require(PixelBuffer.srgbBytes(output, width: 200, height: 100))
        let block1 = PixelBuffer.pixel(bytes, x: 10, y: 50, width: 200)
        let block2 = PixelBuffer.pixel(bytes, x: 60, y: 50, width: 200)
        let block3 = PixelBuffer.pixel(bytes, x: 110, y: 50, width: 200)
        let block4 = PixelBuffer.pixel(bytes, x: 160, y: 50, width: 200)
        #expect(block1.r > 200 && block2.r > 200)
        #expect(block3.b > 200 && block4.b > 200)
        #expect(block1.r == block2.r && block3.b == block4.b)
    }

    @Test func pixelatedKeepsVerticalOrientation() throws {
        // 底图上半绿下半蓝（上下文左下原点：y 大的是图像顶部）
        let base = PixelBuffer.solidImage(
            width: 200, height: 100,
            rects: [
                (CGRect(x: 0, y: 50, width: 200, height: 50), green),
                (CGRect(x: 0, y: 0, width: 200, height: 50), blue),
            ]
        )
        // blockPx = 25*2 = 50 → 纵向两块：上部对应图像顶部
        let output = try #require(
            sampler(base: base).pixelated(region: CGRect(x: 0, y: 0, width: 100, height: 50), blockPoints: 25)
        )
        let bytes = try #require(PixelBuffer.srgbBytes(output, width: 200, height: 100))
        // 画布上部（y 高）对应图像顶部 → 绿
        let top = PixelBuffer.pixel(bytes, x: 100, y: 25, width: 200)
        #expect(top.g > 200 && top.b < 60)
        let bottom = PixelBuffer.pixel(bytes, x: 100, y: 75, width: 200)
        #expect(bottom.b > 200 && bottom.g < 60)
    }

    @Test func pixelatedClampsOutOfRangeRegion() throws {
        // region 右半出界（画布宽 100，region 到 150）→ 钳制为 50 点宽
        let output = try #require(
            sampler(base: horizontalImage()).pixelated(region: CGRect(x: 50, y: 0, width: 100, height: 50), blockPoints: 50)
        )
        #expect(output.width == 100)
        #expect(output.height == 100)
        let bytes = try #require(PixelBuffer.srgbBytes(output, width: 100, height: 100))
        // 钳制后只剩右侧蓝区
        let sampled = PixelBuffer.pixel(bytes, x: 50, y: 50, width: 100)
        #expect(sampled.b > 200 && sampled.r < 60)
    }

    @Test func pixelatedRejectsFullyOutOfRangeAndDegenerate() {
        let sampler = sampler(base: horizontalImage())
        #expect(sampler.pixelated(region: CGRect(x: 150, y: 0, width: 50, height: 50), blockPoints: 50) == nil)
        #expect(sampler.pixelated(region: CGRect(x: 0, y: 0, width: 0, height: 50), blockPoints: 50) == nil)
        #expect(sampler.pixelated(region: CGRect(x: 0, y: 0, width: 100, height: 50), blockPoints: 0) == nil)
    }
}
