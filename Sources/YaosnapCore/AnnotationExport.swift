import CoreGraphics

/// 标注导出：底图裁剪 + 标注层合成最终图。
public enum AnnotationExport {
    /// cropRectPx 是冻结帧内像素矩形（原点在帧左上，y 向下）。
    /// 无标注时输出与 ImageOutput.crop 逐像素一致，保证 P1 复制链路不受影响。
    public static func flatten(
        base: CGImage,
        cropRectPx: CGRect,
        annotations: [Annotation],
        scale: CGFloat
    ) -> CGImage? {
        let cropRect = cropRectPx.integral.intersection(
            CGRect(x: 0, y: 0, width: base.width, height: base.height)
        )
        guard !cropRect.isNull, cropRect.width >= 1, cropRect.height >= 1 else { return nil }
        guard let cropped = ImageOutput.crop(base, to: cropRect) else { return nil }

        // 输出沿用底图色彩空间：冻结帧可能是 P3，默认 sRGB 会偏色。
        let colorSpace = base.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: Int(cropRect.width),
            height: Int(cropRect.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 先画裁剪后的底图，再以同一 RenderInput 走渲染器，与预览共用绘制代码。
        AnnotationRenderer.drawUpright(
            cropped,
            in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height),
            ctx: ctx
        )
        // 渲染器的约定是 ctx 坐标 = 画布点坐标；导出上下文是像素尺寸，缩放由这里负责。
        ctx.scaleBy(x: scale, y: scale)
        let input = RenderInput(
            base: base,
            cropOriginPx: CGPoint(x: cropRect.minX, y: cropRect.minY),
            canvasSize: CGSize(width: cropRect.width / scale, height: cropRect.height / scale),
            scale: scale
        )
        AnnotationRenderer.draw(annotations, draft: nil, input: input, into: ctx)
        return ctx.makeImage()
    }
}
