import CoreGraphics

/// 把"抓到的帧"变成"拼好的长图"：估偏移 → 交给拼接器。
///
/// 核心是**锚点链**：维护最近若干个「已经确定位置」的帧，新帧只要能跟其中任意一个配上，
/// 就能算出它相对长图底部的累计位移。
///
/// 早期实现只保留一个"上一帧/最后一个已拼接帧"，并且一旦某帧配准失败就把链路标记为不可信、
/// 之后只肯与最后一个已拼接帧比。结果是一帧失败就会连锁：内容早已滚远，旧帧永远配不上，
/// 整场只剩一张首帧（实机日志：19 帧都估出了正确位移，却没有一帧被拼进长图）。
/// 锚点链没有这个死结——跳过一两帧之后，新帧仍能和 4 个锚点里较近的那个配上，
/// 位移直接包含跳过的那几帧，不会丢失。
public final class ScrollCaptureEngine {
    /// 一个已知位置的参考帧。
    private struct Anchor {
        let frame: CGImage
        /// 该帧相对「当前长图底部」的累计位移。正数=内容向下滚动（新内容从底部出现）。
        let offsetFromBottom: CGFloat
    }

    /// 锚点最多留几个：太多会让搜索变慢，太少抗不住快速滚动。
    private static let maximumAnchors = 4

    private let stitcher: ScrollStitcher
    private let estimator: any ScrollOffsetEstimating
    private let minimumConfidence: Float
    private var anchors: [Anchor] = []

    /// 最近一次成功估计，仅供实机排查取证。
    public private(set) var lastEstimate: ScrollOffsetEstimate?
    /// 连续配准失败的帧数。上层据此提示"滚动太快"，但不会因此中断会话。
    public private(set) var consecutiveMisses = 0
    /// 固定头/固定尾的条带高度：它是页面属性，不是单帧属性。
    /// 单帧检测经常失手（顶部边框、悬停高亮会让边缘几行对不上），
    /// 所以按「整场取观测到的最大值」处理——只要有一帧测准，之后就一直生效。
    public private(set) var stickyTopPx = 0
    public private(set) var stickyBottomPx = 0
    /// 首帧里的固定条带只在拼第一帧之前裁掉一次；之后再裁就会切到真实内容。
    private var trimmedTop = false
    private var trimmedBottom = false

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
        anchors = [Anchor(frame: first, offsetFromBottom: 0)]
        consecutiveMisses = 0
        lastEstimate = nil
        stickyTopPx = 0
        stickyBottomPx = 0
        trimmedTop = false
        trimmedBottom = false
        return stitcher.start(first: first)
    }

    @discardableResult
    public func consume(frame: CGImage) -> ScrollStitchState? {
        guard !anchors.isEmpty else { return start(first: frame) }
        guard let match = matchAnchor(for: frame) else {
            consecutiveMisses += 1
            lastEstimate = nil
            return nil
        }
        consecutiveMisses = 0
        lastEstimate = match.estimate

        updateStickyBands(from: match.estimate, frameHeight: frame.height)
        applyPendingTrims()
        let total = match.anchor.offsetFromBottom + match.estimate.offsetPx
        // 静止帧：位置没变，只记锚点，不动长图。
        if abs(total) <= stitcher.deadZonePx {
            appendAnchor(frame, offsetFromBottom: total)
            return ScrollStitchState(
                frameCount: stitcher.frameCount,
                changed: false,
                reachedLimit: false
            )
        }

        let state = stitcher.ingest(
            frame: frame,
            offsetPx: total,
            stickyBottomPx: stickyBottomPx,
            stickyTopPx: stickyTopPx
        )
        if state?.changed == true {
            // 这一帧成了新的长图底部，所有历史锚点相对它的位移都要归零重算，直接丢掉更简单。
            anchors = [Anchor(frame: frame, offsetFromBottom: 0)]
        } else {
            appendAnchor(frame, offsetFromBottom: total)
        }
        return state
    }

    /// 从最近的锚点往回找：最近的先用常规窗口（快、严格），失败再放宽；
    /// 更老的锚点直接用宽窗口，因为跳过的帧越多位移越大。
    private func matchAnchor(
        for frame: CGImage
    ) -> (anchor: Anchor, estimate: ScrollOffsetEstimate)? {
        var found: (Anchor, ScrollOffsetEstimate)?
        for (index, anchor) in anchors.enumerated().reversed() {
            let isNewest = index == anchors.count - 1
            var estimate = isNewest ? estimator.estimate(current: frame, previous: anchor.frame) : nil
            if estimate == nil {
                estimate = estimator.estimateForReconnect(current: frame, previous: anchor.frame)
            }
            guard let estimate, estimate.confidence >= minimumConfidence else { continue }
            found = (anchor, estimate)
            break
        }
        return found.map { (anchor: $0.0, estimate: $0.1) }
    }

    /// 首帧本身就带着固定条带（会话标题栏、输入框）。不裁掉的话，
    /// 之后往顶部前插的内容会把它挤到长图中间——实机就是这样把标题栏拼进去的。
    /// 只在长图还是首帧时裁一次。
    private func applyPendingTrims() {
        guard stitcher.frameCount == 1 else { return }
        if !trimmedTop, stickyTopPx > 0, stitcher.trimTop(stickyTopPx) {
            trimmedTop = true
        }
        if !trimmedBottom, stickyBottomPx > 0, stitcher.trimBottom(stickyBottomPx) {
            trimmedBottom = true
        }
    }

    /// 只采信「画面确实动过」的观测，并且排除顶到上限的无效值（那是"整帧没动"的表现）。
    private func updateStickyBands(from estimate: ScrollOffsetEstimate, frameHeight: Int) {
        guard abs(estimate.offsetPx) > stitcher.deadZonePx else { return }
        let plausibleMaximum = frameHeight / 4
        if estimate.stickyTopPx > stickyTopPx, estimate.stickyTopPx <= plausibleMaximum {
            stickyTopPx = estimate.stickyTopPx
        }
        if estimate.stickyBottomPx > stickyBottomPx, estimate.stickyBottomPx <= plausibleMaximum {
            stickyBottomPx = estimate.stickyBottomPx
        }
    }

    private func appendAnchor(_ frame: CGImage, offsetFromBottom: CGFloat) {
        anchors.append(Anchor(frame: frame, offsetFromBottom: offsetFromBottom))
        if anchors.count > Self.maximumAnchors {
            anchors.removeFirst(anchors.count - Self.maximumAnchors)
        }
    }
}