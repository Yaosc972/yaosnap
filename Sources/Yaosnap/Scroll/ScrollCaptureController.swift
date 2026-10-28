import AppKit
import YaosnapCore

/// 定时抓帧并喂给引擎。抓帧是 async 的，用一个 inFlight 标记防止重入。
///
/// engine（含 Vision 配准与拼接）只在 `workQueue` 上串行访问：
/// 抓帧留在主线程，consume 放到后台串行队列，结果回主线程回调，
/// 避免大选区下最多 6 次同步 Vision 配准把主线程占满、预览卡顿。
@MainActor
final class ScrollCaptureController {
    var onUpdate: ((CGImage, Int) -> Void)?
    var onFinish: ((CGImage) -> Void)?
    var onLimitReached: (() -> Void)?

    private let capturer: any ScrollFrameCapturing
    private let globalRect: CGRect
    private let interval: TimeInterval
    private let engine = ScrollCaptureEngine()
    /// engine 只由本队列串行访问（主线程仅捕获引用本身），不做并发保护。
    private let workQueue = DispatchQueue(label: "yaosnap.scroll.engine")
    private var timer: Timer?
    private var inFlight = false
    private var isRunning = false
    /// 上次回调预览图时的拼接高度（像素）。拼接每帧都重绘整张长图，
    /// 预览刷新按高度增长节流，避免每 0.25s 重建一次大图。
    private var lastReportedHeight = 0

    /// 预览图高度至少增长这么多像素才回调一次 onUpdate。
    private static let previewUpdateThresholdPx = 8

    init(capturer: any ScrollFrameCapturing, globalRect: CGRect, interval: TimeInterval = 0.25) {
        self.capturer = capturer
        self.globalRect = globalRect
        self.interval = interval
    }

    func start(firstFrame: CGImage) {
        // 防御重复 start：先清掉可能遗留的旧 timer。
        stopTimer()
        isRunning = true
        lastReportedHeight = 0
        let engine = self.engine
        _ = workQueue.sync { engine.start(first: firstFrame) }
        onUpdate?(firstFrame, 1)
        lastReportedHeight = firstFrame.height

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func finish() {
        stopTimer()
        isRunning = false
        // engine 只在 workQueue 上访问；sync 等待在途帧拼完再取整图。
        let image = workQueue.sync { engine.image }
        guard let image else { return }
        // 收尾始终给出完整长图，不受预览节流影响。
        onFinish?(image)
    }

    func cancel() {
        stopTimer()
        isRunning = false
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isRunning, !inFlight else { return }
        inFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard isRunning else { inFlight = false; return }
            guard let frame = await capturer.capture(globalRect: globalRect) else {
                inFlight = false
                return
            }
            // 抓帧期间可能已 finish()/cancel()：此时不能再喂引擎，
            // 否则会在取消后回调 onUpdate，甚至弹出"已达上限"提示。
            guard isRunning else { inFlight = false; return }
            let engine = self.engine
            workQueue.async { [weak self] in
                let state = engine.consume(frame: frame)
                let image = state?.changed == true ? engine.image : nil
                Task { @MainActor in
                    guard let self else { return }
                    self.inFlight = false
                    guard self.isRunning else { return }
                    if let state { self.handle(state, image: image) }
                }
            }
        }
    }

    /// 主线程消费拼接结果：刷新预览 / 处理到达上限。
    private func handle(_ state: ScrollStitchState, image: CGImage?) {
        if state.changed, let image {
            // 反向滚动裁剪会让拼接图变矮；先把基线降下来，并让缩短本身触发一次刷新，
            // 否则高度差为负，预览会一直卡住直到用户滚回旧的基线之上。
            let shrank = image.height < lastReportedHeight
            if shrank {
                lastReportedHeight = image.height
            }
            let shouldReport = lastReportedHeight == 0
                || shrank
                || image.height - lastReportedHeight >= Self.previewUpdateThresholdPx
            if shouldReport {
                lastReportedHeight = image.height
                onUpdate?(image, state.frameCount)
            }
        }
        if state.reachedLimit {
            stopTimer()
            isRunning = false
            onLimitReached?()
        }
    }
}
