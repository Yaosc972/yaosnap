import AppKit
import YaosnapCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private let hotkeyManager = HotkeyManager()
    private let snipController = SnipController()
    private let pinController = PinController()
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
        statusItemController = StatusItemController(
            onSnip: snipController.start,
            onPin: { [pinController] in pinController.pinFromPasteboard() },
            onTogglePassthrough: { [pinController] in pinController.togglePassthrough() },
            pinGroupState: { [pinController] in Self.menuState(from: pinController) },
            onSelectPinGroup: { [pinController] id in pinController.activateGroup(id) },
            onCreatePinGroup: { [pinController] name in pinController.addGroup(named: name) },
            onRenamePinGroup: { [pinController] id, name in pinController.renameGroup(id, to: name) },
            onDeletePinGroup: { [pinController] id in pinController.deleteGroup(id) },
            onToggleSolo: { [pinController] in pinController.toggleSoloForCurrentPin() }
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSnipEscape(_:)), name: .snipEscapePressed, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSnipCommitted(_:)), name: .snipCommitted, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSnipCopy(_:)), name: .snipCopyRequested, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSnipSave(_:)), name: .snipSaveRequested, object: nil)
        print("Yaosnap launched")
        let snipHandler: () -> Void = { [snipController] in
            MainActor.assumeIsolated {
                print("[hotkey] snip triggered")
                let t0 = CFAbsoluteTimeGetCurrent()
                snipController.start()
                let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                print(String(format: "[perf] hotkey→overlay: %.1f ms", elapsed))
            }
        }
        let ok = hotkeyManager.register(.f1, handler: snipHandler)
        let ok2 = hotkeyManager.register(.ctrlShiftA, handler: snipHandler)
        print("[hotkey] register F1 -> \(ok), Ctrl+Shift+A -> \(ok2)")
        let pinHandler: () -> Void = { [pinController] in
            MainActor.assumeIsolated { _ = pinController.pinFromPasteboard() }
        }
        let hidePinsHandler: () -> Void = { [pinController] in
            MainActor.assumeIsolated { _ = pinController.toggleVisibility() }
        }
        let ok3 = hotkeyManager.register(.f3, handler: pinHandler)
        let ok4 = hotkeyManager.register(.shiftF3, handler: hidePinsHandler)
        let passthroughHandler: () -> Void = { [pinController] in
            MainActor.assumeIsolated { _ = pinController.togglePassthrough() }
        }
        let ok5 = hotkeyManager.register(.ctrlShiftT, handler: passthroughHandler)
        print("[hotkey] register F3 -> \(ok3), Shift+F3 -> \(ok4), Ctrl+Shift+T -> \(ok5)")
        if !ok, !ok2 {
            let alert = NSAlert()
            alert.messageText = "F1 热键注册失败"
            alert.informativeText = "可能被其他程序占用，请关闭冲突程序后重启 Yaosnap。"
            alert.runModal()
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

    @objc private func handleSnipSave(_ notification: Notification) {
        snipController.savePendingImage(notification)
    }

    private static func menuState(from controller: PinController) -> PinGroupMenuState {
        PinGroupMenuState(
            groups: controller.pinGroups.map {
                PinGroupMenuState.Group(id: $0.id, name: $0.name, isDefault: $0.isDefault)
            },
            activeID: controller.activePinGroupID,
            soloActive: controller.soloPinID != nil
        )
    }
}
