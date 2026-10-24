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
}
