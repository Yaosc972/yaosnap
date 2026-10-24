import Carbon.HIToolbox
import Foundation

/// Carbon 虚拟键码 + 修饰键掩码，可持久化。
public struct Hotkey: Equatable, Codable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// kVK_F1 = 122，无修饰键。注意：Apple 键盘默认媒体键模式下物理 F1
    /// 产生亮度事件而非 kVK_F1（需 fn+F1 或开启“将 F1、F2 用作标准功能键”）。
    public static let f1 = Hotkey(keyCode: 122, modifiers: 0)

    /// kVK_ANSI_A = 0，Control+Shift。不受媒体键模式影响，作为可靠默认热键。
    public static let ctrlShiftA = Hotkey(keyCode: 0, modifiers: UInt32(controlKey | shiftKey))
}
