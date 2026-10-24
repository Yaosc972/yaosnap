import CoreGraphics

/// 方向键微调选区的方向（视图坐标，y 向上）。
public enum NudgeDirection {
    case up, down, left, right
}

/// 方向键微调选区的方式：整体平移 / 向该方向扩大 / 向该方向缩小。
public enum NudgeMode {
    case move, expand, shrink
}

/// 坐标转换与选区数学。约定：
/// - CG 全局坐标：主屏左上原点，y 向下（CGDisplayBounds / CGWindowList 返回值）
/// - AppKit 视图坐标：左下原点，y 向上
public enum RectMath {
    /// 拖拽起止点（任意方向）→ 归一化正矩形
    public static func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    /// 裁剪到边界内；完全不相交时返回 .zero
    public static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let clipped = rect.intersection(bounds)
        return clipped.isNull ? .zero : clipped
    }

    /// CG 全局坐标 → 某屏覆盖窗口内的视图坐标
    public static func toViewRect(
        globalRect: CGRect,
        displayBounds: CGRect,
        viewHeight: CGFloat
    ) -> CGRect {
        let localX = globalRect.minX - displayBounds.minX
        let localYTop = globalRect.minY - displayBounds.minY
        let flippedY = viewHeight - (localYTop + globalRect.height)
        return CGRect(x: localX, y: flippedY, width: globalRect.width, height: globalRect.height)
    }

    /// 某屏覆盖窗口内的视图坐标 → CG 全局坐标（toViewRect 的逆变换）
    public static func toGlobalRect(
        viewRect: CGRect,
        displayBounds: CGRect,
        viewHeight: CGFloat
    ) -> CGRect {
        let globalX = viewRect.minX + displayBounds.minX
        let globalY = displayBounds.minY + (viewHeight - (viewRect.minY + viewRect.height))
        return CGRect(x: globalX, y: globalY, width: viewRect.width, height: viewRect.height)
    }

    /// 视图坐标点 → CG 全局坐标（toViewRect 的逆变换，按左下原点翻转 y）
    public static func toGlobalPoint(
        viewPoint: CGPoint,
        displayBounds: CGRect,
        viewHeight: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: displayBounds.minX + viewPoint.x,
            y: displayBounds.minY + (viewHeight - viewPoint.y)
        )
    }

    /// 视图矩形 → 冻结图（物理像素）矩形。scale 为屏 backingScaleFactor。
    public static func imageRect(
        fromViewRect viewRect: CGRect,
        viewHeight: CGFloat,
        scale: CGFloat
    ) -> CGRect {
        imageRect(fromViewRect: viewRect, viewHeight: viewHeight, scaleX: scale, scaleY: scale)
    }

    /// 宽高缩放不同的情形（回放历史截图时，图像尺寸与原屏显示尺寸未必等比）。
    public static func imageRect(
        fromViewRect viewRect: CGRect,
        viewHeight: CGFloat,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) -> CGRect {
        let flippedY = viewHeight - (viewRect.minY + viewRect.height)
        return CGRect(
            x: viewRect.minX * scaleX,
            y: flippedY * scaleY,
            width: viewRect.width * scaleX,
            height: viewRect.height * scaleY
        )
    }

    /// 方向键微调：平移 1pt，或向指定方向扩 / 缩 1pt。
    /// 结果始终落在 bounds 内，缩小时两边都不小于 minimumSide。
    public static func nudge(
        _ rect: CGRect,
        direction: NudgeDirection,
        mode: NudgeMode,
        within bounds: CGRect,
        minimumSide: CGFloat = 1
    ) -> CGRect {
        guard !rect.isEmpty else { return rect }
        var result = rect
        switch mode {
        case .move:
            switch direction {
            case .up: result.origin.y += 1
            case .down: result.origin.y -= 1
            case .left: result.origin.x -= 1
            case .right: result.origin.x += 1
            }
            result.origin.x = clampedOrigin(
                result.minX, side: result.width, lower: bounds.minX, upper: bounds.maxX
            )
            result.origin.y = clampedOrigin(
                result.minY, side: result.height, lower: bounds.minY, upper: bounds.maxY
            )
        case .expand:
            switch direction {
            case .up:
                result.size.height = min(bounds.maxY, result.maxY + 1) - result.minY
            case .down:
                let minY = max(bounds.minY, result.minY - 1)
                result.size.height = result.maxY - minY
                result.origin.y = minY
            case .left:
                let minX = max(bounds.minX, result.minX - 1)
                result.size.width = result.maxX - minX
                result.origin.x = minX
            case .right:
                result.size.width = min(bounds.maxX, result.maxX + 1) - result.minX
            }
        case .shrink:
            let minSide = max(0, minimumSide)
            switch direction {
            case .up:
                result.size.height = max(minSide, result.height - 1)
            case .down:
                let maxY = result.maxY
                let minY = min(result.minY + 1, maxY - minSide)
                result.origin.y = minY
                result.size.height = maxY - minY
            case .left:
                let maxX = result.maxX
                let minX = min(result.minX + 1, maxX - minSide)
                result.origin.x = minX
                result.size.width = maxX - minX
            case .right:
                result.size.width = max(minSide, result.width - 1)
            }
        }
        return result
    }

    private static func clampedOrigin(
        _ value: CGFloat,
        side: CGFloat,
        lower: CGFloat,
        upper: CGFloat
    ) -> CGFloat {
        let maxOrigin = upper - side
        guard maxOrigin >= lower else { return lower }
        return min(max(value, lower), maxOrigin)
    }
}
