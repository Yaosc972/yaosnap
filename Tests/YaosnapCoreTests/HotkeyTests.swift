import Foundation
import Testing
@testable import YaosnapCore

struct HotkeyTests {
    @Test func codableRoundTrip() throws {
        let original = Hotkey(keyCode: 122, modifiers: 0)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Hotkey.self, from: data)
        #expect(decoded == original)
    }

    @Test func f1Constant() {
        #expect(Hotkey.f1.keyCode == 122)
        #expect(Hotkey.f1.modifiers == 0)
    }

    // ⌃⇧A 是默认热键：kVK_ANSI_A=0，Control(0x1000)+Shift(0x0200)
    @Test func ctrlShiftAConstant() {
        #expect(Hotkey.ctrlShiftA.keyCode == 0)
        #expect(Hotkey.ctrlShiftA.modifiers == 0x1200)
        #expect(Hotkey.ctrlShiftA.modifiers != Hotkey.f1.modifiers)
    }
}
