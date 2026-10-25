import AppKit
import YaosnapCore

/// 轮询全局鼠标位置，把是否触发交给 Core 的状态机。
/// 用定时器而不是事件监听，避免额外权限，也便于在设置变更时整体重启。
@MainActor
final class HotCornerMonitor {
    private var timer: Timer?
    private var tracker = HotCornerTracker(configuration: .disabled)
    private let isBusy: () -> Bool
    private let onTrigger: () -> Void

    init(isBusy: @escaping () -> Bool, onTrigger: @escaping () -> Void) {
        self.isBusy = isBusy
        self.onTrigger = onTrigger
    }

    func apply(_ settings: HotCornerSettings) {
        var settings = settings
        settings.clampDwell()
        tracker = HotCornerTracker(configuration: settings.trackerConfiguration)
        guard settings.enabled else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        // 会话中不推进状态机：触发后光标常仍停在角落，重置会让"先离开再回来"失效。
        guard !isBusy() else { return }
        let screens = NSScreen.screens.map(\.frame)
        if tracker.update(
            cursor: NSEvent.mouseLocation,
            screens: screens,
            at: ProcessInfo.processInfo.systemUptime
        ) != nil {
            onTrigger()
        }
    }
}
