import AppKit
import YaosnapCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private let hotkeyManager = HotkeyManager()
    private let fixedHotkeyManager = HotkeyManager()
    private let snipController = SnipController()
    private let pinController = PinController()
    private let settingsStore = SettingsStore()
    private var settings = Settings.standard
    private var settingsWindowController: SettingsWindowController?
    private lazy var hotCornerMonitor = HotCornerMonitor(
        isBusy: { [weak self] in self?.snipController.isActive ?? true },
        onTrigger: { [weak self] in
            guard let self, !self.snipController.isActive else { return }
            print("[hotcorner] triggered")
            self.snipController.start()
        }
    )
    private lazy var commandRouter = AppCommandRouter(
        snipController: snipController,
        pinController: pinController
    )

    /// CLI 通过 `yaosnap://` 唤起；app 未运行时系统先启动进程再投递到这里。
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            commandRouter.handle(url)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 设置里开着 UI 元素检测但还没授权时，启动就请求一次；
        // 不请求的话「辅助功能」列表里根本没有本应用，用户无从勾选。
        if settingsStore.load().detectUIElements, !UIElementDetector.isTrusted {
            _ = UIElementDetector.requestTrust()
        }
        print("[ax] trusted=\(UIElementDetector.isTrusted) detectUI=\(settingsStore.load().detectUIElements)")
        statusItemController = StatusItemController(
            onSnip: snipController.start,
            onPin: { [pinController] in pinController.pinFromPasteboard() },
            onTogglePassthrough: { [pinController] in pinController.togglePassthrough() },
            historyItems: { [snipController] in
                CaptureHistoryMenu.items(from: snipController.historySnapshot)
            },
            onReplayHistory: { [snipController] index in
                snipController.startReplayingHistory(at: index)
            },
            pinGroupState: { [pinController] in Self.menuState(from: pinController) },
            onSelectPinGroup: { [pinController] id in pinController.activateGroup(id) },
            onCreatePinGroup: { [pinController] name in pinController.addGroup(named: name) },
            onRenamePinGroup: { [pinController] id, name in pinController.renameGroup(id, to: name) },
            onDeletePinGroup: { [pinController] id in pinController.deleteGroup(id) },
            onToggleSolo: { [pinController] in pinController.toggleSoloForCurrentPin() },
            onSelectAllPins: { [pinController] in pinController.selectAllPins() },
            onClearPinSelection: { [pinController] in pinController.clearSelection() },
            onJoinSelectionToGroup: { [pinController] in pinController.joinSelectionToActiveGroup() },
            onOpenSettings: { [weak self] in self?.showSettings() },
            onActiveWindow: { [snipController] in snipController.startActiveWindow() },
            onRepeatLastRegion: { [snipController] in snipController.repeatLastRegion() },
            onDelaySnip: { [snipController] in snipController.startDelayed(seconds: $0) },
            onCancelDelay: { [snipController] in snipController.cancelDelay() },
            delayRemaining: { [snipController] in snipController.delayRemainingSeconds }
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSnipEscape(_:)), name: .snipEscapePressed, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSnipCommitted(_:)), name: .snipCommitted, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSnipCopy(_:)), name: .snipCopyRequested, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSnipShare(_:)), name: .snipShareRequested, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSnipSave(_:)), name: .snipSaveRequested, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSnipTextRecognize(_:)), name: .snipTextRecognizeRequested, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSnipBarcodeScan(_:)), name: .snipBarcodeScanRequested, object: nil)
        print("Yaosnap launched")
        settings = settingsStore.load()
        applyRuntimeSettings()
        registerHotkeys()
        registerFixedHotkeys()
    }

    private func showSettings() {
        if settingsWindowController == nil {
            let controller = SettingsWindowController(
                store: settingsStore,
                settings: settings,
                onChange: { [weak self] updated in self?.applySettings(updated) }
            )
            controller.onRecordingStateChange = { [weak self] recording in
                guard let self else { return }
                if recording {
                    self.hotkeyManager.unregisterAll()
                    self.fixedHotkeyManager.unregisterAll()
                } else {
                    self.registerHotkeys()
                    self.registerFixedHotkeys()
                }
            }
            settingsWindowController = controller
        }
        settingsWindowController?.show()
        // 重新注册一次，把启动时和本次打开之间的占用状态画到对应行。
        registerHotkeys()
    }

    private func applySettings(_ updated: Settings) {
        settings = updated
        applyRuntimeSettings()
        registerHotkeys()
    }

    private func applyRuntimeSettings() {
        snipController.quickSaveDirectory = settings.quickSaveDirectory
            .map { URL(fileURLWithPath: $0) }
        pinController.setRestoreCapacity(settings.restoreCapacity)
        hotCornerMonitor.apply(settings.hotCorners)
    }

    private func registerHotkeys() {
        hotkeyManager.unregisterAll()
        var failures = Set<HotkeyAction>()
        for binding in settings.hotkeyBindings {
            let handler = Self.handler(for: binding.action, snip: snipController, pin: pinController)
            if !hotkeyManager.register(binding.hotkey, handler: handler) {
                failures.insert(binding.action)
            }
        }
        let summary = settings.hotkeyBindings
            .map { "\($0.action.rawValue)=\($0.hotkey.displayName)" }
            .joined(separator: ", ")
        print("[hotkey] registered \(summary) failures=\(failures.map(\.rawValue).sorted())")
        settingsWindowController?.showRegistrationFailures(failures)
    }

    /// 固定快捷键不走设置项，单独一个注册器，避免设置保存时被整批重注册牵连。
    private func registerFixedHotkeys() {
        fixedHotkeyManager.unregisterAll()
        let activeWindow = fixedHotkeyManager.register(.ctrlShiftW) { [snipController] in
            MainActor.assumeIsolated { snipController.startActiveWindow() }
        }
        let repeatRegion = fixedHotkeyManager.register(.ctrlShiftR) { [snipController] in
            MainActor.assumeIsolated { snipController.repeatLastRegion() }
        }
        print("[hotkey] fixed activeWindow=\(activeWindow) repeatRegion=\(repeatRegion)")
    }

    private static func handler(
        for action: HotkeyAction,
        snip: SnipController,
        pin: PinController
    ) -> () -> Void {
        switch action {
        case .snip:
            return {
                MainActor.assumeIsolated {
                    print("[hotkey] snip triggered")
                    let t0 = CFAbsoluteTimeGetCurrent()
                    snip.start()
                    let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                    print(String(format: "[perf] hotkey→overlay: %.1f ms", elapsed))
                }
            }
        case .pin:
            return { MainActor.assumeIsolated { _ = pin.pinFromPasteboard() } }
        case .togglePins:
            return { MainActor.assumeIsolated { _ = pin.toggleVisibility() } }
        case .passthrough:
            return { MainActor.assumeIsolated { _ = pin.togglePassthrough() } }
        }
    }

    @objc private func handleSnipEscape(_ notification: Notification) {
        snipController.cancel()
    }

    @objc private func handleSnipCommitted(_ notification: Notification) {
        snipController.commitSelection(notification)
    }

    @objc private func handleSnipCopy(_ notification: Notification) {
        snipController.copyPendingImage(notification)
    }

    @objc private func handleSnipShare(_ notification: Notification) {
        snipController.sharePendingImage(notification)
    }

    @objc private func handleSnipSave(_ notification: Notification) {
        snipController.savePendingImage(notification)
    }

    @objc private func handleSnipTextRecognize(_ notification: Notification) {
        snipController.recognizeTextPending(notification)
    }

    @objc private func handleSnipBarcodeScan(_ notification: Notification) {
        snipController.scanBarcodePending(notification)
    }

    private static func menuState(from controller: PinController) -> PinGroupMenuState {
        PinGroupMenuState(
            groups: controller.pinGroups.map {
                PinGroupMenuState.Group(id: $0.id, name: $0.name, isDefault: $0.isDefault)
            },
            activeID: controller.activePinGroupID,
            soloActive: controller.soloPinID != nil,
            selectedCount: controller.selectedPinCount,
            visibleCount: controller.visiblePinCount
        )
    }
}
