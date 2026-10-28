import CoreGraphics
import CoreText

/// 渲染一次标注所需的全部输入。base 是完整冻结帧；cropOriginPx 是选区左下角
/// 在帧内的像素位置（帧像素坐标原点在左上，y 向下）。
public struct RenderInput {
    public let base: CGImage
    public let cropOriginPx: CGPoint
    /// 画布尺寸，单位点。画布坐标原点 = 选区左下角。
    public let canvasSize: CGSize
    public let scale: CGFloat

    public init(base: CGImage, cropOriginPx: CGPoint, canvasSize: CGSize, scale: CGFloat) {
        self.base = base
        self.cropOriginPx = cropOriginPx
        self.canvasSize = canvasSize
        self.scale = scale
    }
}

/// 标注绘制。纯函数：同输入必然同输出，预览与导出共用这一个入口。
public enum AnnotationRenderer {
    /// 把 CGImage 正立画进左下原点上下文的 rect：CoreGraphics 会把图像顶行画在 rect.maxY 侧。
    /// 所有图像进上下文必须走这里，不要手写 translate/scale 翻转，那是预览与导出分叉的常见来源。
    static func drawUpright(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.draw(image, in: rect)
    }

    /// 把标注画进 ctx。约定 ctx 坐标 = 画布点坐标（原点选区左下，y 向上，单位点）：
    /// 预览侧画布 bounds 尺寸即画布点尺寸，天然成立；导出侧上下文是像素尺寸，
    /// 由 flatten 先 scaleBy(scale)。跨上下文的缩放不在渲染器内做，否则预览与导出分叉。
    public static func draw(
        _ items: [Annotation],
        draft: Annotation?,
        input: RenderInput,
        into ctx: CGContext
    ) {
        guard !items.isEmpty || draft != nil else { return }
        ctx.saveGState()
        // 画布裁剪：预览与导出用同一规则裁掉超出选区的部分。
        ctx.clip(to: CGRect(origin: .zero, size: input.canvasSize))
        // 马赛克放大处单独覆盖此设置；其余绘制关闭插值保证像素确定。
        ctx.interpolationQuality = .none
        for annotation in items {
            draw(annotation, input: input, in: ctx)
        }
        if let draft {
            draw(draft, input: input, in: ctx)
        }
        ctx.restoreGState()
    }

