import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import YaosnapCore

struct AnnotationRendererTests {
    private let white = RGBAColor(r: 1, g: 1, b: 1)
    private let red = RGBAColor(r: 1, g: 0, b: 0)

    /// 建白色底、RGBA8 的位图上下文，执行回调后返回顶部行在前的 sRGB 缓冲。
    private func rendered(
        width: Int,
        height: Int,
        apply: (CGContext) -> Void
    ) -> [UInt8] {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        apply(ctx)
        return PixelBuffer.srgbBytes(ctx.makeImage()!, width: width, height: height)!
    }

    private func isWhite(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        p.r > 240 && p.g > 240 && p.b > 240
    }

    private func isRed(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        p.r > 240 && p.g < 20 && p.b < 20
    }

    private func redCount(_ bytes: [UInt8], side: Int, canvasYRange: ClosedRange<Int>) -> Int {
        var count = 0
        for cy in canvasYRange where cy >= 0 && cy < side {
            for x in 0..<side where isRed(at(bytes, x: x, cy: cy, canvasSide: side)) {
                count += 1
            }
        }
        return count
    }

    private func input(canvasSize: CGSize, scale: CGFloat = 1) -> RenderInput {
        RenderInput(
            base: PixelBuffer.solidImage(width: 1, height: 1, rects: []),
            cropOriginPx: .zero,
            canvasSize: canvasSize,
            scale: scale
        )
    }

    @Test func emptyAnnotationsLeaveCanvasUntouched() {
        let bytes = rendered(width: 40, height: 30) { ctx in
            AnnotationRenderer.draw(
                [], draft: nil,
                input: input(canvasSize: CGSize(width: 40, height: 30)),
                into: ctx
            )
        }
        for pixelIndex in 0..<(40 * 30) {
            let offset = pixelIndex * 4
            #expect(bytes[offset] == 255 && bytes[offset + 1] == 255 && bytes[offset + 2] == 255)
        }
    }

    @Test func textDrawsVisiblePixels() {
        let width = 140, height = 70
        let annotation = Annotation(
            shape: .text("Hello", origin: CGPoint(x: 10, y: 25), fontSize: 24),
            style: Style(color: red, pen: .p3)
        )
        let bytes = rendered(width: width, height: height) { ctx in
            AnnotationRenderer.draw(
                [annotation], draft: nil,
                input: input(canvasSize: CGSize(width: width, height: height)),
                into: ctx
            )
        }
        var redPixels = 0
        for bufferRow in 0..<height {
            for x in 0..<width {
                if isRed(PixelBuffer.pixel(bytes, x: x, y: bufferRow, width: width)) {
                    redPixels += 1
                }
            }
        }
        #expect(redPixels > 0)
    }

    @Test func multilineSecondLineDrawsAtItsBaseline() {
        let side = 200
        let origin = CGPoint(x: 10, y: 150)
        let text = "Hello\nWorld"
        let bytes = rendered(width: side, height: side) { ctx in
            AnnotationRenderer.draw(
                [Annotation(shape: .text(text, origin: origin, fontSize: 24), style: Style(color: red, pen: .p3))],
                draft: nil,
                input: input(canvasSize: CGSize(width: side, height: side)),
                into: ctx
            )
        }
        let layout = TextMetrics.multiline(text, fontSize: 24, origin: origin)
        let firstBaseline = Int(layout.lines[0].baseline.y)
        let secondBaseline = Int(layout.lines[1].baseline.y)
        // 两条基线附近都有字形像素；若两行叠画在 origin，第二行位置会是空白
        #expect(redCount(bytes, side: side, canvasYRange: (firstBaseline + 2)...(firstBaseline + 10)) > 0)
        #expect(redCount(bytes, side: side, canvasYRange: (secondBaseline + 2)...(secondBaseline + 10)) > 0)
    }

