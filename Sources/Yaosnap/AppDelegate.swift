import AppKit
import YaosnapCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private let hotkeyManager = HotkeyManager()
    private let snipController = SnipController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(onSnip: snipController.start)
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
}
