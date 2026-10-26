import AppKit
import YaosnapCore

/// 持有所有贴图窗口。窗口关闭时由 windowWillClose 回收。
@MainActor
final class PinController: NSObject, NSWindowDelegate {
    private var pinned: [PinWindow] = []
    private var restoreList: PinRestoreList<PinRestoreEntry>
    /// 逗号句号翻历史时的当前位置，nil 表示窗口显示的不是历史项。
    private var historyCursor: Int?
    private var lastPinned: PasteImage?
    private var groups = PinBoard()
    private var nextPinID = 1
    /// 进入 Solo 前的可见集合，退出时按它恢复，而不是假定「全组可见」。
    private var visibleBeforeSolo: Set<Int> = []
    private var selection = PinSelection()
    /// 整组拖动的起点快照；拖动期间按快照加偏移重算，避免逐次累加漂移。
    private var dragOrigins: [Int: CGPoint] = [:]

    init(restoreCapacity: Int = Settings.defaultRestoreCapacity) {
        restoreList = PinRestoreList(capacity: restoreCapacity)
        super.init()
    }

    /// 设置里的容量改动立即生效；已记录的恢复项无法扩容，直接清空是唯一一致的选择。
    func setRestoreCapacity(_ capacity: Int) {
        guard capacity != restoreList.capacity else { return }
        restoreList = PinRestoreList(capacity: capacity)
    }

    @discardableResult
    func pinFromPasteboard() -> Bool {
        guard let content = PasteboardReader.read(from: .general),
              let image = PasteboardReader.render(content) else {
            print("[pin] 剪贴板没有可贴的内容")
            NSSound.beep()
            return false
        }
        // 剪贴板自上次贴图后没变时，贴图键用于恢复最近关闭的那张，而不是重复贴一份。
        if PasteImage.sameContent(image, lastPinned), let entry = restoreList.takeMostRecent() {
            restore(entry)
            print("[pin] restored kind=\(content.kind) size=\(Int(image.pointSize.width))x\(Int(image.pointSize.height))")
            return true
        }
        guard let screen = screenUnderMouse() else {
            print("[pin] 找不到可用屏幕")
            NSSound.beep()
            return false
        }
        present(image, on: screen, at: nil)
        print("[pin] pinned kind=\(content.kind) size=\(Int(image.pointSize.width))x\(Int(image.pointSize.height))")
        return true
    }

    /// 命令行贴图：--pos 给的是主屏左上角为原点的坐标，越界时由窗口初始化钳回可见区域。
    @discardableResult
    func pin(image: PasteImage, at topLeft: CGPoint?) -> Bool {
        let appKitTop = topLeft.map(Self.appKitTop(fromTopLeft:))
        guard let screen = screen(containing: appKitTop) else {
            print("[pin] 找不到可用屏幕")
            NSSound.beep()
            return false
        }
        present(image, on: screen, at: appKitTop)
        print("[pin] pinned from cli size=\(Int(image.pointSize.width))x\(Int(image.pointSize.height))")
        return true
    }

    func showAll() {
        var last: PinWindow?
        for window in pinned where groups.shouldShow(pinID: window.pinID) {
            window.orderFront(nil)
            last = window
        }
        last?.makeKey()
    }

    func hideAll() {
        selection.clear()
        dragOrigins = [:]
        for window in pinned { window.orderOut(nil) }
        applySelection()
    }

    /// 只要还有可见窗口就全部隐藏，否则把当前分组重新显示出来。
    @discardableResult
    func toggleVisibility() -> Bool {
        if pinned.contains(where: \.isVisible) {
            hideAll()
            return false
        }
        showAll()
        return true
    }

    // MARK: - 分组与 Solo

    var pinGroups: [PinBoard.Group] { groups.groups }
    var activePinGroupID: Int { groups.activeGroupID }
    var soloPinID: Int? { groups.soloPinID }
    var selectedPinCount: Int { selection.count }
    var visiblePinCount: Int { pinned.filter(\.isVisible).count }

    // MARK: - 多选

    /// Shift 单击：在集合里加一个或移出一个。
    func toggleSelection(pinID: Int) {
        guard pinned.contains(where: { $0.pinID == pinID }) else { return }
        let added = selection.toggle(pinID)
        applySelection()
        print("[pin] selection \(added ? "add" : "remove") pin=\(pinID) count=\(selection.count)")
    }

    /// 全选只覆盖当前可见的贴图，隐藏分组里的贴图不会被顺手关掉。
    func selectAllPins() {
        selection.selectAll(pinned.filter(\.isVisible).map(\.pinID))
        applySelection()
        print("[pin] selection all count=\(selection.count)")
    }

    func clearSelection() {
        guard !selection.isEmpty else { return }
        selection.clear()
        applySelection()
        print("[pin] selection cleared")
    }

    @discardableResult
    func joinSelectionToActiveGroup() -> Bool {
        guard !selection.isEmpty else { return false }
        let ids = selection.ids
        for pinID in ids {
            groups.assign(pinID: pinID, toGroup: groups.activeGroupID)
        }
        // applyVisibility 只显示激活组，顺带清掉多选集合。
        applyVisibility()
        print("[pin] selection joined group=\(groups.activeGroupID) count=\(ids.count)")
        return true
    }

