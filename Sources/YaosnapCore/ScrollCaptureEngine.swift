import CoreGraphics

/// 把"抓到的帧"变成"拼好的长图"：估偏移 → 交给拼接器。
///
/// 关键设计：**位移相对"上一帧"累积，而不是每次都和"最后一个已拼接帧"比**。
/// 早期实现只保留已拼接帧做参考，一旦某一帧配准失败（运动模糊、页面重排），
/// 后续静止帧永远匹配不上那张旧参考，整条链路就彻底停住，长图再也长不高。
/// 现在两条腿走路：
/// 1. 正常情况下逐帧累积位移，累计到超过死区再交给拼接器；
/// 2. 一旦某一帧和上一帧失配，链路标记为不可信，改为直接与最后一个已拼接帧配准来重建同步。
public final class ScrollCaptureEngine {
    private let stitcher: ScrollStitcher
    private let estimator: any ScrollOffsetEstimating
    private let minimumConfidence: Float

    /// 上一帧：总是最新的一帧，用于逐帧累积。
    private var previousFrame: CGImage?
    /// 最后一个真正进入长图的帧，用于断链后重建同步。
    private var stitchedFrame: CGImage?
    /// 从 stitchedFrame 累积到 previousFrame 的位移。
    private var pendingOffset: CGFloat = 0
    private var pendingStickyPx = 0
    private var pendingStickyTopPx = 0
    /// 逐帧累积是否连续可信。出现失配后置为 false，必须靠直连重新建立。
    private var pendingTrusted = true

    public init(
        stitcher: ScrollStitcher = ScrollStitcher(),
        estimator: any ScrollOffsetEstimating = ScrollOffsetEstimator(),
        minimumConfidence: Float = 0.3
    ) {
        self.stitcher = stitcher
        self.estimator = estimator
        self.minimumConfidence = minimumConfidence
    }

    public var image: CGImage? { stitcher.image }
    public var frameCount: Int { stitcher.frameCount }

    @discardableResult
    public func start(first: CGImage) -> ScrollStitchState {
        previousFrame = first
        stitchedFrame = first
        pendingOffset = 0
        pendingStickyPx = 0
        pendingStickyTopPx = 0
        pendingTrusted = true
        return stitcher.start(first: first)
    }

    @discardableResult
    public func consume(frame: CGImage) -> ScrollStitchState? {
        guard let previous = previousFrame, let stitched = stitchedFrame else {
            return start(first: frame)
        }

        // 每帧只估一次「相对上一帧」的位移，后面两个分支复用。
        let step = trustedEstimate(current: frame, previous: previous)
        let isStatic = step.map { abs($0.offsetPx) <= stitcher.deadZonePx } ?? false

        // 1) 画面没动：既不累积也不拼接，但保持链路可信。
        if isStatic {
            previousFrame = frame
            return unchanged()
        }

        // 2) 连续可信：与上一帧配准，位移累积到"距最后一个已拼接帧"的总量。
        if pendingTrusted, let step {
            previousFrame = frame
            pendingOffset += step.offsetPx
            pendingStickyPx = step.stickyBottomPx
            pendingStickyTopPx = step.stickyTopPx
            let state = stitcher.ingest(
                frame: frame,
                offsetPx: pendingOffset,
                stickyBottomPx: pendingStickyPx,
                stickyTopPx: pendingStickyTopPx
            )
            if state?.changed == true {
                stitchedFrame = frame
                pendingOffset = 0
                pendingStickyPx = 0
                pendingStickyTopPx = 0
            }
            return state
        }

        // 3) 真正失配：先更新上一帧，再用宽窗口直接与最后一个已拼接帧配准，把长图接回去。
        //    注意：宽窗口搜索是常规搜索的近两倍开销，只在链路已断时用一次，不能每帧都跑。
        previousFrame = frame
        guard let direct = trustedEstimate(current: frame, previous: stitched, reconnect: true) else {
            pendingTrusted = false
            pendingOffset = 0
            pendingStickyPx = 0
            pendingStickyTopPx = 0
            return nil
        }
        pendingTrusted = true
        let state = stitcher.ingest(
            frame: frame,
            offsetPx: direct.offsetPx,
            stickyBottomPx: direct.stickyBottomPx,
            stickyTopPx: direct.stickyTopPx
        )
        pendingOffset = 0
        pendingStickyPx = 0
        pendingStickyTopPx = 0
        if state?.changed == true {
            stitchedFrame = frame
        }
        return state
    }

    private func trustedEstimate(
        current: CGImage,
        previous: CGImage,
        reconnect: Bool = false
    ) -> ScrollOffsetEstimate? {
        let estimate = reconnect
            ? estimator.estimateForReconnect(current: current, previous: previous)
            : estimator.estimate(current: current, previous: previous)
        guard let estimate, estimate.confidence >= minimumConfidence else { return nil }
        return estimate
    }

    private func unchanged() -> ScrollStitchState {
        ScrollStitchState(frameCount: stitcher.frameCount, changed: false, reachedLimit: false)
    }
}