    /// 中文行高来自 fallback 字体；包围盒必须盖住实际墨迹，且两行文字带不重叠。
    @Test func chineseMultilinePixelsStayInsideBounds() {
        let side = 200
        let text = "测试文字\n测试文字"
        let origin = CGPoint(x: 10, y: 150)
        let fontSize: CGFloat = 22
        let bytes = rendered(width: side, height: side) { ctx in
            AnnotationRenderer.draw(
                [Annotation(shape: .text(text, origin: origin, fontSize: fontSize), style: Style(color: red, pen: .p3))],
                draft: nil,
                input: input(canvasSize: CGSize(width: side, height: side)),
                into: ctx
            )
        }
        let layout = TextMetrics.multiline(text, fontSize: fontSize, origin: origin)
        var ascent0: CGFloat = 0
        var descent0: CGFloat = 0
        _ = CTLineGetTypographicBounds(layout.lines[0].line, &ascent0, &descent0, nil)
        #expect(layout.lines[0].baseline.y - layout.lines[1].baseline.y >= ascent0 + descent0 - 0.01)

        var minInk = side
        var maxInk = -1
        for cy in 0..<side {
            for x in 0..<side where isRed(at(bytes, x: x, cy: cy, canvasSide: side)) {
                minInk = min(minInk, cy)
                maxInk = max(maxInk, cy)
            }
        }
        #expect(maxInk >= 0)
        #expect(CGFloat(minInk) >= layout.rect.minY - 1)
        #expect(CGFloat(maxInk) <= layout.rect.maxY + 1)
        #expect(minInk < Int(layout.lines[1].baseline.y))
        #expect(maxInk > Int(layout.lines[0].baseline.y))
    }

    @Test func rectDrawnAtExpectedCanvasRegion() {
        let width = 100, height = 100
        let annotation = Annotation(
            shape: .rect(CGRect(x: 10, y: 10, width: 30, height: 20)),
            style: Style(color: red, pen: .p3)
        )
        let bytes = rendered(width: width, height: height) { ctx in
            AnnotationRenderer.draw(
                [annotation], draft: nil,
                input: input(canvasSize: CGSize(width: width, height: height)),
                into: ctx
            )
        }
        // 画布 y 向上；顶部行在前缓冲里画布 (x, cy) = 缓冲 (x, height-1-cy)
        // 矩形空心描边：边框上着色，内部保留底图
        #expect(isRed(PixelBuffer.pixel(bytes, x: 12, y: height - 1 - 20, width: width)))
        #expect(isRed(PixelBuffer.pixel(bytes, x: 25, y: height - 1 - 11, width: width)))
        #expect(isWhite(PixelBuffer.pixel(bytes, x: 25, y: height - 1 - 20, width: width)))
        #expect(isWhite(PixelBuffer.pixel(bytes, x: 5, y: height - 1 - 5, width: width)))
        #expect(isWhite(PixelBuffer.pixel(bytes, x: 50, y: height - 1 - 50, width: width)))
    }

    @Test func sameInputProducesIdenticalBytes() {
        let annotation = Annotation(
            shape: .rect(CGRect(x: 5, y: 5, width: 20, height: 15)),
            style: Style(color: red, pen: .p2)
        )
        let first = rendered(width: 60, height: 60) { ctx in
            AnnotationRenderer.draw(
                [annotation], draft: nil,
                input: input(canvasSize: CGSize(width: 60, height: 60)),
                into: ctx
            )
        }
        let second = rendered(width: 60, height: 60) { ctx in
            AnnotationRenderer.draw(
                [annotation], draft: nil,
                input: input(canvasSize: CGSize(width: 60, height: 60)),
                into: ctx
            )
        }
        #expect(first == second)
    }

