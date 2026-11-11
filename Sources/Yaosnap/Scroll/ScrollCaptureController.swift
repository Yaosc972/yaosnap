import AppKit
import YaosnapCore

/// 定时抓帧并喂给引擎。抓帧是 async 的，用一个 inFlight 标记防止重入。
///
/// engine（含 Vision 配准与拼接）只在 `workQueue` 上串行访问：
/// 抓帧交给 ScreenScrollFrameCapturer 这个 actor（不占主线程，也不参与主 actor 的 XPC 等待），
/// consume 放到后台串行队列，结果回主线程回调，避免大选区下最多 6 次同步 Vision 配准把主线程占满。
@MainActor
final class ScrollCaptureController {
    var onUpdate: ((CGImage, Int) -> Void)?
    var onFinish: ((CGImage) -> Void)?
    var onLimitReached: (() -> Void)?
    /// 抓帧持续超时（连续三次超过 1 秒）时回调，调用方负责提示并收尾。
    var onStalled: (() -> Void)?
    /// 连续漏帧过多时回调（滚动太快，配准跟不上）。不中断会话，只是提示。
    var onFramesMissed: (() -> Void)?

    private let capturer: any ScrollFrameCapturing
    private let globalRect: CGRect
    private let interval: TimeInterval
    private let engine = ScrollCaptureEngine()
    /// engine 只由本队列串行访问（主线程仅捕获引用本身），不做并发保护。
    private let workQueue = DispatchQueue(label: "yaosnap.scroll.engine")
    private var timer: Timer?
    private var inFlight = false
    private var isRunning = false
    /// 连续慢抓帧计数：抓帧一旦拖住主线程，用户会先感到整机卡顿，而不是预览变慢。
    private var slowCaptureCount = 0
    private var nilCaptureCount = 0
    /// 上次回调预览图时的拼接高度（像素）。拼接每帧都重绘整张长图，
    /// 预览刷新按高度增长节流，避免每 0.15s 重建一次大图。
    private var lastReportedHeight = 0

    /// 连续漏这么多帧就提示一次「滚动太快」。
    private static let missedFrameHintThreshold = 8

    /// 预览图高度至少增长这么多像素才回调一次 onUpdate。
    private static let previewUpdateThresholdPx = 24

    // 间隔直接决定两帧之间的位移量：0.35s 下快速滚动单帧能超过一整屏，
    // 重叠不足就无法配准、帧被丢弃、长图出现空洞。0.10s（约 10fps）让位移始终落在可配准范围内。
    init(capturer: any ScrollFrameCapturing, globalRect: CGRect, interval: TimeInterval = 0.10) {
        self.capturer = capturer
        self.globalRect = globalRect
        self.interval = interval
    }

    func start(firstFrame: CGImage) {
        // 防御重复 start：先清掉可能遗留的旧 timer。
        stopTimer()
        ScrollDebug.log("start \(firstFrame.width)x\(firstFrame.height) interval=\(interval)")
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
        ScrollDebug.log("finish height=\(image?.height ?? 0) frames=\(workQueue.sync { engine.frameCount })")
        ScrollDebug.save(image, name: "result.png")
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
            let started = ProcessInfo.processInfo.systemUptime
            guard let frame = await self.captureFrameWithTimeout() else {
                nilCaptureCount += 1
                inFlight = false
                if nilCaptureCount >= 3 {
                    stopTimer()
                    isRunning = false
                    onStalled?()
                }
                return
            }
            nilCaptureCount = 0
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if elapsed > 1.0 {
                slowCaptureCount += 1
                if slowCaptureCount >= 3 {
                    stopTimer()
                    isRunning = false
                    inFlight = false
                    onStalled?()
                    return
                }
            } else {
                slowCaptureCount = 0
            }
            // 抓帧期间可能已 finish()/cancel()：此时不能再喂引擎，
            // 否则会在取消后回调 onUpdate，甚至弹出"已达上限"提示。
            guard isRunning else { inFlight = false; return }
            let engine = self.engine
            workQueue.async { [weak self] in
                let state = engine.consume(frame: frame)
                let estimate = engine.lastEstimate
                let misses = engine.consecutiveMisses
                ScrollDebug.log(
                    String(
                        format: "frame %dx%d offset=%@ cost=%.2f stickyT=%d stickyB=%d changed=%@ frames=%d height=%d",
                        frame.width, frame.height,
                        estimate.map { String(format: "%.0f", $0.offsetPx) } ?? "nil",
                        estimate?.confidence ?? 0,
                        engine.stickyTopPx,
                        engine.stickyBottomPx,
                        state?.changed == true ? "Y" : "n",
                        state?.frameCount ?? -1,
                        engine.image?.height ?? 0
                    )
                )
                if ScrollDebug.isEnabled { Self.dumpDebugFrame(frame) }
                let image = state?.changed == true ? engine.image : nil
                Task { @MainActor in
                    guard let self else { return }
                    self.inFlight = false
                    guard self.isRunning else { return }
                    if misses >= Self.missedFrameHintThreshold, misses % Self.missedFrameHintThreshold == 0 {
                        self.onFramesMissed?()
                    }
                    if let state { self.handle(state, image: image) }
                }
            }
        }
    }

    /// 抓帧超时保护：ScreenCaptureKit 一旦卡在 XPC 往返，这一帧永不返回，
    /// inFlight 会永久为真、预览停在原地。超时后放弃该帧，下一轮继续。
    private func captureFrameWithTimeout() async -> CGImage? {
        let capturer = self.capturer
        let rect = self.globalRect
        return await withTaskGroup(of: CGImage?.self) { group in
            group.addTask { await capturer.capture(globalRect: rect) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// 取证：把前若干帧落盘，便于用同一批真实帧离线回放验证引擎。
    private static var dumpedFrameCount = 0

    private static func dumpDebugFrame(_ frame: CGImage) {
        guard dumpedFrameCount < 24 else { return }
        dumpedFrameCount += 1
        ScrollDebug.save(frame, name: String(format: "frame-%02d.png", dumpedFrameCount))
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