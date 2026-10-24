import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let onSnip: @MainActor () -> Void
    private let onPin: @MainActor () -> Void

    init(onSnip: @escaping @MainActor () -> Void, onPin: @escaping @MainActor () -> Void) {
        self.onSnip = onSnip
        self.onPin = onPin
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            let icon = Self.templateIcon(named: "StatusBarIcon", pointSize: 18)
            if icon == nil {
                print("[status] error: StatusBarIcon 资源缺失，回退系统符号")
            }
            button.image = icon
                ?? NSImage(
                    systemSymbolName: "camera.viewfinder",
                    accessibilityDescription: "Yaosnap"
                )
        }
        let snipItem = NSMenuItem(title: "截图", action: #selector(snipTriggered), keyEquivalent: "")
        let menuIcon = Self.templateIcon(named: "MenuItemIcon", pointSize: 16)
        if menuIcon == nil {
            print("[status] error: MenuItemIcon 资源缺失，回退系统符号")
        }
        snipItem.image = menuIcon
            ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "截图")
        menu.addItem(snipItem)
        let pinItem = NSMenuItem(title: "贴图", action: #selector(pinTriggered), keyEquivalent: "")
        pinItem.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "贴图")
        menu.addItem(pinItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Yaosnap", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil {
            item.target = self
        }
        statusItem.menu = menu
    }

    /// 模板图标：1x/2x 两张 PNG 合成一个 NSImage，rep 的点尺寸统一为设计稿尺寸。
    private static func templateIcon(named name: String, pointSize: CGFloat) -> NSImage? {
        let pointSize = NSSize(width: pointSize, height: pointSize)
        let reps: [NSBitmapImageRep] = [name, "\(name)@2x"].compactMap { fileName in
            guard let url = Bundle.main.url(forResource: fileName, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { return nil }
            rep.size = pointSize
            return rep
        }
        guard !reps.isEmpty else { return nil }
        let image = NSImage(size: pointSize)
        for rep in reps {
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }

    @objc private func snipTriggered() {
        onSnip()
    }

    @objc private func pinTriggered() {
        onPin()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