    // 导出上下文按 flatten 的调用方式先 scaleBy(scale)：归一化后与 scale 1 逐字节一致
    @Test func scaledContextNormalizesToScaleOne() {
        let annotation = Annotation(
            shape: .rect(CGRect(x: 10, y: 10, width: 20, height: 20)),
            style: Style(color: red, pen: .p3)
        )
        let canvasSize = CGSize(width: 50, height: 50)
        let scaleOne = rendered(width: 50, height: 50) { ctx in
            AnnotationRenderer.draw(
                [annotation], draft: nil,
                input: input(canvasSize: canvasSize),
                into: ctx
            )
        }
        let scaleTwo = rendered(width: 100, height: 100) { ctx in
            ctx.scaleBy(x: 2, y: 2)
            AnnotationRenderer.draw(
                [annotation], draft: nil,
                input: input(canvasSize: canvasSize, scale: 2),
                into: ctx
            )
        }
        // scale 2 图按 2:1 点采样降到 scale 1（整数缩放无失真）
        var normalized = [UInt8](repeating: 0, count: 50 * 50 * 4)
        for row in 0..<50 {
            for x in 0..<50 {
                let src = ((1 + row * 2) * 100 + x * 2) * 4
                let dst = (row * 50 + x) * 4
                for channel in 0..<4 {
                    normalized[dst + channel] = scaleTwo[src + channel]
                }
            }
        }
        #expect(scaleOne == normalized)
    }

    // MARK: - 其余 7 种形状的关键像素特征

    /// 画布 (x, cy) → 顶部行在前缓冲的像素。cy 是画布 y（原点左下，向上）。
    private func at(_ bytes: [UInt8], x: Int, cy: Int, canvasSide: Int) -> (r: Int, g: Int, b: Int) {
        PixelBuffer.pixel(bytes, x: x, y: canvasSide - 1 - cy, width: canvasSide)
    }

    /// 不铺底图的透明画布，用来观察标注自身的 alpha。
    private func renderedTransparent(
        width: Int,
        height: Int,
        apply: (CGContext) -> Void
    ) -> [UInt8] {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        apply(ctx)
        return PixelBuffer.srgbBytes(ctx.makeImage()!, width: width, height: height)!
    }

    private func alphaAt(_ bytes: [UInt8], x: Int, cy: Int, canvasSide: Int) -> Int {
        let offset = ((canvasSide - 1 - cy) * canvasSide + x) * 4 + 3
        return Int(bytes[offset])
    }

    @Test func roundedRectClampsRadiusAndStrokesSides() {
        let side = 200
        // radius 40 超过内缩后短边一半，应被钳制而不是画出未定义形状
        let annotation = Annotation(
            shape: .roundedRect(CGRect(x: 30, y: 30, width: 120, height: 90), radius: 40),
            style: Style(color: red, pen: .p3)
        )
        let bytes = rendered(width: side, height: side) { ctx in
            AnnotationRenderer.draw([annotation], draft: nil, input: input(canvasSize: CGSize(width: side, height: side)), into: ctx)
        }
        // 底边中点描边着色，中心与直角外侧留白
        #expect(isRed(at(bytes, x: 90, cy: 32, canvasSide: side)))
        #expect(isWhite(at(bytes, x: 90, cy: 75, canvasSide: side)))
        // 圆角弧外：内缩矩形左下角 (32.5,32.5)，钳后半径 20，弧心 (52.5,52.5)
        #expect(isWhite(at(bytes, x: 35, cy: 35, canvasSide: side)))
    }

    @Test func ellipseCornersStayBaseAndMidlineColored() {
        let side = 200
        let annotation = Annotation(
            shape: .ellipse(CGRect(x: 40, y: 50, width: 120, height: 80)),
            style: Style(color: red, pen: .p3)
        )
        let bytes = rendered(width: side, height: side) { ctx in
            AnnotationRenderer.draw([annotation], draft: nil, input: input(canvasSize: CGSize(width: side, height: side)), into: ctx)
        }
        // 内缩椭圆中心 (100,90)，长短半轴 57.5/37.5
        #expect(isRed(at(bytes, x: 100, cy: 52, canvasSide: side)))
        #expect(isRed(at(bytes, x: 42, cy: 90, canvasSide: side)))
        #expect(isWhite(at(bytes, x: 100, cy: 90, canvasSide: side)))
        #expect(isWhite(at(bytes, x: 44, cy: 54, canvasSide: side)))
        #expect(isWhite(at(bytes, x: 156, cy: 126, canvasSide: side)))
    }

