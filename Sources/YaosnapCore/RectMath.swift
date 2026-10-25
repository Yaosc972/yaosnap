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

    /// 按固定宽高比从拖拽起点向外扩展。位移较大的轴决定尺寸，另一轴按比例推出；
    /// 两边都不小于 minimumSide；放不下时等比缩小，缩到低于 minimumSide 返回 .zero。
    public static func aspectRect(
        from start: CGPoint,
        to end: CGPoint,
        ratio: CGFloat,
        within bounds: CGRect,
        minimumSide: CGFloat = 1
    ) -> CGRect {
        guard ratio > 0, ratio.isFinite else { return .zero }
        let minSide = max(0, minimumSide)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let xSign: CGFloat = dx >= 0 ? 1 : -1
        let ySign: CGFloat = dy >= 0 ? 1 : -1

        var width: CGFloat
        var height: CGFloat
        if abs(dx) >= abs(dy) {
            width = max(abs(dx), minSide, minSide * ratio)
            height = width / ratio
        } else {
            height = max(abs(dy), minSide, minSide / ratio)
            width = height * ratio
        }

        let availableX = xSign > 0 ? bounds.maxX - start.x : start.x - bounds.minX
        let availableY = ySign > 0 ? bounds.maxY - start.y : start.y - bounds.minY
        guard availableX > 0, availableY > 0 else { return .zero }
        let fit = min(1, availableX / width, availableY / height)
        width *= fit
        height *= fit
        guard width >= minSide, height >= minSide else { return .zero }

        return CGRect(
            x: xSign > 0 ? start.x : start.x - width,
            y: ySign > 0 ? start.y : start.y - height,
            width: width,
            height: height
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
    /// 给了 aspectRatio 时扩 / 缩保持该比例，平移不受影响。
    public static func nudge(
        _ rect: CGRect,
        direction: NudgeDirection,
        mode: NudgeMode,
        within bounds: CGRect,
        minimumSide: CGFloat = 1,
        aspectRatio: CGFloat? = nil
    ) -> CGRect {
        guard !rect.isEmpty else { return rect }
        if let ratio = aspectRatio, ratio > 0, ratio.isFinite, mode != .move {
            return aspectNudge(
                rect,
                direction: direction,
                mode: mode,
                ratio: ratio,
                within: bounds,
                minimumSide: minimumSide
            )
        }
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

    /// 保持宽高比的扩 / 缩。改动的那条边对面固定，另一轴居中，尺寸由比例推出；
    /// 最后只平移回 bounds，不改变尺寸。
    private static func aspectNudge(
        _ rect: CGRect,
        direction: NudgeDirection,
        mode: NudgeMode,
        ratio: CGFloat,
        within bounds: CGRect,
        minimumSide: CGFloat
    ) -> CGRect {
        let minSide = max(0, minimumSide)
        // 驱动轴的下限要反过来保证另一轴也够 minimumSide。
        let drivenMinimum = direction == .up || direction == .down
            ? max(minSide, minSide / ratio)
            : max(minSide, minSide * ratio)

        var size = rect.size
        switch direction {
        case .up, .down:
            let target = mode == .expand ? rect.height + 1 : rect.height - 1
            size.height = mode == .shrink ? max(drivenMinimum, target) : target
            size.width = size.height * ratio
        case .left, .right:
            let target = mode == .expand ? rect.width + 1 : rect.width - 1
            size.width = mode == .shrink ? max(drivenMinimum, target) : target
            size.height = size.width / ratio
        }
        guard size.width > 0, size.height > 0 else { return rect }
        // 竖直扩缩会带着宽度一起长，贴着屏幕边缘时可能超出 bounds，等比收回来。
        let fit = min(1, bounds.width / size.width, bounds.height / size.height)
        size.width *= fit
        size.height *= fit
        guard size.width >= minSide, size.height >= minSide else { return rect }

        var origin = rect.origin
        switch direction {
        case .up:
            origin.y = rect.minY
        case .down:
            origin.y = rect.maxY - size.height
        case .left:
            origin.x = rect.maxX - size.width
        case .right:
            origin.x = rect.minX
        }
        if direction == .up || direction == .down {
            origin.x = rect.midX - size.width / 2
        } else {
            origin.y = rect.midY - size.height / 2
        }

        origin.x = clampedOrigin(origin.x, side: size.width, lower: bounds.minX, upper: bounds.maxX)
        origin.y = clampedOrigin(origin.y, side: size.height, lower: bounds.minY, upper: bounds.maxY)
        return CGRect(origin: origin, size: size)
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
