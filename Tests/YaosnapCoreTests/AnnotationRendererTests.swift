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
            shape: .text("Hello", origin: CGPoint(x: 10, y: 25), fontSize: 24, rotation: 0),
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

    /// 指定底色的位图上下文，用来把背景填充和原底图区分开。
    private func rendered(
        width: Int,
        height: Int,
        base: RGBAColor,
        apply: (CGContext) -> Void
    ) -> [UInt8] {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(base.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        apply(ctx)
        return PixelBuffer.srgbBytes(ctx.makeImage()!, width: width, height: height)!
    }

    /// 文字带背景：外扩 2pt 内边距被背景色覆盖，笔画仍是文字色，内边距之外保持底图。
    @Test func textBackgroundFillsPaddingBand() {
        let side = 140
        let origin = CGPoint(x: 30, y: 90)
        let text = "Hello"
        let box = TextMetrics.multiline(text, fontSize: 24, origin: origin).rect
        let base = RGBAColor(r: 0.18, g: 0.42, b: 0.86)
        let annotation = Annotation(
            shape: .text(text, origin: origin, fontSize: 24, rotation: 0),
            style: Style(color: red, pen: .p3, background: RGBAColor(r: 1, g: 1, b: 1))
        )
        let bytes = rendered(width: side, height: side, base: base) { ctx in
            AnnotationRenderer.draw(
                [annotation], draft: nil,
                input: input(canvasSize: CGSize(width: side, height: side)),
                into: ctx
            )
        }
        let middle = Int(box.midY)
        // 文字左缘左侧 1pt 落在外扩区内，应为背景色。
        #expect(isWhite(at(bytes, x: Int(box.minX) - 1, cy: middle, canvasSide: side)))
        // 再往左越过外扩区，仍是底图蓝色。
        let outside = at(bytes, x: Int(box.minX) - 4, cy: middle, canvasSide: side)
        #expect(outside.b > 150 && !isWhite(outside))
        // 文字笔画保持标注色。
        #expect(redCount(bytes, side: side, canvasYRange: Int(box.minY)...Int(box.maxY)) > 0)
    }

    /// 文字无背景：同一采样点保持底图，说明旧行为不受影响。
    @Test func textWithoutBackgroundLeavesPaddingBandBase() {
        let side = 140
        let origin = CGPoint(x: 30, y: 90)
        let text = "Hello"
        let box = TextMetrics.multiline(text, fontSize: 24, origin: origin).rect
        let base = RGBAColor(r: 0.18, g: 0.42, b: 0.86)
        let annotation = Annotation(
            shape: .text(text, origin: origin, fontSize: 24, rotation: 0),
            style: Style(color: red, pen: .p3)
        )
        let bytes = rendered(width: side, height: side, base: base) { ctx in
            AnnotationRenderer.draw(
                [annotation], draft: nil,
                input: input(canvasSize: CGSize(width: side, height: side)),
                into: ctx
            )
        }
        let outside = at(bytes, x: Int(box.minX) - 1, cy: Int(box.midY), canvasSide: side)
        #expect(outside.b > 150 && !isWhite(outside))
    }

    @Test func multilineSecondLineDrawsAtItsBaseline() {
        let side = 200
        let origin = CGPoint(x: 10, y: 150)
        let text = "Hello\nWorld"
        let bytes = rendered(width: side, height: side) { ctx in
            AnnotationRenderer.draw(
                [Annotation(shape: .text(text, origin: origin, fontSize: 24, rotation: 0), style: Style(color: red, pen: .p3))],
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
                [Annotation(shape: .text(text, origin: origin, fontSize: fontSize, rotation: 0), style: Style(color: red, pen: .p3))],
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

    /// 同一条矩形只换线型：实线着色最多，虚线次之，点线最少。
    /// 线型只改 dash，不改任何其他绘制参数，所以三者的差异只来自着色覆盖率。
    @Test func dashStylesProduceDifferentInkDensity() {
        let side = 200
        func ink(_ lineStyle: LineStyle) -> Int {
            let annotation = Annotation(
                shape: .rect(CGRect(x: 30, y: 30, width: 140, height: 100)),
                style: Style(color: red, pen: .p3, lineStyle: lineStyle)
            )
            let bytes = rendered(width: side, height: side) { ctx in
                AnnotationRenderer.draw(
                    [annotation], draft: nil,
                    input: input(canvasSize: CGSize(width: side, height: side)),
                    into: ctx
                )
            }
            return redCount(bytes, side: side, canvasYRange: 0...(side - 1))
        }
        let solid = ink(.solid)
        let dashed = ink(.dashed)
        let dotted = ink(.dotted)
        #expect(solid > 0)
        #expect(Double(solid) > Double(dashed) * 1.2, "虚线应明显少于实线，实线 \(solid) 虚线 \(dashed)")
        #expect(dashed > dotted, "点线的着色像素应少于虚线，虚线 \(dashed) 点线 \(dotted)")
        #expect(dotted > 0)
    }

    /// 画笔不走描边路径，样式里的线型不能改变自由笔画的像素。
    @Test func lineStyleLeavesInkStrokeUnchanged() {
        let side = 120
        let points = [CGPoint(x: 20, y: 60), CGPoint(x: 60, y: 90), CGPoint(x: 100, y: 60)]
        func render(_ lineStyle: LineStyle) -> [UInt8] {
            let annotation = Annotation(
                shape: .brush(points),
                style: Style(color: red, pen: .p3, lineStyle: lineStyle)
            )
            return rendered(width: side, height: side) { ctx in
                AnnotationRenderer.draw(
                    [annotation], draft: nil,
                    input: input(canvasSize: CGSize(width: side, height: side)),
                    into: ctx
                )
            }
        }
        #expect(render(.solid) == render(.dotted))
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

    /// 两端带头独立：.end 只有终点三角，.start 只有起点三角，.both 两端都有。
    /// 采样点在头部底边附近、线体半宽之外，只有三角本身会覆盖那里。
    @Test func arrowHeadsSelectsWhichEndsGetHeads() {
        let side = 200
        let from = CGPoint(x: 40, y: 100), to = CGPoint(x: 160, y: 100)
        func render(_ heads: ArrowHeads) -> [UInt8] {
            let annotation = Annotation(
                shape: .arrow(from: from, to: to),
                style: Style(color: red, pen: .p3, arrowHeads: heads)
            )
            return rendered(width: side, height: side) { ctx in
                AnnotationRenderer.draw(
                    [annotation], draft: nil,
                    input: input(canvasSize: CGSize(width: side, height: side)),
                    into: ctx
                )
            }
        }
        // 线宽 5 → 头长 22.5、底边半宽 5.61；cy=103 在线体半宽 2.5 之外。
        func headInk(_ bytes: [UInt8], xRange: ClosedRange<Int>) -> Int {
            xRange.filter { isRed(at(bytes, x: $0, cy: 103, canvasSide: side)) }.count
        }
        let startBand = 58...62
        let endBand = 138...142

        let endOnly = render(.end)
        #expect(headInk(endOnly, xRange: endBand) > 0, ".end 终点应有三角头部")
        #expect(headInk(endOnly, xRange: startBand) == 0, ".end 起点不应有三角头部")

        let both = render(.both)
        #expect(headInk(both, xRange: startBand) > 0, ".both 起点应有三角头部")
        #expect(headInk(both, xRange: endBand) > 0, ".both 终点应有三角头部")
        #expect(isRed(at(both, x: 100, cy: 100, canvasSide: side)), ".both 线体仍连着两端")

        let startOnly = render(.start)
        #expect(headInk(startOnly, xRange: startBand) > 0, ".start 起点应有三角头部")
        #expect(headInk(startOnly, xRange: endBand) == 0, ".start 终点不应有三角头部")
    }

    /// 总长小于两端头长之和时只画头部，不构造反向或负长度的线体。
    @Test func shortArrowWithBothHeadsDrawsHeadsOnly() {
        let side = 200
        let annotation = Annotation(
            shape: .arrow(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 120, y: 100)),
            style: Style(color: red, pen: .p3, arrowHeads: .both)
        )
        let bytes = rendered(width: side, height: side) { ctx in
            AnnotationRenderer.draw(
                [annotation], draft: nil,
                input: input(canvasSize: CGSize(width: side, height: side)),
                into: ctx
            )
        }
        // 两个头部分别从尖端伸出 22.5，覆盖中段与两个尖端附近。
        #expect(isRed(at(bytes, x: 102, cy: 100, canvasSide: side)))
        #expect(isRed(at(bytes, x: 118, cy: 100, canvasSide: side)))
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

    @Test func magnifyShowsScaledCenterRegionWithBorder() {
        let side = 224
        // 8px 绿 / 8px 蓝竖条纹，周期 16px。
        let striped = PixelBuffer.solidImage(width: side, height: side, rects: stride(
            from: 0, to: side, by: 16
        ).flatMap { x in
            [
                (rect: CGRect(x: x, y: 0, width: 8, height: side), color: PixelBuffer.rgb(0, 1, 0)),
                (rect: CGRect(x: x + 8, y: 0, width: 8, height: side), color: PixelBuffer.rgb(0, 0, 1)),
            ]
        })
        // 镜框中心 (112, 112)，zoom 2 → 源区域 80..144，从绿条起点开始。
        let rect = CGRect(x: 48, y: 48, width: 128, height: 128)
        let annotation = Annotation(
            shape: .magnify(rect, zoom: 2),
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

        // 相邻绿/蓝跳变的间距：镜外是原始 8px，镜内放大后应为 16px。
        func edgeDeltas(_ range: ClosedRange<Int>, cy: Int) -> [Int] {
            var edges: [Int] = []
            var lastGreen: Bool?
            for x in range {
                let p = at(bytes, x: x, cy: cy, canvasSide: side)
                let green = p.g > 200 && p.b < 60
                let blue = p.b > 200 && p.g < 60
                guard green || blue else { continue }
                if let lastGreen, lastGreen != green { edges.append(x) }
                lastGreen = green
            }
            return zip(edges, edges.dropFirst()).map { $1 - $0 }
        }

        let outside = edgeDeltas(0...40, cy: 20)
        #expect(!outside.isEmpty, "镜外应能找到原始条纹")
        #expect(outside.allSatisfy { abs($0 - 8) <= 1 }, "镜外条纹保持原始周期: \(outside)")

        let inside = edgeDeltas(70...160, cy: 112)
        #expect(!inside.isEmpty, "镜内应能看到被放大的条纹")
        #expect(inside.allSatisfy { abs($0 - 16) <= 1 }, "镜内条纹周期应是原始的两倍: \(inside)")

        #expect(isRed(at(bytes, x: 50, cy: 112, canvasSide: side)), "镜框左边界应为描边色")
        #expect(!isRed(at(bytes, x: 112, cy: 112, canvasSide: side)), "镜面中心应是条纹而不是描边")
    }
}