    @Test func lineStaysBetweenEndpoints() {
        let side = 200
        let annotation = Annotation(
            shape: .line(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 160, y: 160)),
            style: Style(color: red, pen: .p3)
        )
        let bytes = rendered(width: side, height: side) { ctx in
            AnnotationRenderer.draw([annotation], draft: nil, input: input(canvasSize: CGSize(width: side, height: side)), into: ctx)
        }
        #expect(isRed(at(bytes, x: 100, cy: 100, canvasSide: side)))
        // 中线外侧 7pt、端点外 8pt（圆头延伸仅 2.5pt）都应留白
        #expect(isWhite(at(bytes, x: 100, cy: 90, canvasSide: side)))
        #expect(isWhite(at(bytes, x: 168, cy: 168, canvasSide: side)))
    }

    @Test func polylineConnectsVerticesWithStraightSegments() {
        let side = 200
        let annotation = Annotation(
            shape: .polyline([
                CGPoint(x: 40, y: 40),
                CGPoint(x: 100, y: 100),
                CGPoint(x: 160, y: 40),
            ]),
            style: Style(color: red, pen: .p3)
        )
        let bytes = rendered(width: side, height: side) { ctx in
            AnnotationRenderer.draw([annotation], draft: nil, input: input(canvasSize: CGSize(width: side, height: side)), into: ctx)
        }
        // 两段直连的中点都着色，未经过的顶点上方留白
        #expect(isRed(at(bytes, x: 70, cy: 70, canvasSide: side)))
        #expect(isRed(at(bytes, x: 130, cy: 70, canvasSide: side)))
        #expect(isWhite(at(bytes, x: 100, cy: 40, canvasSide: side)))
    }

    @Test func translucentColorLowersDrawnAlpha() {
        let side = 100
        var translucentRed = red
        translucentRed.a = 0.4
        func alpha(for color: RGBAColor) -> Int {
            let annotation = Annotation(
                shape: .line(from: CGPoint(x: 20, y: 50), to: CGPoint(x: 80, y: 50)),
                style: Style(color: color, pen: .p5)
            )
            let bytes = renderedTransparent(width: side, height: side) { ctx in
                AnnotationRenderer.draw([annotation], draft: nil, input: input(canvasSize: CGSize(width: side, height: side)), into: ctx)
            }
            return alphaAt(bytes, x: 50, cy: 50, canvasSide: side)
        }
        let opaque = alpha(for: red)
        let faded = alpha(for: translucentRed)
        #expect(opaque > 250, "不透明颜色应画出不透明像素，实际 \(opaque)")
        #expect(faded < 160, "40% 透明度应明显降低 alpha，实际 \(faded)")
        #expect(faded > 40, "40% 透明度不应低到看不见，实际 \(faded)")
    }

    @Test func arrowHeadFillsTowardTip() {
        let side = 200
        let annotation = Annotation(
            shape: .arrow(from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 100)),
            style: Style(color: red, pen: .p3)
        )
        let bytes = rendered(width: side, height: side) { ctx in
            AnnotationRenderer.draw([annotation], draft: nil, input: input(canvasSize: CGSize(width: side, height: side)), into: ctx)
        }
        // 线宽 5 → 头长 22.5，头部底边 x=137.5；tip 与头部内部着色
        #expect(isRed(at(bytes, x: 155, cy: 100, canvasSide: side)))
        #expect(isRed(at(bytes, x: 148, cy: 100, canvasSide: side)))
        #expect(isRed(at(bytes, x: 80, cy: 100, canvasSide: side)))
        // 三角外、线体外留白
        #expect(isWhite(at(bytes, x: 150, cy: 112, canvasSide: side)))
    }

    @Test func brushFollowsPointSequence() {
        let side = 200
        let annotation = Annotation(
            shape: .brush([CGPoint(x: 60, y: 60), CGPoint(x: 100, y: 100), CGPoint(x: 140, y: 60)]),
            style: Style(color: red, pen: .p3)
        )
        let bytes = rendered(width: side, height: side) { ctx in
            AnnotationRenderer.draw([annotation], draft: nil, input: input(canvasSize: CGSize(width: side, height: side)), into: ctx)
        }
        // 中点二次贝塞尔 t=0.5 恰过 (P0+2C+P1)/4 = (95,85)
        #expect(isRed(at(bytes, x: 95, cy: 85, canvasSide: side)))
        #expect(isRed(at(bytes, x: 60, cy: 60, canvasSide: side)))
        #expect(isRed(at(bytes, x: 140, cy: 60, canvasSide: side)))
        #expect(isWhite(at(bytes, x: 100, cy: 60, canvasSide: side)))
    }

    @Test func markerIsTranslucentMultiply() {
        let side = 200
        let annotation = Annotation(
            shape: .marker([CGPoint(x: 60, y: 100), CGPoint(x: 140, y: 100)]),
            style: Style(color: red, pen: .p3)
        )
        let bytes = rendered(width: side, height: side) { ctx in
            AnnotationRenderer.draw([annotation], draft: nil, input: input(canvasSize: CGSize(width: side, height: side)), into: ctx)
        }
        // 白底 multiply 0.45 红 ≈ (255,140,140)：不是纯红也不是白
        let p = at(bytes, x: 100, cy: 100, canvasSide: side)
        #expect(p.r > 240 && p.g > 100 && p.g < 190 && p.b > 100 && p.b < 190)
    }

    @Test func brushSingleTapDrawsDot() {
        let side = 200
        let annotation = Annotation(
            shape: .brush([CGPoint(x: 100, y: 100)]),
            style: Style(color: red, pen: .p3)
        )
        let bytes = rendered(width: side, height: side) { ctx in
            AnnotationRenderer.draw([annotation], draft: nil, input: input(canvasSize: CGSize(width: side, height: side)), into: ctx)
        }
        #expect(isRed(at(bytes, x: 100, cy: 100, canvasSide: side)))
        #expect(isWhite(at(bytes, x: 100, cy: 110, canvasSide: side)))
    }

    @Test func mosaicQuantizesBasePixels() {
        let side = 200
        // 底图竖条纹（8px 红蓝交替）：量化后块色是红蓝均值
        let striped = PixelBuffer.solidImage(width: side, height: side, rects: stride(
            from: 0, to: side, by: 16
        ).flatMap { x in
            [
                (rect: CGRect(x: x, y: 0, width: 8, height: side), color: PixelBuffer.rgb(1, 0, 0)),
                (rect: CGRect(x: x + 8, y: 0, width: 8, height: side), color: PixelBuffer.rgb(0, 0, 1)),
            ]
        })
        let annotation = Annotation(
            shape: .mosaic([CGPoint(x: 40, y: 100), CGPoint(x: 160, y: 100)]),
            style: Style(color: red, pen: .p3)
        )
        let ctx = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        AnnotationRenderer.drawUpright(striped, in: CGRect(x: 0, y: 0, width: side, height: side), ctx: ctx)
        AnnotationRenderer.draw(
            [annotation], draft: nil,
            input: RenderInput(
                base: striped,
                cropOriginPx: .zero,
                canvasSize: CGSize(width: side, height: side),
                scale: 1
            ),
            into: ctx
        )
        let bytes = PixelBuffer.srgbBytes(ctx.makeImage()!, width: side, height: side)!

        // 块内均匀：同块两点颜色一致（原条纹处它们分属红蓝）
        let a = at(bytes, x: 60, cy: 100, canvasSide: side)
        let b = at(bytes, x: 62, cy: 100, canvasSide: side)
        #expect(a.r == b.r && a.g == b.g && a.b == b.b)
        // 块色是红蓝均值 ≈ (127,0,127)
        #expect(a.r > 90 && a.r < 170 && a.b > 90 && a.b < 170 && a.g < 40)
    }
}
