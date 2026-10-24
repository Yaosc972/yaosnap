import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let onSnip: @MainActor () -> Void

    init(onSnip: @escaping @MainActor () -> Void) {
        self.onSnip = onSnip
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "camera.viewfinder",
                accessibilityDescription: "Yaosnap"
            )
        }
        menu.addItem(NSMenuItem(title: "截图", action: #selector(snipTriggered), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Yaosnap", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil {
            item.target = self
        }
        statusItem.menu = menu
    }

    @objc private func snipTriggered() {
        onSnip()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
