import CoreGraphics

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

    /// 视图矩形 → 冻结图（物理像素）矩形。scale 为屏 backingScaleFactor。
    public static func imageRect(
        fromViewRect viewRect: CGRect,
        viewHeight: CGFloat,
        scale: CGFloat
    ) -> CGRect {
        let flippedY = viewHeight - (viewRect.minY + viewRect.height)
        return CGRect(
            x: viewRect.minX * scale,
            y: flippedY * scale,
            width: viewRect.width * scale,
            height: viewRect.height * scale
        )
    }
}
