import Foundation

/// Carbon 虚拟键码 + 修饰键掩码，可持久化。
public struct Hotkey: Equatable, Codable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// kVK_F1 = 122，无修饰键
    public static let f1 = Hotkey(keyCode: 122, modifiers: 0)
}
