import CoreGraphics
import Foundation
import Testing
@testable import YaosnapCore

struct AnnotationExportTests {
    private let red = RGBAColor(r: 1, g: 0, b: 0)

    private func flatten(
        _ base: CGImage,
        cropRectPx: CGRect,
        annotations: [Annotation] = [],
        scale: CGFloat = 1
    ) -> CGImage? {
        AnnotationExport.flatten(
            base: base,
            cropRectPx: cropRectPx,
            annotations: annotations,
            scale: scale
        )
    }

    @Test func flattenSizeMatchesCropRect() {
        let base = PixelBuffer.solidImage(width: 100, height: 80, rects: [])
        let output = flatten(base, cropRectPx: CGRect(x: 10, y: 10, width: 30, height: 20))
        #expect(output?.width == 30)
        #expect(output?.height == 20)
    }

    // 无标注时与 ImageOutput.crop 逐字节一致，保证 P1 复制链路不回归
    @Test func flattenWithoutAnnotationsEqualsCrop() throws {
        let base = PixelBuffer.solidImage(width: 100, height: 80, rects: [])
        let cropRect = CGRect(x: 10, y: 12, width: 44, height: 30)
        let output = try #require(flatten(base, cropRectPx: cropRect))
        let expected = try #require(ImageOutput.crop(base, to: cropRect))
        let outputBytes = try #require(PixelBuffer.srgbBytes(output, width: 44, height: 30))
        let expectedBytes = try #require(PixelBuffer.srgbBytes(expected, width: 44, height: 30))
        #expect(outputBytes == expectedBytes)
    }

    // P3 底图导出沿用其色彩空间，不被强转 sRGB
    @Test func flattenKeepsDisplayP3ColorSpace() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let base = PixelBuffer.solidImage(
            width: 40, height: 40, colorSpace: p3,
            rects: [(CGRect(x: 0, y: 0, width: 40, height: 40), CGColor(colorSpace: p3, components: [1, 0, 0, 1])!)]
        )
        let output = try #require(flatten(base, cropRectPx: CGRect(x: 0, y: 0, width: 20, height: 20)))
        let outputSpace = try #require(output.colorSpace)
        #expect(outputSpace == p3)
    }

    // 画布上部矩形落在输出图像顶部：抓住导出侧 y 翻转
    @Test func flattenPlacesRectByCanvasOrientation() throws {
        // 底图左半蓝右半白（上下文左下原点画，x 不受翻转影响）
        let base = PixelBuffer.solidImage(
            width: 100, height: 100,
            rects: [(CGRect(x: 0, y: 0, width: 50, height: 100), PixelBuffer.rgb(0, 0, 1))]
        )
        let annotation = Annotation(
            shape: .rect(CGRect(x: 5, y: 35, width: 20, height: 10)),
            style: Style(color: red, pen: .p3)
        )
        let output = try #require(
            flatten(
                base,
                cropRectPx: CGRect(x: 0, y: 0, width: 100, height: 100),
                annotations: [annotation],
                scale: 2
            )
        )
        #expect(output.width == 100)
        #expect(output.height == 100)
        let bytes = try #require(PixelBuffer.srgbBytes(output, width: 100, height: 100))

        // 画布 y ∈ [35,45) × scale 2 → 像素 y' ∈ [70,90)，顶部行前 py = 99 - y' ∈ [10,30)
        let redInside = PixelBuffer.pixel(bytes, x: 20, y: 20, width: 100)
        #expect(redInside.r > 200 && redInside.g < 60 && redInside.b < 60)
        // 矩形外：底图蓝块与白底原样保留
        let blueLeft = PixelBuffer.pixel(bytes, x: 20, y: 60, width: 100)
        #expect(blueLeft.b > 200 && blueLeft.r < 60)
        let whiteRight = PixelBuffer.pixel(bytes, x: 80, y: 60, width: 100)
        #expect(whiteRight.r > 240 && whiteRight.g > 240 && whiteRight.b > 240)
        // 翻转错误会把红块送到底部
        let bottomProbe = PixelBuffer.pixel(bytes, x: 20, y: 80, width: 100)
        #expect(bottomProbe.b > 200 && bottomProbe.r < 60)
    }

    @Test func flattenRejectsInvalidCropRect() {
        let base = PixelBuffer.solidImage(width: 50, height: 50, rects: [])
        #expect(flatten(base, cropRectPx: CGRect(x: 60, y: 60, width: 10, height: 10)) == nil)
        #expect(flatten(base, cropRectPx: .zero) == nil)
    }

    // 导出链路 scale 一致性：scale 1 与 2 的输出归一化后逐字节一致
    @Test func flattenScaleOneMatchesScaleTwoNormalized() throws {
        let base = PixelBuffer.solidImage(width: 100, height: 100, rects: [])
        let annotation = Annotation(
            shape: .rect(CGRect(x: 10, y: 10, width: 20, height: 20)),
            style: Style(color: red, pen: .p3)
        )
        let scaleOne = try #require(
            flatten(
                base,
                cropRectPx: CGRect(x: 0, y: 0, width: 100, height: 100),
                annotations: [annotation],
                scale: 1
            )
        )
        // scale 2：选区 200x200 像素（底图放大一倍的等价区域），画布仍是 100 点
        let bigBase = PixelBuffer.solidImage(width: 200, height: 200, rects: [])
        let scaleTwo = try #require(
            flatten(
                bigBase,
                cropRectPx: CGRect(x: 0, y: 0, width: 200, height: 200),
                annotations: [annotation],
                scale: 2
            )
        )
        let oneBytes = try #require(PixelBuffer.srgbBytes(scaleOne, width: 100, height: 100))
        let twoBytesRaw = try #require(PixelBuffer.srgbBytes(scaleTwo, width: 200, height: 200))
        var twoBytes = [UInt8](repeating: 0, count: 100 * 100 * 4)
        for row in 0..<100 {
            for x in 0..<100 {
                let src = ((1 + row * 2) * 200 + x * 2) * 4
                let dst = (row * 100 + x) * 4
                for channel in 0..<4 {
                    twoBytes[dst + channel] = twoBytesRaw[src + channel]
                }
            }
        }
        #expect(oneBytes == twoBytes)
    }
}
