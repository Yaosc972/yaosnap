import CoreGraphics

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
            stroke(ctx, color: color, lineWidth: lineWidth, join: .miter) {
                $0.addRect(rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
            }
        case .roundedRect(let rect, let radius):
            let inner = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            // 半径按内缩后短边钳制，超过半边长时 CGPath(roundedRect:) 行为未定义。
            guard inner.width > 0, inner.height > 0 else { break }
            let safeRadius = min(radius, min(inner.width, inner.height) / 2)
            stroke(ctx, color: color, lineWidth: lineWidth) {
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
            stroke(ctx, color: color, lineWidth: lineWidth) {
                $0.addEllipse(in: inner)
            }
        case .line(let from, let to):
            stroke(ctx, color: color, lineWidth: lineWidth) {
                $0.move(to: from)
                $0.addLine(to: to)
            }
        case .arrow(let from, let to):
            drawArrow(from: from, to: to, color: color, lineWidth: lineWidth, in: ctx)
        case .brush(let points):
            drawInkStroke(points, color: color, lineWidth: lineWidth, blend: .normal, in: ctx)
        case .marker(let points):
            // 荧光笔：multiply 模拟墨水叠进底色，半透明保留底图可读性。
            var markerColor = color
            markerColor.a = 0.45
            drawInkStroke(points, color: markerColor, lineWidth: lineWidth, blend: .multiply, in: ctx)
        case .mosaic(let points):
            drawMosaic(points, style: annotation.style, input: input, in: ctx)
        }
    }

    /// 所有描边形状共用的设置：圆头、圆角连接。build 只负责构建路径。
    /// 矩形传 .miter 保持直角，其余形状用默认圆角连接。
    private static func stroke(
        _ ctx: CGContext,
        color: RGBAColor,
        lineWidth: CGFloat,
        blend: CGBlendMode = .normal,
        join: CGLineJoin = .round,
        build: (CGContext) -> Void
    ) {
        ctx.setBlendMode(blend)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(join)
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

    /// 箭头 = 圆头直线 + 填充三角头部。头长 4.5 倍线宽、张角 28°，
    /// 线体画到头部底边为止，避免圆头从三角下方露出。
    private static func drawArrow(
        from: CGPoint,
        to: CGPoint,
        color: RGBAColor,
        lineWidth: CGFloat,
        in ctx: CGContext
    ) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let headLength = lineWidth * 4.5
        let halfBase = headLength * tan(.pi * 14 / 180)
        let base = CGPoint(x: to.x - headLength * cos(angle), y: to.y - headLength * sin(angle))
        let perpX = -sin(angle), perpY = cos(angle)

        if hypot(to.x - from.x, to.y - from.y) > headLength {
            stroke(ctx, color: color, lineWidth: lineWidth) {
                $0.move(to: from)
                $0.addLine(to: base)
            }
        }
        ctx.setBlendMode(.normal)
        ctx.setFillColor(color.cgColor)
        ctx.beginPath()
        ctx.move(to: to)
        ctx.addLine(to: CGPoint(x: base.x + perpX * halfBase, y: base.y + perpY * halfBase))
        ctx.addLine(to: CGPoint(x: base.x - perpX * halfBase, y: base.y - perpY * halfBase))
        ctx.closePath()
        ctx.fillPath()
    }

    /// 马赛克：采样源必须是 RenderInput.base（原始冻结帧），不是已画标注的合成结果。
    /// clip 用笔画路径的 3 倍线宽描边区域，块图只在该区域内可见。
    private static func drawMosaic(
        _ points: [CGPoint],
        style: Style,
        input: RenderInput,
        in ctx: CGContext
    ) {
        guard !points.isEmpty else { return }
        // 零长度笔画构不成 clip 区域，微移成短线段后圆头即为圆点。
        var strokePoints = points
        if strokePoints.count == 1, let only = strokePoints.first {
            strokePoints.append(CGPoint(x: only.x + 0.5, y: only.y))
        }
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
        ctx.beginPath()
        addSmoothedPath(strokePoints, into: ctx)
        ctx.setLineWidth(coverageWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        // 块图的顶行对应 region 的画布 maxY，与 drawUpright 的摆放语义一致。
        drawUpright(blocks, in: region, ctx: ctx)
        ctx.restoreGState()
    }
}
