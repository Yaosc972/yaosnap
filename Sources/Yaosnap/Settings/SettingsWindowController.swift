import AppKit
import Carbon.HIToolbox
import YaosnapCore

/// 热键录制控件：点击进入录制，按下组合键写入，Esc 取消。
@MainActor
final class HotkeyRecorderView: NSView {
    var hotkey: Hotkey {
        didSet { refreshAppearance() }
    }
    var onChange: ((Hotkey) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    private(set) var isRecording = false {
        didSet {
            refreshAppearance()
            onRecordingChange?(isRecording)
        }
    }

    private let label = NSTextField(labelWithString: "")

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 26) }

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 150),
            heightAnchor.constraint(equalToConstant: 26),
        ])
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未使用")
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginRecording()
    }

    func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
    }

    func cancelRecording() {
        isRecording = false
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            cancelRecording()
            return
        }
        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        // 字母数字单键做全局热键会抢走正常输入，只接受带修饰键的组合；功能键保持可单按。
        guard modifiers != 0 || Self.isFunctionKey(event.keyCode) else {
            NSSound.beep()
            return
        }
        let recorded = Hotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        isRecording = false
        hotkey = recorded
        refreshAppearance()
        onChange?(recorded)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { isRecording = false }
        return resigned
    }

    private func refreshAppearance() {
        label.stringValue = isRecording ? "按下快捷键…" : hotkey.displayName
        label.textColor = isRecording ? .secondaryLabelColor : .labelColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        return modifiers
    }

    private static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        (96...122).contains(keyCode)
    }
}

