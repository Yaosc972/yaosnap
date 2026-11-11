import CoreGraphics

public struct ScrollStitchState: Equatable {
    public let frameCount: Int
    public let changed: Bool
    public let reachedLimit: Bool

    public init(frameCount: Int, changed: Bool, reachedLimit: Bool) {
        self.frameCount = frameCount
        self.changed = changed
        self.reachedLimit = reachedLimit
    }
}

/// 把连续帧按垂直偏移拼成长图。像素坐标系，图像行 0 为顶部。
///
/// 两个方向都要支持：向下滚动时新内容从底部出现，拼到长图底部；
/// 向上滚动时新内容从顶部出现，拼到长图**顶部**。
/// 早期实现只做了向下追加、把向上滚动当成「反向」去裁剪，
/// 结果在聊天记录、代码这类「往上翻看更早内容」的场景里长图永远长不高。
public final class ScrollStitcher {
    public let maxHeightPx: Int
    public let deadZonePx: CGFloat

    public private(set) var image: CGImage?
    public private(set) var frameCount = 0

    public init(maxHeightPx: Int = 8_000, deadZonePx: CGFloat = 3) {
        self.maxHeightPx = maxHeightPx
        self.deadZonePx = deadZonePx
    }

    @discardableResult
    public func start(first: CGImage) -> ScrollStitchState {
        image = first
        frameCount = 1
        return ScrollStitchState(
            frameCount: frameCount,
            changed: true,
            reachedLimit: first.height >= maxHeightPx
        )
    }

    /// 裁掉长图顶部的固定条带（会话标题栏之类）。
    /// 首帧里必然带着它，若不裁掉，之后往前插的内容会把它挤到长图中间。
    @discardableResult
    public func trimTop(_ pixels: Int) -> Bool {
        guard let current = image, pixels > 0, current.height - pixels > 16 else { return false }
        guard let cropped = current.cropping(
            to: CGRect(x: 0, y: pixels, width: current.width, height: current.height - pixels)
        ) else { return false }
        image = cropped
        return true
    }

    /// 裁掉长图底部的固定条带（输入框之类）。
    @discardableResult
    public func trimBottom(_ pixels: Int) -> Bool {
        guard let current = image, pixels > 0, current.height - pixels > 16 else { return false }
        guard let cropped = current.cropping(
            to: CGRect(x: 0, y: 0, width: current.width, height: current.height - pixels)
        ) else { return false }
        image = cropped
        return true
    }

    /// - Parameters:
    ///   - offsetPx: 正数表示内容向下滚动（新内容从底部出现），负数表示内容向上滚动（新内容从顶部出现）。
    ///   - stickyBottomPx: 画面底部固定不动的条带高度（输入框、播放条），追加时剔除。
    ///   - stickyTopPx: 画面顶部固定不动的条带高度（标题栏、工具栏），前插时剔除。
    @discardableResult
    public func ingest(
        frame: CGImage,
        offsetPx: CGFloat,
        stickyBottomPx: Int = 0,
        stickyTopPx: Int = 0
    ) -> ScrollStitchState? {
        guard let current = image else {
            return start(first: frame)
        }
        guard frame.width == current.width else { return unchanged() }
        guard abs(offsetPx) > deadZonePx else { return unchanged() }

        let allowed = maxHeightPx - current.height
        guard allowed > 0 else {
            return ScrollStitchState(frameCount: frameCount, changed: false, reachedLimit: true)
        }

        if offsetPx > 0 {
            // 向下滚动：新露出的内容在画面底部（固定条带上方），拼到长图底部。
            let sticky = min(max(0, stickyBottomPx), frame.height / 3)
            let sourceBottom = max(1, frame.height - sticky)
            let append = min(Int(offsetPx.rounded()), sourceBottom)
            let take = min(append, allowed)
            guard take > 0,
                  let composed = Self.appendBottom(
                      base: current, strip: frame, stripHeightPx: take, sourceBottomPx: sourceBottom
                  ) else { return unchanged() }
            image = composed
            frameCount += 1
            return ScrollStitchState(
                frameCount: frameCount,
                changed: true,
                reachedLimit: composed.height >= maxHeightPx
            )
        }

        // 向上滚动：新露出的内容在画面顶部（固定条带下方），拼到长图顶部。
        let sticky = min(max(0, stickyTopPx), frame.height / 3)
        let sourceTop = sticky
        let prepend = min(Int((-offsetPx).rounded()), max(0, frame.height - sourceTop))
        let take = min(prepend, allowed)
        guard take > 0,
              let composed = Self.prependTop(
                  base: current, strip: frame, stripHeightPx: take, sourceTopPx: sourceTop
              ) else { return unchanged() }
        image = composed
        frameCount += 1
        return ScrollStitchState(
            frameCount: frameCount,
            changed: true,
            reachedLimit: composed.height >= maxHeightPx
        )
    }

