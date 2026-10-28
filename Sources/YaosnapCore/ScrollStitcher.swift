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
public final class ScrollStitcher {
    public let maxHeightPx: Int
    public let deadZonePx: CGFloat

    public private(set) var image: CGImage?
    public private(set) var frameCount = 0

    /// 反向位移连续出现两次才裁剪，避免滚动惯性抖动误删内容。
    private var hasPendingReverse = false

    public init(maxHeightPx: Int = 20_000, deadZonePx: CGFloat = 3) {
        self.maxHeightPx = maxHeightPx
        self.deadZonePx = deadZonePx
    }

    @discardableResult
    public func start(first: CGImage) -> ScrollStitchState {
        image = first
        frameCount = 1
        hasPendingReverse = false
        return ScrollStitchState(frameCount: frameCount, changed: true, reachedLimit: first.height >= maxHeightPx)
    }

    @discardableResult
    public func ingest(frame: CGImage, offsetPx: CGFloat) -> ScrollStitchState? {
        guard let current = image else {
            return start(first: frame)
        }
        guard frame.width == current.width else {
            return ScrollStitchState(frameCount: frameCount, changed: false, reachedLimit: false)
        }

        if abs(offsetPx) <= deadZonePx {
            hasPendingReverse = false
            return ScrollStitchState(frameCount: frameCount, changed: false, reachedLimit: false)
        }

        if offsetPx > 0 {
            let append = min(Int(offsetPx.rounded()), frame.height)
            let allowed = maxHeightPx - current.height
            guard append > 0, allowed > 0 else {
                return ScrollStitchState(
                    frameCount: frameCount,
                    changed: false,
                    reachedLimit: allowed <= 0
                )
            }
            let take = min(append, allowed)
            guard let composed = Self.appendBottom(base: current, strip: frame, stripHeightPx: take) else {
                return ScrollStitchState(frameCount: frameCount, changed: false, reachedLimit: false)
            }
            image = composed
            frameCount += 1
            hasPendingReverse = false
            return ScrollStitchState(
                frameCount: frameCount,
                changed: true,
                reachedLimit: composed.height >= maxHeightPx
            )
        }

        guard hasPendingReverse else {
            hasPendingReverse = true
            return ScrollStitchState(frameCount: frameCount, changed: false, reachedLimit: false)
        }
        hasPendingReverse = false

        let crop = min(Int((-offsetPx).rounded()), current.height - 1)
        guard crop > 0 else {
            return ScrollStitchState(frameCount: frameCount, changed: false, reachedLimit: false)
        }
        guard let cropped = current.cropping(
            to: CGRect(x: 0, y: 0, width: current.width, height: current.height - crop)
        ) else {
            return ScrollStitchState(frameCount: frameCount, changed: false, reachedLimit: false)
        }
        image = cropped
        return ScrollStitchState(frameCount: frameCount, changed: true, reachedLimit: false)
    }

    private static func appendBottom(base: CGImage, strip: CGImage, stripHeightPx: Int) -> CGImage? {
        let width = base.width
        let height = base.height + stripHeightPx
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: base.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 新帧底部 stripHeightPx 行是新露出的内容，放在长图底部。
        guard let newStrip = strip.cropping(
            to: CGRect(x: 0, y: strip.height - stripHeightPx, width: strip.width, height: stripHeightPx)
        ) else { return nil }

        AnnotationRenderer.drawUpright(
            base,
            in: CGRect(x: 0, y: stripHeightPx, width: width, height: base.height),
            ctx: ctx
        )
        AnnotationRenderer.drawUpright(
            newStrip,
            in: CGRect(x: 0, y: 0, width: width, height: stripHeightPx),
            ctx: ctx
        )
        return ctx.makeImage()
    }
}
