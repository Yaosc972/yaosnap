import AppKit
import Foundation
import YaosnapCore

/// 设置窗口验收：真实构造 SettingsWindowController，验证控件、录制回写与持久化。
@MainActor
final class SettingsHarness {
    private var passes = 0
    private var failures = 0
    private let suiteName = "yaosnap.settings.e2e"

    private func pass(_ id: String, _ detail: String) {
        passes += 1
        print("PASS \(id) \(detail)")
    }

    private func fail(_ id: String, _ detail: String) {
        failures += 1
        print("FAIL \(id) \(detail)")
    }

    private func check(_ id: String, _ condition: Bool, _ detail: String) {
        if condition { pass(id, detail) } else { fail(id, detail) }
    }

    private func collect<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        var found: [T] = root is T ? [root as! T] : []
        for subview in root.subviews {
            found.append(contentsOf: collect(type, in: subview))
        }
        return found
    }

    private func keyEvent(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        window: NSWindow
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    func runAll() {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fail("suite", "无法创建测试 UserDefaults suite")
            print("SUMMARY passes=\(passes) failures=\(failures)")
            exit(1)
        }
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(defaults: defaults)
        var lastChange: Settings?
        let controller = SettingsWindowController(
            store: store,
            settings: store.load(),
            onChange: { lastChange = $0 }
        )

        guard let window = controller.window, let content = window.contentView else {
            fail("window", "窗口未创建")
            print("SUMMARY passes=\(passes) failures=\(failures)")
            exit(1)
        }
        pass("window", "title=\(window.title) size=\(Int(window.frame.width))x\(Int(window.frame.height))")
        check("single-page", content.subviews.count == 1, "内容根视图 \(content.subviews.count) 个")
        window.orderFront(nil)

        let recorders = collect(HotkeyRecorderView.self, in: content)
        check("hotkey-controls", recorders.count == HotkeyAction.allCases.count,
              "录制控件 \(recorders.count) 个")

        let buttons = collect(NSButton.self, in: content)
        check("directory-button", buttons.contains(controller.chooseDirectoryButton), "含选择目录按钮")
        check("reset-button", buttons.contains(controller.resetButton), "含恢复默认按钮")
        check("capacity-controls",
              collect(NSStepper.self, in: content).count == 1
                && collect(NSTextField.self, in: content).contains(controller.restoreCapacityField),
              "数量输入与步进器各一")
        check("auto-select", controller.autoSelectCheckbox.state == .on, "自动选中默认开启")

        let selectBefore = store.load().autoSelectOnCreation
        controller.autoSelectCheckbox.performClick(nil)
        check("auto-select-toggle", store.load().autoSelectOnCreation == !selectBefore,
              "自动选中写回 \(store.load().autoSelectOnCreation)")
        check("auto-select-callback", lastChange?.autoSelectOnCreation == !selectBefore, "变更回调收到新值")

        controller.restoreCapacityField.stringValue = "7"
        if let action = controller.restoreCapacityField.action {
            NSApp.sendAction(
                action,
                to: controller.restoreCapacityField.target,
                from: controller.restoreCapacityField
            )
        }
        check("capacity-write", store.load().restoreCapacity == 7,
              "数量写回 \(store.load().restoreCapacity)")

        guard let snipRecorder = controller.hotkeyRecorders[.snip] else {
            fail("hotkey-record", "截图录制控件缺失")
            return summarize()
        }
        snipRecorder.beginRecording()
        check("recording-state", snipRecorder.isRecording, "点击后进入录制")
        if let event = keyEvent(keyCode: 11, characters: "b", modifiers: [.control, .shift], window: window) {
            snipRecorder.keyDown(with: event)
        }
        let recorded = store.load().snipHotkey
        check("hotkey-record", recorded.keyCode == 11 && recorded.modifiers == 0x1200,
              "Ctrl+Shift+B -> keyCode=\(recorded.keyCode) modifiers=\(recorded.modifiers)")
        check("hotkey-display", snipRecorder.hotkey.displayName == "⌃⇧B",
              "显示 \(snipRecorder.hotkey.displayName)")

        snipRecorder.beginRecording()
        if let escape = keyEvent(keyCode: 53, characters: "\u{1b}", modifiers: [], window: window) {
            snipRecorder.keyDown(with: escape)
        }
        check("escape-cancels",
              !snipRecorder.isRecording && store.load().snipHotkey.keyCode == 11,
              "Esc 结束录制且不改写")

        controller.showRegistrationFailures([.pin])
        check("failure-mark",
              controller.statusLabels[.pin]?.stringValue == "被其他程序占用"
                && controller.statusLabels[.snip]?.stringValue == "",
              "占用状态只标在失败行")

        controller.resetButton.performClick(nil)
        check("reset-defaults", store.load() == Settings.standard, "恢复默认写回标准值")
        check("reset-controls", controller.restoreCapacityField.integerValue == 1,
              "控件同步为默认值")

        check("persisted",
              defaults.data(forKey: SettingsStore.defaultsKey) != nil,
              "UserDefaults 存在 \(SettingsStore.defaultsKey)")
        check("reload", SettingsStore(defaults: defaults).load() == store.load(), "新 store 读到相同设置")

        window.orderOut(nil)
        defaults.removePersistentDomain(forName: suiteName)
        summarize()
    }

    private func summarize() {
        print("SUMMARY passes=\(passes) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}

@main
struct SettingsE2EMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let harness = SettingsHarness()
            harness.runAll()
        }
    }
}