    private static func draw(_ annotation: Annotation, input: RenderInput, in ctx: CGContext) {
        let color = annotation.style.color
        let lineWidth = annotation.style.pen.lineWidth
        switch annotation.shape {
        case .rect(let rect):
            // 空心描边，线宽全部落在 rect 内侧，与 Snipaste 的矩形观感一致。
            // 直角是矩形观感的一部分：闭合形状 cap 不参与，join 必须保持 miter。
            stroke(ctx, color: color, lineWidth: lineWidth, join: .miter, lineStyle: annotation.style.lineStyle) {
                $0.addRect(rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
            }
        case .roundedRect(let rect, let radius):
            let inner = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            // 半径按内缩后短边钳制，超过半边长时 CGPath(roundedRect:) 行为未定义。
            guard inner.width > 0, inner.height > 0 else { break }
            let safeRadius = min(radius, min(inner.width, inner.height) / 2)
            stroke(ctx, color: color, lineWidth: lineWidth, lineStyle: annotation.style.lineStyle) {
                $0.addPath(CGPath(
                    roundedRect: inner,
                    cornerWidth: safeRadius,
                    cornerHeight: safeRadius,
                    transform: nil
                ))
            }
        case .ellipse(let rect):
            let inner = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            guard inner.width > 0, inner.height > 0 else { break }
            stroke(ctx, color: color, lineWidth: lineWidth, lineStyle: annotation.style.lineStyle) {
                $0.addEllipse(in: inner)
            }
        case .line(let from, let to):
            stroke(ctx, color: color, lineWidth: lineWidth, lineStyle: annotation.style.lineStyle) {
                $0.move(to: from)
                $0.addLine(to: to)
            }
        case .arrow(let from, let to):
            drawArrow(
                from: from, to: to,
                color: color,
                lineWidth: lineWidth,
                lineStyle: annotation.style.lineStyle,
                heads: annotation.style.arrowHeads,
                in: ctx
            )
        case .polyline(let points):
            drawPolyline(
                points,
                color: color,
                lineWidth: lineWidth,
                lineStyle: annotation.style.lineStyle,
                in: ctx
            )
        case .brush(let points):
            drawInkStroke(points, color: color, lineWidth: lineWidth, blend: .normal, in: ctx)
        case .marker(let points):
            // 荧光笔：multiply 模拟墨水叠进底色，半透明保留底图可读性。
            var markerColor = color
            markerColor.a = 0.45
            drawInkStroke(points, color: markerColor, lineWidth: lineWidth, blend: .multiply, in: ctx)
        case .mosaic(let points):
            drawMosaic(points, style: annotation.style, input: input, in: ctx)
        case .mosaicRect(let rect):
            drawMosaicRect(rect, style: annotation.style, input: input, in: ctx)
        case .blur(let points):
            drawBlur(points, style: annotation.style, input: input, in: ctx)
        case .magnify(let rect, let zoom):
            drawMagnify(rect, zoom: zoom, style: annotation.style, input: input, in: ctx)
        case .serial(let value, let center, let radius):
            drawSerial(value: value, center: center, radius: radius, color: color, in: ctx)
        case .text(let string, let origin, let fontSize, let rotation):
            guard !string.isEmpty else { break }
            let layout = TextMetrics.multiline(
                string,
                fontSize: fontSize,
                origin: origin,
                foreground: color.cgColor
            )
            ctx.setBlendMode(.normal)
            ctx.saveGState()
            if rotation != 0 {
                // 绕未旋转包围盒中心旋转；行基线仍是本地坐标，CTM 负责带它们转。
                let center = TextGeometry(rect: layout.rect, rotation: rotation).center
                ctx.translateBy(x: center.x, y: center.y)
                ctx.rotate(by: rotation)
                ctx.translateBy(x: -center.x, y: -center.y)
            }
            if let background = annotation.style.background {
                // 在 saveGState 之内绘制，文字旋转时背景随 CTM 一起转。
                ctx.setFillColor(background.cgColor)
                ctx.addPath(CGPath(
                    roundedRect: layout.rect.insetBy(dx: -2, dy: -2),
                    cornerWidth: 2, cornerHeight: 2, transform: nil
                ))
                ctx.fillPath()
            }
            // CTLine 以文本矩阵定位基线；画布上下文 y 向上，与 CoreText 约定一致。
            ctx.textMatrix = .identity
            for row in layout.lines {
                ctx.textPosition = row.baseline
                CTLineDraw(row.line, ctx)
            }
            ctx.restoreGState()
        }
    }

    /// 所有描边形状共用的设置：圆头、圆角连接。build 只负责构建路径。
    /// 矩形传 .miter 保持直角，其余形状用默认圆角连接。
    /// 线型每笔都显式设置：实线传空数组复位，避免上一笔的 dash 泄漏到这一笔。
    private static func stroke(
        _ ctx: CGContext,
        color: RGBAColor,
        lineWidth: CGFloat,
        blend: CGBlendMode = .normal,
        join: CGLineJoin = .round,
        lineStyle: LineStyle = .solid,
        build: (CGContext) -> Void
    ) {
        ctx.setBlendMode(blend)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(join)
        ctx.setLineDash(phase: 0, lengths: lineStyle.dashPattern(lineWidth: lineWidth) ?? [])
        build(ctx)
        ctx.strokePath()
    }

    /// 画笔/记号笔的点序列。选中点二次贝塞尔平滑：相邻段共用中点，观感平滑且点数不变。
    private static func drawInkStroke(
        _ points: [CGPoint],
        color: RGBAColor,
        lineWidth: CGFloat,
        blend: CGBlendMode,
        in ctx: CGContext
    ) {
        guard let first = points.first else { return }
        if points.count == 1 {
            // 零长度线段即使圆头也画不出来，单击落笔用填充圆呈现。
            fillDot(first, radius: lineWidth / 2, color: color, blend: blend, in: ctx)
            return
        }
        stroke(ctx, color: color, lineWidth: lineWidth, blend: blend) {
            addSmoothedPath(points, into: $0)
        }
    }

    private static func addSmoothedPath(_ points: [CGPoint], into ctx: CGContext) {
        guard let first = points.first, let last = points.last else { return }
        ctx.move(to: first)
        guard points.count > 2 else {
            ctx.addLine(to: last)
            return
        }
        for index in 1..<(points.count - 1) {
            let control = points[index]
            let mid = CGPoint(
                x: (control.x + points[index + 1].x) / 2,
                y: (control.y + points[index + 1].y) / 2
            )
            ctx.addQuadCurve(to: mid, control: control)
        }
        ctx.addLine(to: last)
    }

    private static func fillDot(
        _ center: CGPoint,
        radius: CGFloat,
        color: RGBAColor,
        blend: CGBlendMode,
        in ctx: CGContext
    ) {
        guard radius > 0 else { return }
        ctx.setBlendMode(blend)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        ))
    }

    /// 箭头 = 圆头直线 + 填充三角头部。头长 4.5 倍线宽、张角 28°。
    /// 线体两端按带头内缩到头部底边，避免圆头从三角下方露出。
    /// 线型只作用于线体，头部始终实心。
    private static func drawArrow(
        from: CGPoint,
        to: CGPoint,
        color: RGBAColor,
        lineWidth: CGFloat,
        lineStyle: LineStyle,
        heads: ArrowHeads,
        in ctx: CGContext
    ) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let headLength = lineWidth * 4.5
        let length = hypot(to.x - from.x, to.y - from.y)
        let startInset = heads.hasStart ? headLength : 0
        let endInset = heads.hasEnd ? headLength : 0

        // 总长不足两端头长之和时只画头部，不构造反向或负长度的线体。
        if length > startInset + endInset {
            let bodyStart = CGPoint(
                x: from.x + cos(angle) * startInset,
                y: from.y + sin(angle) * startInset
            )
            let bodyEnd = CGPoint(
                x: to.x - cos(angle) * endInset,
                y: to.y - sin(angle) * endInset
            )
            stroke(ctx, color: color, lineWidth: lineWidth, lineStyle: lineStyle) {
                $0.move(to: bodyStart)
                $0.addLine(to: bodyEnd)
            }
        }
        if heads.hasEnd {
            fillArrowHead(vertex: to, angle: angle, color: color, lineWidth: lineWidth, in: ctx)
        }
        if heads.hasStart {
            // 起点头从 to 指向 from，与线体方向相反。
            fillArrowHead(vertex: from, angle: angle + .pi, color: color, lineWidth: lineWidth, in: ctx)
        }
    }

    /// 一个实心三角头：vertex 是尖端，angle 是尖端朝向。
    private static func fillArrowHead(
        vertex: CGPoint,
        angle: CGFloat,
        color: RGBAColor,
        lineWidth: CGFloat,
        in ctx: CGContext
    ) {
        let headLength = lineWidth * 4.5
        let halfBase = headLength * tan(.pi * 14 / 180)
        let base = CGPoint(
            x: vertex.x - headLength * cos(angle),
            y: vertex.y - headLength * sin(angle)
        )
        let perpX = -sin(angle), perpY = cos(angle)

        ctx.setBlendMode(.normal)
        ctx.setFillColor(color.cgColor)
        ctx.beginPath()
        ctx.move(to: vertex)
        ctx.addLine(to: CGPoint(x: base.x + perpX * halfBase, y: base.y + perpY * halfBase))
        ctx.addLine(to: CGPoint(x: base.x - perpX * halfBase, y: base.y - perpY * halfBase))
        ctx.closePath()
        ctx.fillPath()
    }

    /// 折线：顶点间直连，圆头圆角连接。单点用填充圆，否则首次点按看不见落点。
    private static func drawPolyline(
        _ points: [CGPoint],
        color: RGBAColor,
        lineWidth: CGFloat,
        lineStyle: LineStyle,
        in ctx: CGContext
    ) {
        guard let first = points.first else { return }
        if points.count == 1 {
            fillDot(first, radius: lineWidth / 2, color: color, blend: .normal, in: ctx)
            return
        }
        stroke(ctx, color: color, lineWidth: lineWidth, lineStyle: lineStyle) {
            $0.move(to: first)
            for point in points.dropFirst() {
                $0.addLine(to: point)
            }
        }
    }

    /// 马赛克：采样源必须是 RenderInput.base（原始冻结帧），不是已画标注的合成结果。
    /// clip 用笔画路径的 3 倍线宽描边区域，块图只在该区域内可见。
    private static func drawMosaicRect(
        _ rect: CGRect,
        style: Style,
        input: RenderInput,
        in ctx: CGContext
    ) {
        guard rect.width > 0, rect.height > 0 else { return }
        let sampler = BaseSampler(
            base: input.base,
            cropOriginPx: input.cropOriginPx,
            canvasSize: input.canvasSize,
            scale: input.scale
        )
        guard let blocks = sampler.pixelated(
            region: rect,
            blockPoints: style.pen.mosaicBlock
        ) else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        drawUpright(blocks, in: rect, ctx: ctx)
        ctx.restoreGState()
    }

    private static func drawMosaic(
        _ points: [CGPoint],
        style: Style,
        input: RenderInput,
        in ctx: CGContext
    ) {
        guard !points.isEmpty else { return }
        let strokePoints = coveragePoints(points)
        let coverageWidth = style.pen.lineWidth * 3
        let region = Shape.mosaic(strokePoints).bounds
            .insetBy(dx: -coverageWidth / 2, dy: -coverageWidth / 2)
        let sampler = BaseSampler(
            base: input.base,
            cropOriginPx: input.cropOriginPx,
            canvasSize: input.canvasSize,
            scale: input.scale
        )
        guard let blocks = sampler.pixelated(region: region, blockPoints: style.pen.mosaicBlock) else { return }
        ctx.saveGState()
        clipToStroke(strokePoints, width: coverageWidth, in: ctx)
        // 块图的顶行对应 region 的画布 maxY，与 drawUpright 的摆放语义一致。
        drawUpright(blocks, in: region, ctx: ctx)
        ctx.restoreGState()
    }

    /// 模糊：与马赛克同构，采样源同为原始冻结帧，只把块化换成高斯模糊。
    private static func drawBlur(
        _ points: [CGPoint],
        style: Style,
        input: RenderInput,
        in ctx: CGContext
    ) {
        guard !points.isEmpty else { return }
        let strokePoints = coveragePoints(points)
        let coverageWidth = style.pen.lineWidth * 3
        let region = Shape.blur(strokePoints).bounds
            .insetBy(dx: -coverageWidth / 2, dy: -coverageWidth / 2)
        let sampler = BaseSampler(
            base: input.base,
            cropOriginPx: input.cropOriginPx,
            canvasSize: input.canvasSize,
            scale: input.scale
        )
        guard let blurred = sampler.blurred(region: region, radiusPoints: style.pen.blurRadius) else {
            return
        }
        ctx.saveGState()
        clipToStroke(strokePoints, width: coverageWidth, in: ctx)
        drawUpright(blurred, in: region, ctx: ctx)
        ctx.restoreGState()
    }

    /// 放大镜：取镜框中心 1/zoom 区域的冻结帧像素，重新铺满镜框。
    /// 采样源与马赛克一致，是原始冻结帧，已画标注不会进镜内。
    private static func drawMagnify(
        _ rect: CGRect,
        zoom: CGFloat,
        style: Style,
        input: RenderInput,
        in ctx: CGContext
    ) {
        guard rect.width > 0, rect.height > 0 else { return }
        let factor = max(1, zoom)
        let sampler = BaseSampler(
            base: input.base,
            cropOriginPx: input.cropOriginPx,
            canvasSize: input.canvasSize,
            scale: input.scale
        )
        let sourceWidth = rect.width / factor
        let sourceHeight = rect.height / factor
        let sourceRegion = CGRect(
            x: rect.midX - sourceWidth / 2,
            y: rect.midY - sourceHeight / 2,
            width: sourceWidth,
            height: sourceHeight
        )
        if let source = sampler.cropped(region: sourceRegion) {
            let corner = min(Self.magnifyCorner, min(rect.width, rect.height) / 2)
            ctx.saveGState()
            ctx.addPath(CGPath(
                roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil
            ))
            ctx.clip()
            drawUpright(source, in: rect, ctx: ctx)
            ctx.restoreGState()
        }

        let lineWidth = style.pen.lineWidth
        let inner = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        guard inner.width > 0, inner.height > 0 else { return }
        let innerCorner = min(Self.magnifyCorner, min(inner.width, inner.height) / 2)
        stroke(ctx, color: style.color, lineWidth: lineWidth, lineStyle: style.lineStyle) {
            $0.addPath(CGPath(
                roundedRect: inner, cornerWidth: innerCorner, cornerHeight: innerCorner, transform: nil
            ))
        }
    }

    private static let magnifyCorner: CGFloat = 4

    /// 实心圆加居中白字。数字按位数缩字号，两位数也不会溢出圆外。
    private static func drawSerial(
        value: Int,
        center: CGPoint,
        radius: CGFloat,
        color: RGBAColor,
        in ctx: CGContext
    ) {
        guard radius > 0 else { return }
        ctx.setBlendMode(.normal)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        ))

        let text = String(value)
        let baseSize = radius * 1.3
        let width = TextMetrics.boundingRect(text, fontSize: baseSize, origin: .zero).width
        let fontSize = width > radius * 1.5 ? baseSize * radius * 1.5 / width : baseSize
        let layout = TextMetrics.multiline(
            text,
            fontSize: fontSize,
            origin: TextMetrics.origin(text: text, fontSize: fontSize, centeredAt: center),
            foreground: RGBAColor(r: 1, g: 1, b: 1).cgColor
        )
        ctx.textMatrix = .identity
        for row in layout.lines {
            ctx.textPosition = row.baseline
            CTLineDraw(row.line, ctx)
        }
    }

    /// 零长度笔画构不成 clip 区域，微移成短线段后圆头即为圆点。
    private static func coveragePoints(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count == 1, let only = points.first else { return points }
        return [only, CGPoint(x: only.x + 0.5, y: only.y)]
    }

    /// 把当前裁剪区设为笔画路径的描边区域，采样效果只在笔迹内可见。
    private static func clipToStroke(_ points: [CGPoint], width: CGFloat, in ctx: CGContext) {
        ctx.beginPath()
        addSmoothedPath(points, into: ctx)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
    }
}
