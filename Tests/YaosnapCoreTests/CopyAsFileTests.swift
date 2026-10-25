import Foundation
import Testing
@testable import YaosnapCore

struct CopyAsFileTests {
    @Test func legacySettingsWithoutTriggerDefaultToShortcut() throws {
        let legacy: [String: Any] = [
            "snipHotkey": ["keyCode": 7, "modifiers": 0x1200],
            "pinHotkey": ["keyCode": 99, "modifiers": 0x0200],
            "togglePinsHotkey": ["keyCode": 45, "modifiers": 0x0900],
            "passthroughHotkey": ["keyCode": 17, "modifiers": 0x1200],
            "restoreCapacity": 2,
            "autoSelectOnCreation": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)

        #expect(decoded.copyAsFileTrigger == .shortcut)
    }

    @Test func triggerRoundTripsThroughJSON() throws {
        for trigger in CopyAsFileTrigger.allCases {
            let data = try JSONEncoder().encode(trigger)
            let decoded = try JSONDecoder().decode(CopyAsFileTrigger.self, from: data)
            #expect(decoded == trigger)
        }
    }

    @Test func triggerDecidesFileFromOptionKey() {
        #expect(!CopyAsFileTrigger.off.copiesAsFile(optionHeld: false))
        #expect(!CopyAsFileTrigger.off.copiesAsFile(optionHeld: true))
        #expect(!CopyAsFileTrigger.shortcut.copiesAsFile(optionHeld: false))
        #expect(CopyAsFileTrigger.shortcut.copiesAsFile(optionHeld: true))
        #expect(CopyAsFileTrigger.always.copiesAsFile(optionHeld: false))
        #expect(CopyAsFileTrigger.always.copiesAsFile(optionHeld: true))
    }
}
