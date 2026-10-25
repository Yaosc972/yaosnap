import AppKit
import YaosnapCore

/// 菜单展示所需的分组快照，由 PinController 提供。
struct PinGroupMenuState {
    struct Group {
        let id: Int
        let name: String
        let isDefault: Bool
    }

    let groups: [Group]
    let activeID: Int
    let soloActive: Bool
}

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    let menu = NSMenu()
    private let onSnip: @MainActor () -> Void
    private let onPin: @MainActor () -> Void
    private let onTogglePassthrough: @MainActor () -> Void
    private let historyItems: @MainActor () -> [CaptureHistoryMenu.Item]
    private let onReplayHistory: @MainActor (Int) -> Void
    private let pinGroupState: @MainActor () -> PinGroupMenuState
    private let onSelectPinGroup: @MainActor (Int) -> Void
    private let onCreatePinGroup: @MainActor (String) -> Bool
    private let onRenamePinGroup: @MainActor (Int, String) -> Bool
    private let onDeletePinGroup: @MainActor (Int) -> Bool
    private let onToggleSolo: @MainActor () -> Void
    private let onOpenSettings: @MainActor () -> Void

    init(
        onSnip: @escaping @MainActor () -> Void,
        onPin: @escaping @MainActor () -> Void,
        onTogglePassthrough: @escaping @MainActor () -> Void,
        historyItems: @escaping @MainActor () -> [CaptureHistoryMenu.Item],
        onReplayHistory: @escaping @MainActor (Int) -> Void,
        pinGroupState: @escaping @MainActor () -> PinGroupMenuState,
        onSelectPinGroup: @escaping @MainActor (Int) -> Void,
        onCreatePinGroup: @escaping @MainActor (String) -> Bool,
        onRenamePinGroup: @escaping @MainActor (Int, String) -> Bool,
        onDeletePinGroup: @escaping @MainActor (Int) -> Bool,
        onToggleSolo: @escaping @MainActor () -> Void,
        onOpenSettings: @escaping @MainActor () -> Void
    ) {
        self.onSnip = onSnip
        self.onPin = onPin
        self.onTogglePassthrough = onTogglePassthrough
        self.historyItems = historyItems
        self.onReplayHistory = onReplayHistory
        self.pinGroupState = pinGroupState
        self.onSelectPinGroup = onSelectPinGroup
        self.onCreatePinGroup = onCreatePinGroup
        self.onRenamePinGroup = onRenamePinGroup
        self.onDeletePinGroup = onDeletePinGroup
        self.onToggleSolo = onToggleSolo
        self.onOpenSettings = onOpenSettings
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
        menu.delegate = self
        menu.autoenablesItems = false
        rebuildMenu()
        statusItem.menu = menu
    }

    /// 分组与 Solo 状态随贴图变化，每次展开菜单时重建。
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        let state = pinGroupState()
        menu.removeAllItems()

        let snipItem = NSMenuItem(title: "截图", action: #selector(snipTriggered), keyEquivalent: "")
        let menuIcon = Self.templateIcon(named: "MenuItemIcon", pointSize: 16)
        if menuIcon == nil {
            print("[status] error: MenuItemIcon 资源缺失，回退系统符号")
        }
        snipItem.image = menuIcon
            ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "截图")
        menu.addItem(snipItem)

        let history = historyItems()
        let historyItem = NSMenuItem(title: "截图历史", action: nil, keyEquivalent: "")
        historyItem.image = NSImage(
            systemSymbolName: "clock.arrow.circlepath",
            accessibilityDescription: "截图历史"
        )
        historyItem.submenu = makeHistoryMenu(history)
        historyItem.isEnabled = !history.isEmpty
        menu.addItem(historyItem)

        let pinItem = NSMenuItem(title: "贴图", action: #selector(pinTriggered), keyEquivalent: "")
        pinItem.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "贴图")
        menu.addItem(pinItem)

        let passthroughItem = NSMenuItem(
            title: "切换贴图穿透",
            action: #selector(passthroughTriggered),
            keyEquivalent: ""
        )
        passthroughItem.image = NSImage(
            systemSymbolName: "cursorarrow",
            accessibilityDescription: "切换贴图穿透"
        )
        menu.addItem(passthroughItem)

        menu.addItem(.separator())

        let groupItem = NSMenuItem(title: "贴图分组", action: nil, keyEquivalent: "")
        groupItem.image = NSImage(
            systemSymbolName: "square.stack.3d.up",
            accessibilityDescription: "贴图分组"
        )
        groupItem.submenu = makeGroupMenu(state)
        menu.addItem(groupItem)

        let soloItem = NSMenuItem(
            title: state.soloActive ? "退出 Solo" : "Solo 当前贴图",
            action: #selector(soloTriggered),
            keyEquivalent: ""
        )
        soloItem.image = NSImage(
            systemSymbolName: "rectangle.on.rectangle.slash",
            accessibilityDescription: "Solo 当前贴图"
        )
        menu.addItem(soloItem)

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(settingsTriggered),
            keyEquivalent: ","
        )
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: "退出 Yaosnap", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil {
            item.target = self
        }
    }

    private func makeHistoryMenu(_ items: [CaptureHistoryMenu.Item]) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for item in items {
            let entry = NSMenuItem(
                title: item.title,
                action: #selector(historySelected(_:)),
                keyEquivalent: ""
            )
            entry.representedObject = item.index
            entry.target = self
            submenu.addItem(entry)
        }
        return submenu
    }

    private func makeGroupMenu(_ state: PinGroupMenuState) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for group in state.groups {
            let item = NSMenuItem(
                title: group.name,
                action: #selector(groupSelected(_:)),
                keyEquivalent: ""
            )
            item.representedObject = group.id
            item.state = group.id == state.activeID ? .on : .off
            item.target = self
            submenu.addItem(item)
        }
        submenu.addItem(.separator())

        let create = NSMenuItem(title: "新建分组…", action: #selector(createGroup), keyEquivalent: "")
        create.target = self
        submenu.addItem(create)

        let rename = NSMenuItem(
            title: "重命名当前分组…",
            action: #selector(renameActiveGroup),
            keyEquivalent: ""
        )
        rename.target = self
        submenu.addItem(rename)

        let isDefault = state.groups.first { $0.id == state.activeID }?.isDefault ?? true
        let delete = NSMenuItem(
            title: "删除当前分组…",
            action: #selector(deleteActiveGroup),
            keyEquivalent: ""
        )
        delete.target = self
        delete.isEnabled = !isDefault
        submenu.addItem(delete)
        return submenu
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

    private func promptName(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    @objc private func snipTriggered() {
        onSnip()
    }

    @objc private func historySelected(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        onReplayHistory(index)
    }

    @objc private func pinTriggered() {
        onPin()
    }

    @objc private func passthroughTriggered() {
        onTogglePassthrough()
    }

    @objc private func soloTriggered() {
        onToggleSolo()
    }

    @objc private func settingsTriggered() {
        onOpenSettings()
    }

    @objc private func groupSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int else { return }
        onSelectPinGroup(id)
    }

    @objc private func createGroup() {
        guard let name = promptName(title: "新建分组", initial: "") else { return }
        if !onCreatePinGroup(name) { NSSound.beep() }
    }

    @objc private func renameActiveGroup() {
        let state = pinGroupState()
        guard let active = state.groups.first(where: { $0.id == state.activeID }),
              let name = promptName(title: "重命名分组", initial: active.name) else { return }
        if !onRenamePinGroup(active.id, name) { NSSound.beep() }
    }

    @objc private func deleteActiveGroup() {
        let state = pinGroupState()
        guard let active = state.groups.first(where: { $0.id == state.activeID }),
              !active.isDefault else { return }
        if !onDeletePinGroup(active.id) { NSSound.beep() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
