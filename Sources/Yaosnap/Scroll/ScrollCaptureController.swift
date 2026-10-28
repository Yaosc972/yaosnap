import AppKit
import YaosnapCore

/// 定时抓帧并喂给引擎。抓帧是 async 的，用一个 inFlight 标记防止重入。
@MainActor
final class ScrollCaptureController {
    var onUpdate: ((CGImage, Int) -> Void)?
    var onFinish: ((CGImage) -> Void)?
    var onLimitReached: (() -> Void)?

    private let capturer: any ScrollFrameCapturing
    private let globalRect: CGRect
    private let interval: TimeInterval
    private let engine = ScrollCaptureEngine()
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
        engine.start(first: firstFrame)
        isRunning = true
        lastReportedHeight = 0
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
        guard let image = engine.image else { return }
        isRunning = false
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
            defer { self.inFlight = false }
            guard isRunning else { return }
            guard let frame = await capturer.capture(globalRect: globalRect) else { return }
            guard let state = engine.consume(frame: frame) else { return }
            if state.changed, let image = engine.image {
                let grewEnough = lastReportedHeight == 0
                    || image.height - lastReportedHeight >= Self.previewUpdateThresholdPx
                if grewEnough {
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
}