    /// 把单个贴图移到指定分组，右键菜单「移动到分组」用。
    @discardableResult
    func assign(pinID: Int, toGroup groupID: Int) -> Bool {
        guard groups.group(id: groupID) != nil else { return false }
        groups.assign(pinID: pinID, toGroup: groupID)
        applyVisibility()
        return true
    }

    /// 多选拖动期间 Esc 关闭整组；不是多选时交回窗口自己关闭。
    @discardableResult
    func closeSelection(triggeredBy window: PinWindow) -> Bool {
        guard selection.count > 1, selection.contains(window.pinID) else { return false }
        let ids = selection.ids
        selection.clear()
        dragOrigins = [:]
        let targets = pinned.filter { ids.contains($0.pinID) }
        for target in targets { target.close() }
        print("[pin] selection closed count=\(targets.count)")
        return true
    }

    func beginDrag(of window: PinWindow) {
        guard selection.count > 1, selection.contains(window.pinID) else {
            dragOrigins = [:]
            return
        }
        dragOrigins = Dictionary(uniqueKeysWithValues: pinned
            .filter { selection.contains($0.pinID) }
            .map { ($0.pinID, $0.frame.origin) })
    }

    @discardableResult
    func dragSelection(by delta: CGPoint) -> Bool {
        guard !dragOrigins.isEmpty else { return false }
        // 偏移先按整组一起钳进屏幕，逐张各自钳回会改变贴图间距。
        var applied = delta
        for window in pinned {
            guard let origin = dragOrigins[window.pinID],
                  let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { continue }
            let minDX = visible.minX - origin.x
            let maxDX = visible.maxX - window.frame.width - origin.x
            let minDY = visible.minY - origin.y
            let maxDY = visible.maxY - window.frame.height - origin.y
            applied.x = min(max(applied.x, minDX), max(maxDX, minDX))
            applied.y = min(max(applied.y, minDY), max(maxDY, minDY))
        }
        let moved = PinSelection.moved(origins: dragOrigins, by: applied)
        for window in pinned {
            guard let origin = moved[window.pinID] else { continue }
            window.setFrameOrigin(origin)
        }
        return true
    }

    func endDrag() {
        dragOrigins = [:]
    }

    private func applySelection() {
        for window in pinned {
            window.setMultiSelected(selection.contains(window.pinID))
        }
    }

    @discardableResult
    func addGroup(named name: String) -> Bool {
        groups.addGroup(named: name) != nil
    }

    @discardableResult
    func renameGroup(_ id: Int, to name: String) -> Bool {
        groups.renameGroup(id: id, to: name)
    }

    @discardableResult
    func deleteGroup(_ id: Int) -> Bool {
        guard id != PinBoard.defaultGroupID, groups.group(id: id) != nil else { return false }
        groups.deleteGroup(id: id)
        if groups.soloPinID == nil { visibleBeforeSolo = [] }
        applyVisibility()
        return true
    }

    /// 切组只显示该组贴图，并让 Solo 让位：用户要看的是整组。
    @discardableResult
    func activateGroup(_ id: Int) -> Bool {
        guard groups.activateGroup(id: id) else { return false }
        visibleBeforeSolo = []
        applyVisibility()
        return true
    }

    /// 对指定贴图切换 Solo。同一时间只有一张贴图能处于 Solo，切换目标即接管。
    @discardableResult
    func toggleSolo(pinID: Int) -> Bool {
        guard let window = pinned.first(where: { $0.pinID == pinID }) else { return false }
        if groups.soloPinID == pinID {
            groups.endSolo()
            restoreAfterSolo()
            return true
        }
        if groups.soloPinID == nil {
            visibleBeforeSolo = Set(pinned.filter(\.isVisible).map(\.pinID))
        }
        guard groups.beginSolo(pinID: pinID) else { return false }
        applyVisibility()
        window.makeKey()
        return true
    }

    /// 菜单入口：当前贴图取 key window，退而求其次取最上层可见贴图。
    @discardableResult
    func toggleSoloForCurrentPin() -> Bool {
        let current = (NSApp.keyWindow as? PinWindow)
            ?? pinned.last(where: \.isVisible)
            ?? pinned.last
        guard let current else {
            print("[pin] solo 失败：没有贴图")
            NSSound.beep()
            return false
        }
        let wasSolo = groups.soloPinID == current.pinID
        let ok = toggleSolo(pinID: current.pinID)
        print("[pin] solo \(wasSolo ? "off" : "on") pin=\(current.pinID) ok=\(ok)")
        return ok
    }

    /// 可见集合变化后多选集合不再有意义，一并清掉。
    private func applyVisibility() {
        selection.clear()
        dragOrigins = [:]
        var last: PinWindow?
        for window in pinned {
            if groups.shouldShow(pinID: window.pinID) {
                window.orderFront(nil)
                last = window
            } else {
                window.orderOut(nil)
            }
        }
        applySelection()
        last?.makeKey()
    }