/// 单页设置窗口。窗口只负责显示与回写，模型与持久化都在 SettingsStore。
@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    private let store: SettingsStore
    private var settings: Settings
    private let onChange: (Settings) -> Void
    /// 录制期间需要暂停全局热键，否则按下的旧组合会直接触发对应功能。
    var onRecordingStateChange: ((Bool) -> Void)?

    private(set) var hotkeyRecorders: [HotkeyAction: HotkeyRecorderView] = [:]
    private(set) var statusLabels: [HotkeyAction: NSTextField] = [:]
    let directoryLabel = NSTextField(labelWithString: "")
    let chooseDirectoryButton = NSButton(title: "选择…", target: nil, action: nil)
    let restoreCapacityField = NSTextField()
    let restoreCapacityStepper = NSStepper()
    let autoSelectCheckbox = NSButton(checkboxWithTitle: "创建后自动选中", target: nil, action: nil)
    let detectElementsCheckbox = NSButton(checkboxWithTitle: "自动检测 UI 元素", target: nil, action: nil)
    let aspectRatioPopup = NSPopUpButton()
    let shadowCheckbox = NSButton(checkboxWithTitle: "保存 / 复制时添加", target: nil, action: nil)
    let hotCornerCheckbox = NSButton(checkboxWithTitle: "启用", target: nil, action: nil)
    private(set) var hotCornerBoxes: [ScreenCorner: NSButton] = [:]
    let dwellField = NSTextField()
    let whiteboardCheckbox = NSButton(checkboxWithTitle: "启用", target: nil, action: nil)
    let whiteboardColorWell = NSColorWell()
    let whiteboardColorHexField = NSTextField()
    let resetButton = NSButton(title: "恢复默认", target: nil, action: nil)

    init(store: SettingsStore, settings: Settings, onChange: @escaping (Settings) -> Void) {
        self.store = store
        self.settings = settings
        self.onChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        // 程序创建的窗口默认关闭即释放，菜单再次打开会变成野指针。
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        refreshControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未使用")
    }

    func show() {
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 注册失败的组合在对应行标红，成功时清空提示。
    func showRegistrationFailures(_ failures: Set<HotkeyAction>) {
        for (action, label) in statusLabels {
            label.stringValue = failures.contains(action) ? "被其他程序占用" : ""
        }
    }

    private func buildContent() {
        var rows: [[NSView]] = []

        for action in HotkeyAction.allCases {
            let title = NSTextField(labelWithString: action.title)
            title.alignment = .right
            let recorder = HotkeyRecorderView(hotkey: settings.hotkey(for: action))
            recorder.onChange = { [weak self] hotkey in
                self?.hotkeyRecorded(hotkey, for: action)
            }
            recorder.onRecordingChange = { [weak self] recording in
                self?.onRecordingStateChange?(recording)
            }
            hotkeyRecorders[action] = recorder

            let status = NSTextField(labelWithString: "")
            status.font = .systemFont(ofSize: 11)
            status.textColor = .systemRed
            statusLabels[action] = status

            let stack = NSStackView(views: [recorder, status])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 8
            rows.append([title, stack])
        }

        let directoryTitle = NSTextField(labelWithString: "快捷保存目录")
        directoryTitle.alignment = .right
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        directoryLabel.textColor = .secondaryLabelColor
        directoryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        directoryLabel.widthAnchor.constraint(equalToConstant: 230).isActive = true
        chooseDirectoryButton.target = self
        chooseDirectoryButton.action = #selector(chooseDirectory)
        let directoryStack = NSStackView(views: [directoryLabel, chooseDirectoryButton])
        directoryStack.orientation = .horizontal
        directoryStack.alignment = .centerY
        directoryStack.spacing = 8
        rows.append([directoryTitle, directoryStack])

        let capacityTitle = NSTextField(labelWithString: "可恢复贴图数量")
        capacityTitle.alignment = .right
        restoreCapacityField.alignment = .right
        restoreCapacityField.target = self
        restoreCapacityField.action = #selector(restoreCapacityCommitted)
        restoreCapacityField.delegate = self
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: Settings.restoreCapacityRange.lowerBound)
        formatter.maximum = NSNumber(value: Settings.restoreCapacityRange.upperBound)
        restoreCapacityField.formatter = formatter
        restoreCapacityField.widthAnchor.constraint(equalToConstant: 56).isActive = true

        restoreCapacityStepper.minValue = Double(Settings.restoreCapacityRange.lowerBound)
        restoreCapacityStepper.maxValue = Double(Settings.restoreCapacityRange.upperBound)
        restoreCapacityStepper.increment = 1
        restoreCapacityStepper.target = self
        restoreCapacityStepper.action = #selector(restoreCapacityStepperChanged)
        let capacityStack = NSStackView(views: [
            restoreCapacityField,
            restoreCapacityStepper,
            NSTextField(labelWithString: "张"),
        ])
        capacityStack.orientation = .horizontal
        capacityStack.alignment = .centerY
        capacityStack.spacing = 8
        rows.append([capacityTitle, capacityStack])

        let autoSelectTitle = NSTextField(labelWithString: "创建后自动选中")
        autoSelectTitle.alignment = .right
        autoSelectCheckbox.target = self
        autoSelectCheckbox.action = #selector(autoSelectToggled)
        rows.append([autoSelectTitle, autoSelectCheckbox])

        let detectElementsTitle = NSTextField(labelWithString: "自动检测 UI 元素")
        detectElementsTitle.alignment = .right
        detectElementsCheckbox.target = self
        detectElementsCheckbox.action = #selector(detectElementsToggled)
        rows.append([detectElementsTitle, detectElementsCheckbox])

        let aspectTitle = NSTextField(labelWithString: "选区比例")
        aspectTitle.alignment = .right
        aspectRatioPopup.addItems(withTitles: SelectionAspectRatio.allCases.map(\.title))
        aspectRatioPopup.target = self
        aspectRatioPopup.action = #selector(aspectRatioChanged)
        rows.append([aspectTitle, aspectRatioPopup])

        let shadowTitle = NSTextField(labelWithString: "导出阴影")
        shadowTitle.alignment = .right
        shadowCheckbox.target = self
        shadowCheckbox.action = #selector(shadowToggled)
        rows.append([shadowTitle, shadowCheckbox])

        let cornerTitle = NSTextField(labelWithString: "触发角")
        cornerTitle.alignment = .right
        hotCornerCheckbox.target = self
        hotCornerCheckbox.action = #selector(hotCornersToggled)
        let cornerBoxes = [ScreenCorner.topLeft, .topRight, .bottomLeft, .bottomRight].map { corner in
            let box = NSButton(checkboxWithTitle: corner.title, target: self, action: #selector(hotCornerToggled(_:)))
            hotCornerBoxes[corner] = box
            return box
        }
        let cornerStack = NSStackView(views: [hotCornerCheckbox] + cornerBoxes)
        cornerStack.orientation = .horizontal
        cornerStack.alignment = .centerY
        cornerStack.spacing = 8
        rows.append([cornerTitle, cornerStack])

        let dwellTitle = NSTextField(labelWithString: "停留时长")
        dwellTitle.alignment = .right
        dwellField.alignment = .right
        dwellField.target = self
        dwellField.action = #selector(dwellCommitted)
        dwellField.delegate = self
        let dwellFormatter = NumberFormatter()
        dwellFormatter.allowsFloats = false
        dwellFormatter.minimum = NSNumber(value: HotCornerSettings.dwellRange.lowerBound)
        dwellFormatter.maximum = NSNumber(value: HotCornerSettings.dwellRange.upperBound)
        dwellField.formatter = dwellFormatter
        dwellField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let dwellStack = NSStackView(views: [
            dwellField,
            NSTextField(labelWithString: "毫秒（默认 500）"),
        ])
        dwellStack.orientation = .horizontal
        dwellStack.alignment = .centerY
        dwellStack.spacing = 8
        rows.append([dwellTitle, dwellStack])

        let whiteboardTitle = NSTextField(labelWithString: "白板模式")
        whiteboardTitle.alignment = .right
        whiteboardCheckbox.target = self
        whiteboardCheckbox.action = #selector(whiteboardToggled)
        rows.append([whiteboardTitle, whiteboardCheckbox])

        let whiteboardColorTitle = NSTextField(labelWithString: "白板背景色")
        whiteboardColorTitle.alignment = .right
        whiteboardColorWell.target = self
        whiteboardColorWell.action = #selector(whiteboardColorChanged)
        whiteboardColorWell.widthAnchor.constraint(equalToConstant: 56).isActive = true
        whiteboardColorHexField.placeholderString = "#RRGGBB"
        whiteboardColorHexField.alignment = .right
        whiteboardColorHexField.target = self
        whiteboardColorHexField.action = #selector(whiteboardHexCommitted)
        whiteboardColorHexField.delegate = self
        whiteboardColorHexField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let whiteboardColorRow = NSStackView(views: [whiteboardColorWell, whiteboardColorHexField])
        whiteboardColorRow.orientation = .horizontal
        whiteboardColorRow.alignment = .centerY
        whiteboardColorRow.spacing = 8
        rows.append([whiteboardColorTitle, whiteboardColorRow])

        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.columnSpacing = 12
        grid.rowSpacing = 12
        grid.rowAlignment = .firstBaseline

        resetButton.target = self
        resetButton.action = #selector(resetToDefaults)
        resetButton.bezelStyle = .rounded

        let content = NSStackView(views: [grid, resetButton])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 20
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window?.contentView = container
        content.layoutSubtreeIfNeeded()
        let fitted = content.fittingSize
        window?.setContentSize(NSSize(width: 480, height: fitted.height))
    }

    private func refreshControls() {
        for action in HotkeyAction.allCases {
            hotkeyRecorders[action]?.hotkey = settings.hotkey(for: action)
        }
        updateDirectoryLabel()
        restoreCapacityField.integerValue = settings.restoreCapacity
        restoreCapacityStepper.integerValue = settings.restoreCapacity
        autoSelectCheckbox.state = settings.autoSelectOnCreation ? .on : .off
        detectElementsCheckbox.state = settings.detectUIElements ? .on : .off
        if let index = SelectionAspectRatio.allCases.firstIndex(of: settings.selectionAspectRatio) {
            aspectRatioPopup.selectItem(at: index)
        }
        shadowCheckbox.state = settings.exportShadow ? .on : .off
        hotCornerCheckbox.state = settings.hotCorners.enabled ? .on : .off
        for (corner, box) in hotCornerBoxes {
            box.state = settings.hotCorners.corners.contains(corner) ? .on : .off
        }
        dwellField.integerValue = settings.hotCorners.dwellMilliseconds
        whiteboardCheckbox.state = settings.whiteboard.enabled ? .on : .off
        whiteboardColorWell.color = NSColor(
            srgbRed: settings.whiteboard.color.r,
            green: settings.whiteboard.color.g,
            blue: settings.whiteboard.color.b,
            alpha: settings.whiteboard.color.a
        )
        whiteboardColorHexField.stringValue = settings.whiteboard.color.hexString
        showRegistrationFailures([])
    }

    private func updateDirectoryLabel() {
        directoryLabel.stringValue = settings.quickSaveDirectory ?? "~/Pictures/Yaosnap（默认）"
    }

    private func hotkeyRecorded(_ hotkey: Hotkey, for action: HotkeyAction) {
        settings.setHotkey(hotkey, for: action)
        apply()
    }

    private func apply() {
        settings.clamp()
        store.save(settings)
        onChange(settings)
    }

    @objc private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.directoryURL = settings.quickSaveDirectory
            .map { URL(fileURLWithPath: $0) } ?? QuickSaveStore().directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.quickSaveDirectory = url.path
        updateDirectoryLabel()
        apply()
    }

    @objc private func restoreCapacityCommitted() {
        let typed = restoreCapacityField.integerValue
        // 空输入或 0 恢复为当前值，避免把「没填」当成要清空恢复列表。
        settings.restoreCapacity = typed == 0 ? settings.restoreCapacity : typed
        settings.clampRestoreCapacity()
        restoreCapacityField.integerValue = settings.restoreCapacity
        restoreCapacityStepper.integerValue = settings.restoreCapacity
        apply()
    }

    @objc private func restoreCapacityStepperChanged() {
        settings.restoreCapacity = restoreCapacityStepper.integerValue
        settings.clampRestoreCapacity()
        restoreCapacityField.integerValue = settings.restoreCapacity
        restoreCapacityStepper.integerValue = settings.restoreCapacity
        apply()
    }

    @objc private func autoSelectToggled() {
        settings.autoSelectOnCreation = autoSelectCheckbox.state == .on
        apply()
    }

    /// 开启时未授权只做引导：设置照常保存，截图时静默回落到窗口吸附。
    @objc private func detectElementsToggled() {
        settings.detectUIElements = detectElementsCheckbox.state == .on
        apply()
        guard settings.detectUIElements, !UIElementDetector.isTrusted else { return }
        // 先登记进「辅助功能」列表，否则系统设置里根本没有本应用可勾选。
        UIElementDetector.requestTrust()
        presentAccessibilityAlert()
    }

    private func presentAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = """
        自动检测 UI 元素需要辅助功能权限。请在「系统设置 → 隐私与安全性 → 辅助功能」中勾选 \
        Build/Yaosnap.app（~/yaosnap/Build/Yaosnap.app），然后关闭并重新开启本开关以生效。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn,
                  let url = URL(
                      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                  ) else { return }
            NSWorkspace.shared.open(url)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    @objc private func aspectRatioChanged() {
        let index = aspectRatioPopup.indexOfSelectedItem
        guard SelectionAspectRatio.allCases.indices.contains(index) else { return }
        settings.selectionAspectRatio = SelectionAspectRatio.allCases[index]
        apply()
    }

    @objc private func shadowToggled() {
        settings.exportShadow = shadowCheckbox.state == .on
        apply()
    }

    @objc private func hotCornersToggled() {
        settings.hotCorners.enabled = hotCornerCheckbox.state == .on
        apply()
    }

    @objc private func hotCornerToggled(_ sender: NSButton) {
        guard let corner = hotCornerBoxes.first(where: { $0.value === sender })?.key else { return }
        if sender.state == .on {
            settings.hotCorners.corners.insert(corner)
        } else {
            settings.hotCorners.corners.remove(corner)
        }
        apply()
    }

    @objc private func dwellCommitted() {
        let typed = dwellField.integerValue
        // 空输入或 0 保持当前值，不把「没填」当成 0 毫秒。
        settings.hotCorners.dwellMilliseconds = typed == 0
            ? settings.hotCorners.dwellMilliseconds : typed
        settings.hotCorners.clampDwell()
        dwellField.integerValue = settings.hotCorners.dwellMilliseconds
        apply()
    }

    @objc private func whiteboardToggled() {
        settings.whiteboard.enabled = whiteboardCheckbox.state == .on
        apply()
    }

    @objc private func whiteboardColorChanged() {
        let color = whiteboardColorWell.color.usingColorSpace(.sRGB) ?? .white
        settings.whiteboard.color = RGBAColor(
            r: color.redComponent,
            g: color.greenComponent,
            b: color.blueComponent,
            a: color.alphaComponent
        )
        whiteboardColorHexField.stringValue = settings.whiteboard.color.hexString
        apply()
    }

    /// 非法输入不落库，回填当前颜色，避免设置里出现无法解析的字符串。
    @objc private func whiteboardHexCommitted() {
        settings.whiteboard.color = WhiteboardColor.parseOrDefault(whiteboardColorHexField.stringValue)
        whiteboardColorHexField.stringValue = settings.whiteboard.color.hexString
        whiteboardColorWell.color = NSColor(
            srgbRed: settings.whiteboard.color.r,
            green: settings.whiteboard.color.g,
            blue: settings.whiteboard.color.b,
            alpha: settings.whiteboard.color.a
        )
        apply()
    }

    @objc private func resetToDefaults() {
        settings = .standard
        refreshControls()
        apply()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === restoreCapacityField {
            restoreCapacityCommitted()
        } else if field === dwellField {
            dwellCommitted()
        } else if field === whiteboardColorHexField {
            whiteboardHexCommitted()
        }
    }

    /// 窗口关闭时若还在录制，热键会停在注销状态，这里负责恢复注册。
    func windowWillClose(_ notification: Notification) {
        for recorder in hotkeyRecorders.values where recorder.isRecording {
            recorder.cancelRecording()
        }
    }
}
