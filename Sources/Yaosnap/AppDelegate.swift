import AppKit
import YaosnapCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private let hotkeyManager = HotkeyManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController()
        print("Yaosnap launched")
        let ok = hotkeyManager.register(.f1) {
            NSSound.beep() // Task 6 起替换为 SnipController.start()
        }
        if !ok {
            let alert = NSAlert()
            alert.messageText = "F1 热键注册失败"
            alert.informativeText = "可能被其他程序占用，请关闭冲突程序后重启 Yaosnap。"
            alert.runModal()
        }
    }
}