    /// 片段布局约定：图像行 0 为顶部。
    /// CGContext 的 y=0 在底部，所以「顶部内容」要画在较大的 y 上。
    private static func makeContext(width: Int, height: Int, colorSpace: CGColorSpace?) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// 增量上下文（复用同一 CGContext、只绘制新增条带）未实现：每次追加都新建整高 CGContext
    /// 并重绘全部已有内容。默认上限压到 8000px，把单次追加的峰值控制在约 190MB。
    private static func appendBottom(
        base: CGImage,
        strip: CGImage,
        stripHeightPx: Int,
        sourceBottomPx: Int
    ) -> CGImage? {
        let width = base.width
        let height = base.height + stripHeightPx
        guard let ctx = makeContext(width: width, height: height, colorSpace: base.colorSpace) else {
            return nil
        }
        // 新露出的内容取自「固定条带上方」的 stripHeightPx 行。
        let sourceTop = max(0, sourceBottomPx - stripHeightPx)
        let sourceHeight = min(stripHeightPx, sourceBottomPx - sourceTop)
        guard sourceHeight > 0,
              let newStrip = strip.cropping(
                  to: CGRect(x: 0, y: sourceTop, width: strip.width, height: sourceHeight)
              ) else { return nil }

        AnnotationRenderer.drawUpright(
            base,
            in: CGRect(x: 0, y: stripHeightPx, width: width, height: base.height),
            ctx: ctx
        )
        AnnotationRenderer.drawUpright(
            newStrip,
            in: CGRect(x: 0, y: stripHeightPx - sourceHeight, width: width, height: sourceHeight),
            ctx: ctx
        )
        return ctx.makeImage()
    }

    /// 向上滚动时把新露出的顶部内容前插到长图顶部。
    private static func prependTop(
        base: CGImage,
        strip: CGImage,
        stripHeightPx: Int,
        sourceTopPx: Int
    ) -> CGImage? {
        let width = base.width
        let height = base.height + stripHeightPx
        guard let ctx = makeContext(width: width, height: height, colorSpace: base.colorSpace) else {
            return nil
        }
        let sourceHeight = min(stripHeightPx, max(0, strip.height - sourceTopPx))
        guard sourceHeight > 0,
              let newStrip = strip.cropping(
                  to: CGRect(x: 0, y: sourceTopPx, width: strip.width, height: sourceHeight)
              ) else { return nil }

        // 既有长图放底部，新条带放它上方（更靠近顶部）。
        AnnotationRenderer.drawUpright(
            base,
            in: CGRect(x: 0, y: 0, width: width, height: base.height),
            ctx: ctx
        )
        AnnotationRenderer.drawUpright(
            newStrip,
            in: CGRect(x: 0, y: base.height, width: width, height: sourceHeight),
            ctx: ctx
        )
        return ctx.makeImage()
    }

    private func unchanged() -> ScrollStitchState {
        ScrollStitchState(frameCount: frameCount, changed: false, reachedLimit: false)
    }
}