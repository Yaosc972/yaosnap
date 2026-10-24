import CoreGraphics
import Foundation
import Testing
@testable import YaosnapCore

struct SerialBlurEraserTests {
    private let red = RGBAColor(r: 1, g: 0, b: 0)

    private func render(base: CGImage, side: Int, annotations: [Annotation]) -> [UInt8] {
        let ctx = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        AnnotationRenderer.drawUpright(
            base,
            in: CGRect(x: 0, y: 0, width: side, height: side),
            ctx: ctx
        )
        AnnotationRenderer.draw(
            annotations,
            draft: nil,
            input: RenderInput(
                base: base,
                cropOriginPx: .zero,
                canvasSize: CGSize(width: side, height: side),
                scale: 1
            ),
            into: ctx
        )
        return PixelBuffer.srgbBytes(ctx.makeImage()!, width: side, height: side)!
    }

    private func pixel(
        _ bytes: [UInt8], x: Int, canvasY: Int, side: Int
    ) -> (r: Int, g: Int, b: Int) {
        PixelBuffer.pixel(bytes, x: x, y: side - 1 - canvasY, width: side)
    }

    private func variance(
        _ bytes: [UInt8], xRange: ClosedRange<Int>, canvasYRange: ClosedRange<Int>, side: Int
    ) -> Double {
        var values: [Double] = []
        for canvasY in canvasYRange where canvasY >= 0 && canvasY < side {
            for x in xRange where x >= 0 && x < side {
                let p = pixel(bytes, x: x, canvasY: canvasY, side: side)
                values.append(Double(p.r + p.g + p.b) / 3)
            }
        }
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    }

    @Test func serialBoundsAndDrawsAnnotationColor() {
        let shape = Shape.serial(value: 1, center: CGPoint(x: 60, y: 70), radius: 20)
        #expect(shape.bounds == CGRect(x: 40, y: 50, width: 40, height: 40))
        #expect(shape.kind == .serial)

        let side = 120
        let base = PixelBuffer.solidImage(width: side, height: side, rects: [])
        let bytes = render(base: base, side: side, annotations: [
            Annotation(shape: shape, style: Style(color: red, pen: .p3)),
        ])

        // 圆环上的标注色，避开展示数字的圆心区域。
        let ring = pixel(bytes, x: 75, canvasY: 70, side: side)
        #expect(ring.r > 240 && ring.g < 30 && ring.b < 30)

        // 圆内出现的白色只可能来自数字，底图白被实心圆盖住。
        var whiteInsideCircle = 0
        for canvasY in 52...88 {
            for x in 42...78 {
                guard hypot(CGFloat(x) - 60, CGFloat(canvasY) - 70) < 18 else { continue }
                let p = pixel(bytes, x: x, canvasY: canvasY, side: side)
                if p.r > 240 && p.g > 240 && p.b > 240 { whiteInsideCircle += 1 }
            }
        }
        #expect(whiteInsideCircle > 0)

        // 圆外仍是底图白。
        let outside = pixel(bytes, x: 90, canvasY: 70, side: side)
        #expect(outside.r > 240 && outside.g > 240 && outside.b > 240)
    }

    @Test func blurSmoothsInsideAndLeavesOutsideUntouched() {
        let side = 200
        // 1px 黑白横条纹：模糊前局部方差大，模糊后趋近平滑。
        let striped = PixelBuffer.solidImage(width: side, height: side, rects: (0..<side).map { y in
            (
                rect: CGRect(x: 0, y: y, width: side, height: 1),
                color: y % 2 == 0 ? PixelBuffer.rgb(0, 0, 0) : PixelBuffer.rgb(1, 1, 1)
            )
        })
        let annotation = Annotation(
            shape: .blur([CGPoint(x: 30, y: 100), CGPoint(x: 170, y: 100)]),
            style: Style(color: red, pen: .p3)
        )

        let before = render(base: striped, side: side, annotations: [])
        let after = render(base: striped, side: side, annotations: [annotation])

        let beforeVariance = variance(before, xRange: 90...110, canvasYRange: 95...105, side: side)
        let afterVariance = variance(after, xRange: 90...110, canvasYRange: 95...105, side: side)
        #expect(beforeVariance > 1000)
        #expect(afterVariance < beforeVariance * 0.25)

        // 笔迹区域内确实有像素被改写。
        var changed = 0
        for canvasY in 94...106 {
            for x in 80...120 where
                pixel(before, x: x, canvasY: canvasY, side: side) != pixel(after, x: x, canvasY: canvasY, side: side)
            {
                changed += 1
            }
        }
        #expect(changed > 0)

        // 笔迹区域外与底图逐像素一致（clip 之外的模糊结果不可见）。
        for canvasY in 0..<side where canvasY <= 88 || canvasY >= 112 {
            for x in 0..<side {
                let expected = pixel(before, x: x, canvasY: canvasY, side: side)
                let actual = pixel(after, x: x, canvasY: canvasY, side: side)
                #expect(actual == expected, "区域外像素 (x=\(x), y=\(canvasY)) 不应变化")
            }
        }
    }

    @Test func eraserPathHitsOnlyCrossedAnnotation() {
        let crossed = Shape.rect(CGRect(x: 20, y: 20, width: 80, height: 60))
        let untouched = Shape.rect(CGRect(x: 160, y: 20, width: 80, height: 60))
        let path = [CGPoint(x: 0, y: 50), CGPoint(x: 120, y: 50)]
        #expect(crossed.intersects(path: path, tolerance: 3))
        #expect(!untouched.intersects(path: path, tolerance: 3))

        // 线状标注按到路径的距离判断。
        let line = Shape.line(from: CGPoint(x: 40, y: 10), to: CGPoint(x: 40, y: 90))
        #expect(line.intersects(
            path: [CGPoint(x: 10, y: 60), CGPoint(x: 70, y: 60)],
            tolerance: 2
        ))
        #expect(!line.intersects(
            path: [CGPoint(x: 10, y: 110), CGPoint(x: 70, y: 110)],
            tolerance: 2
        ))

        // 从包围盒下方掠过且超出容差时不命中。
        #expect(!crossed.intersects(
            path: [CGPoint(x: 0, y: 10), CGPoint(x: 120, y: 10)],
            tolerance: 2
        ))
    }
}
