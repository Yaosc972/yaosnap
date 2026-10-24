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
            self,
            selector: #selector(handleSnipEscape(_:)),
            name: .snipEscapePressed,
            object: nil
        )
        print("Yaosnap launched")
        let ok = hotkeyManager.register(.f1) { [snipController] in
            MainActor.assumeIsolated {
                snipController.start()
            }
        }
        if !ok {
            let alert = NSAlert()
            alert.messageText = "F1 热键注册失败"
            alert.informativeText = "可能被其他程序占用，请关闭冲突程序后重启 Yaosnap。"
            alert.runModal()
        }
    }

    @objc private func handleSnipEscape(_ notification: Notification) {
        snipController.cancel()
    }
}
