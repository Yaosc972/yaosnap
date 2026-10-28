import CoreGraphics

/// 把"抓到的帧"变成"拼好的长图"：估偏移 → 交给拼接器。
public final class ScrollCaptureEngine {
    private let stitcher: ScrollStitcher
    private let estimator: any ScrollOffsetEstimating
    private let minimumConfidence: Float
    private var previousFrame: CGImage?

    public init(
        stitcher: ScrollStitcher = ScrollStitcher(),
        estimator: any ScrollOffsetEstimating = VisionScrollOffsetEstimator(),
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
        return stitcher.start(first: first)
    }

    @discardableResult
    public func consume(frame: CGImage) -> ScrollStitchState? {
        guard let previous = previousFrame else {
            return start(first: frame)
        }
        guard let estimate = estimator.estimate(current: frame, previous: previous),
              estimate.confidence >= minimumConfidence else {
            return nil
        }
        let state = stitcher.ingest(frame: frame, offsetPx: estimate.offsetPx)
        if state?.changed == true {
            previousFrame = frame
        }
        return state
    }
}