    private func restoreAfterSolo() {
        let previous = visibleBeforeSolo
        visibleBeforeSolo = []
        selection.clear()
        dragOrigins = [:]
        for window in pinned {
            if previous.contains(window.pinID), groups.shouldShow(pinID: window.pinID) {
                window.orderFront(nil)
            } else {
                window.orderOut(nil)
            }
        }
        applySelection()
        pinned.last(where: \.isVisible)?.makeKey()
    }

    func closeAll() {
        selection.clear()
        dragOrigins = [:]
        let windows = pinned
        pinned.removeAll()
        for window in windows { window.close() }
    }

    /// 切换光标下最上层贴图的鼠标穿透；光标下没有贴图时取消全部穿透。
    /// 穿透中的窗口仍占据屏幕区域，再次触发热键会命中并切回可点击。
    @discardableResult
    func togglePassthrough(at point: CGPoint? = nil) -> Bool {
        let location = point ?? NSEvent.mouseLocation
        // NSApp.windows 从前往后排列；翻转成从底到顶，命中规则才和真实叠放一致。
        let stack = Array(NSApp.windows.compactMap { $0 as? PinWindow }.reversed())
        let index = PinHitTest.topmostIndex(
            of: location,
            in: stack.map(\.frame),
            visible: stack.map(\.isVisible)
        )
        let states = PinPassthrough.toggled(
            index: index,
            states: stack.map(\.ignoresMouseEvents)
        )
        for (window, ignoresMouse) in zip(stack, states) {
            window.ignoresMouseEvents = ignoresMouse
        }
        print("[pin] passthrough hit=\(index.map(String.init) ?? "none")")
        return index != nil
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? PinWindow else { return }
        pinned.removeAll { $0 === window }
        selection.remove(window.pinID)
        dragOrigins.removeValue(forKey: window.pinID)
        applySelection()
        let groupID = groups.groupID(of: window.pinID)
        let wasSolo = groups.soloPinID == window.pinID
        groups.forget(pinID: window.pinID)
        if wasSolo { visibleBeforeSolo = [] }
        guard window.canRestore else { return }
        restoreList.record(
            PinRestoreEntry(
                image: window.pasteImage,
                transform: window.transform,
                frame: window.frame,
                basePointSize: window.basePointSize,
                groupID: groupID
            ),
            kind: .closed
        )
    }

    /// 拖到屏幕外时把整个窗口钳回可见区域。
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? PinWindow,
              let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = window.frame
        let x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
        let y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
        guard x != frame.minX || y != frame.minY else { return }
        window.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private func present(_ image: PasteImage, on screen: NSScreen, at topLeft: CGPoint?) {
        lastPinned = image
        historyCursor = nil
        // 贴一张新图是想看到它：Solo 退出并把原可见集合还回去。
        if groups.soloPinID != nil {
            groups.endSolo()
            restoreAfterSolo()
        }
        let pinID = allocatePinID()
        groups.assign(pinID: pinID, toGroup: groups.activeGroupID)
        let window = PinWindow(
            pasteImage: image,
            pinID: pinID,
            screen: screen,
            cascadeIndex: pinned.count,
            topLeft: topLeft
        )
        window.delegate = self
        window.pinController = self
        pinned.append(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 逗号看更早关闭的一张，句号看更新的。只换当前窗口，不动恢复列表。
    func stepHistory(by direction: Int, in window: PinWindow) {
        guard restoreList.count > 0 else {
            NSSound.beep()
            return
        }
        let base = historyCursor ?? (direction > 0 ? -1 : restoreList.count)
        let target = min(max(base + direction, 0), restoreList.count - 1)
        guard let entry = restoreList.entry(at: target) else { return }
        historyCursor = target
        window.applyHistory(entry)
        print("[pin] history index=\(target) count=\(restoreList.count)")
    }

    private func restore(_ entry: PinRestoreEntry) {
        historyCursor = nil
        lastPinned = entry.image
        if groups.soloPinID != nil {
            groups.endSolo()
            restoreAfterSolo()
        }
        let pinID = allocatePinID()
        // 恢复回到关闭时的分组，组已删则 assign 落到默认组。
        groups.assign(pinID: pinID, toGroup: entry.groupID)
        groups.activateGroup(id: groups.groupID(of: pinID))
        let window = PinWindow(pasteImage: entry.image, pinID: pinID, restoring: entry)
        window.delegate = self
        window.pinController = self
        pinned.append(window)
        applyVisibility()
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func allocatePinID() -> Int {
        defer { nextPinID += 1 }
        return nextPinID
    }

    /// Snipaste 的 --pos 以主屏左上角为原点、y 向下；AppKit 以左下角为原点、y 向上。
    private static func appKitTop(fromTopLeft point: CGPoint) -> CGPoint {
        let main = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == CGMainDisplayID()
        } ?? NSScreen.screens.first
        let topY = main?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: topY - point.y)
    }

    private func screen(containing point: CGPoint?) -> NSScreen? {
        guard let point else { return screenUnderMouse() }
        return NSScreen.screens.first { $0.frame.contains(point) } ?? screenUnderMouse()
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}
