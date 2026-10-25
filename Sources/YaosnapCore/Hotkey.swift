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

    /// kVK_F3 = 99，无修饰键，贴图。与 F1 一样受媒体键模式影响，需 fn+F3。
    public static let f3 = Hotkey(keyCode: 99, modifiers: 0)

    /// Shift+F3，隐藏 / 显示所有贴图。
    public static let shiftF3 = Hotkey(keyCode: 99, modifiers: UInt32(shiftKey))

    /// kVK_ANSI_T = 17，Control+Shift，切换光标下贴图的鼠标穿透。
    public static let ctrlShiftT = Hotkey(keyCode: 17, modifiers: UInt32(controlKey | shiftKey))

    /// kVK_ANSI_W = 13，Control+Shift，截取活动窗口。
    public static let ctrlShiftW = Hotkey(keyCode: 13, modifiers: UInt32(controlKey | shiftKey))

    /// kVK_ANSI_R = 15，Control+Shift，重复上次区域。
    public static let ctrlShiftR = Hotkey(keyCode: 15, modifiers: UInt32(controlKey | shiftKey))

    /// 设置窗口按下组合键时用 Carbon 掩码判断，避免 NSEvent 与 Carbon 位序混淆。
    private var hasCommand: Bool { modifiers & UInt32(cmdKey) != 0 }
    private var hasControl: Bool { modifiers & UInt32(controlKey) != 0 }
    private var hasOption: Bool { modifiers & UInt32(optionKey) != 0 }
    private var hasShift: Bool { modifiers & UInt32(shiftKey) != 0 }

    /// 与系统菜单一致：⌃⌥⇧⌘ 顺序。
    public var displayName: String {
        var text = ""
        if hasControl { text += "⌃" }
        if hasOption { text += "⌥" }
        if hasShift { text += "⇧" }
        if hasCommand { text += "⌘" }
        return text + (Self.keyNames[keyCode] ?? "键\(keyCode)")
    }

    /// kVK 常量在 Swift 里不易直接跨版本使用，这里固定与 Carbon 头文件一致的键码。
    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\",
        43: ",", 44: "/", 47: ".", 50: "`",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}
