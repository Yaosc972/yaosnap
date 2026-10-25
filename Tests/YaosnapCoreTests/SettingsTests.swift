import Foundation
import Testing
@testable import YaosnapCore

struct SettingsTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "YaosnapTests.Settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func defaultsMatchPreviousHardcodedHotkeys() {
        let settings = Settings.standard
        #expect(settings.snipHotkey == .ctrlShiftA)
        #expect(settings.pinHotkey == .f3)
        #expect(settings.togglePinsHotkey == .shiftF3)
        #expect(settings.passthroughHotkey == .ctrlShiftT)
        #expect(settings.quickSaveDirectory == nil)
        #expect(settings.restoreCapacity == 1)
        #expect(settings.autoSelectOnCreation)
        #expect(settings.hotkeyBindings.map(\.action) == HotkeyAction.allCases)
    }

    @Test func emptyStoreLoadsDefaults() {
        let store = SettingsStore(defaults: makeDefaults())
        #expect(store.load() == .standard)
    }

    @Test func roundTripThroughIsolatedSuite() {
        var settings = Settings.standard
        settings.snipHotkey = Hotkey(keyCode: 7, modifiers: 0x1200)
        settings.pinHotkey = Hotkey(keyCode: 99, modifiers: 0x0200)
        settings.togglePinsHotkey = Hotkey(keyCode: 45, modifiers: 0x0900)
        settings.passthroughHotkey = Hotkey(keyCode: 17, modifiers: 0x1200)
        settings.quickSaveDirectory = "/tmp/yaosnap-settings-test"
        settings.restoreCapacity = 5
        settings.autoSelectOnCreation = false

        let defaults = makeDefaults()
        SettingsStore(defaults: defaults).save(settings)
        let loaded = SettingsStore(defaults: defaults).load()

        #expect(loaded == settings)
    }

    @Test func legacySettingsWithoutNewFieldsKeepExistingValues() throws {
        let legacy: [String: Any] = [
            "snipHotkey": ["keyCode": 7, "modifiers": 0x1200],
            "pinHotkey": ["keyCode": 99, "modifiers": 0x0200],
            "togglePinsHotkey": ["keyCode": 45, "modifiers": 0x0900],
            "passthroughHotkey": ["keyCode": 17, "modifiers": 0x1200],
            "restoreCapacity": 5,
            "autoSelectOnCreation": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)

        #expect(decoded.restoreCapacity == 5)
        #expect(!decoded.autoSelectOnCreation)
        #expect(decoded.hotCorners == .standard)
        #expect(decoded.whiteboard == .standard)
    }

    @Test func hotkeyStructureSurvivesJSON() throws {        let hotkey = Hotkey(keyCode: 17, modifiers: 0x1200)
        let data = try JSONEncoder().encode(hotkey)
        let decoded = try JSONDecoder().decode(Hotkey.self, from: data)
        #expect(decoded.keyCode == 17)
        #expect(decoded.modifiers == 0x1200)
        #expect(decoded.displayName == "⌃⇧T")
    }

    @Test func settingsBindingsCarryRegistrationValues() {
        var settings = Settings.standard
        settings.setHotkey(Hotkey(keyCode: 8, modifiers: 0x0A00), for: .passthrough)

        let bindings = Dictionary(
            uniqueKeysWithValues: settings.hotkeyBindings.map { ($0.action, $0.hotkey) }
        )
        #expect(bindings[.snip]?.keyCode == 0)
        #expect(bindings[.snip]?.modifiers == 0x1200)
        #expect(bindings[.pin]?.keyCode == 99)
        #expect(bindings[.pin]?.modifiers == 0)
        #expect(bindings[.togglePins]?.keyCode == 99)
        #expect(bindings[.togglePins]?.modifiers == 0x0200)
        #expect(bindings[.passthrough]?.keyCode == 8)
        #expect(bindings[.passthrough]?.modifiers == 0x0A00)
    }

    @Test func restoreCapacityIsClampedOnSaveAndLoad() {
        var settings = Settings.standard
        settings.restoreCapacity = 999
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.save(settings)
        #expect(store.load().restoreCapacity == Settings.restoreCapacityRange.upperBound)

        settings.restoreCapacity = 0
        store.save(settings)
        #expect(store.load().restoreCapacity == Settings.restoreCapacityRange.lowerBound)
    }

    @Test func corruptPayloadFallsBackToDefaults() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: SettingsStore.defaultsKey)
        #expect(SettingsStore(defaults: defaults).load() == .standard)
    }
}
