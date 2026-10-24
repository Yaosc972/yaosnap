import CoreGraphics
import Foundation
import Testing
@testable import YaosnapCore

struct MagnifierTests {
    /// 200x100 像素四象限图：左上红、右上绿、左下蓝、右下黄。
    /// 画布 100x50 点、scale 2，验证点坐标到 Retina 像素的换算。
    private func quadrants() -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return PixelBuffer.solidImage(
            width: 200,
            height: 100,
            colorSpace: space,
            rects: [
                (CGRect(x: 0, y: 50, width: 100, height: 50), PixelBuffer.rgb(1, 0, 0)),
                (CGRect(x: 100, y: 50, width: 100, height: 50), PixelBuffer.rgb(0, 1, 0)),
                (CGRect(x: 0, y: 0, width: 100, height: 50), PixelBuffer.rgb(0, 0, 1)),
                (CGRect(x: 100, y: 0, width: 100, height: 50), PixelBuffer.rgb(1, 1, 0)),
            ]
        )
    }

    private func sampler() -> MagnifierSampler {
        MagnifierSampler(
            image: quadrants(),
            canvasSize: CGSize(width: 100, height: 50),
            scale: 2
        )
    }

    private func expectColor(
        _ color: PixelColor?,
        r: ClosedRange<Int>,
        g: ClosedRange<Int>,
        b: ClosedRange<Int>,
        _ label: String
    ) {
        guard let color else {
            Issue.record("\(label) 采样失败")
            return
        }
        #expect(r.contains(Int(color.red)), "\(label) red=\(color.red)")
        #expect(g.contains(Int(color.green)), "\(label) green=\(color.green)")
        #expect(b.contains(Int(color.blue)), "\(label) blue=\(color.blue)")
    }

    @Test func colorSamplingMatchesCanvasPoint() {
        let sampler = sampler()
        // 画布 y 向上：y=37 落在图像上半（红/绿），y=13 落在下半（蓝/黄）。
        expectColor(sampler.color(at: CGPoint(x: 25, y: 37)), r: 240...255, g: 0...15, b: 0...15, "左上")
        expectColor(sampler.color(at: CGPoint(x: 75, y: 37)), r: 0...15, g: 240...255, b: 0...15, "右上")
        expectColor(sampler.color(at: CGPoint(x: 25, y: 13)), r: 0...15, g: 0...15, b: 240...255, "左下")
        expectColor(sampler.color(at: CGPoint(x: 75, y: 13)), r: 240...255, g: 240...255, b: 0...15, "右下")
    }

    @Test func colorSamplingUsesRetinaPixelOffset() {
        let sampler = sampler()
        // 点 49.9 仍是第 99 像素（红），50.0 已跨到第 100 像素（绿）。差值错一个 scale 就会串色。
        expectColor(sampler.color(at: CGPoint(x: 49.9, y: 37)), r: 240...255, g: 0...15, b: 0...15, "分界左")
        expectColor(sampler.color(at: CGPoint(x: 50.0, y: 37)), r: 0...15, g: 240...255, b: 0...15, "分界右")
    }

    @Test func colorFormatting() {
        let color = PixelColor(red: 255, green: 136, blue: 0)
        #expect(ColorFormat.hex.string(for: color) == "#FF8800")
        #expect(ColorFormat.rgb.string(for: color) == "rgb(255, 136, 0)")
        #expect(ColorFormat.hex.toggled == .rgb)
        #expect(ColorFormat.rgb.toggled == .hex)
    }

    @Test func framePlacesMagnifierBottomRightByDefault() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let cursor = CGPoint(x: 400, y: 400)
        let frame = MagnifierGeometry.frame(cursor: cursor, in: bounds)
        #expect(frame.minX > cursor.x)
        #expect(frame.maxY < cursor.y)
        #expect(bounds.contains(frame))
    }

    @Test func frameFlipsNearBottomRightEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let cursor = CGPoint(x: 990, y: 12)
        let frame = MagnifierGeometry.frame(cursor: cursor, in: bounds)
        #expect(frame.width == MagnifierGeometry.side)
        #expect(frame.height == MagnifierGeometry.side)
        #expect(frame.maxX <= cursor.x)
        #expect(frame.minY >= cursor.y)
        #expect(bounds.contains(frame))
    }

    @Test func samplePixelCountIsOdd() {
        for scale in [CGFloat(1), 2, 3] {
            let count = MagnifierGeometry.samplePixelCount(scale: scale)
            #expect(count % 2 == 1)
            #expect(count >= 3)
        }
    }
}
