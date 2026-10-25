import Foundation

/// 可绑定全局热键的动作。rawValue 用作持久化与日志标识。
public enum HotkeyAction: String, CaseIterable, Codable {
    case snip
    case pin
    case togglePins
    case passthrough

    public var title: String {
        switch self {
        case .snip: return "截图"
        case .pin: return "贴图"
        case .togglePins: return "隐藏 / 显示贴图"
        case .passthrough: return "切换贴图穿透"
        }
    }
}

public struct HotkeyBinding: Equatable {
    public let action: HotkeyAction
    public let hotkey: Hotkey

    public init(action: HotkeyAction, hotkey: Hotkey) {
        self.action = action
        self.hotkey = hotkey
    }
}

public struct Settings: Equatable, Codable {
    public static let defaultRestoreCapacity = 1
    public static let restoreCapacityRange = 1...20

    public var snipHotkey: Hotkey
    public var pinHotkey: Hotkey
    public var togglePinsHotkey: Hotkey
    public var passthroughHotkey: Hotkey
    /// nil 表示使用默认目录 ~/Pictures/Yaosnap，路径写死反而会让移动后的目录失效。
    public var quickSaveDirectory: String?
    public var restoreCapacity: Int
    public var autoSelectOnCreation: Bool
    /// 截图时按 UI 元素吸附。默认关闭，开启需要辅助功能权限。
    public var detectUIElements: Bool
    public var selectionAspectRatio: SelectionAspectRatio
    public var exportShadow: Bool
    public var hotCorners: HotCornerSettings
    public var whiteboard: WhiteboardSettings

    public init(
        snipHotkey: Hotkey = .ctrlShiftA,
        pinHotkey: Hotkey = .f3,
        togglePinsHotkey: Hotkey = .shiftF3,
        passthroughHotkey: Hotkey = .ctrlShiftT,
        quickSaveDirectory: String? = nil,
        restoreCapacity: Int = Settings.defaultRestoreCapacity,
        autoSelectOnCreation: Bool = true,
        detectUIElements: Bool = false,
        selectionAspectRatio: SelectionAspectRatio = .free,
        exportShadow: Bool = false,
        hotCorners: HotCornerSettings = .standard,
        whiteboard: WhiteboardSettings = .standard
    ) {
        self.snipHotkey = snipHotkey
        self.pinHotkey = pinHotkey
        self.togglePinsHotkey = togglePinsHotkey
        self.passthroughHotkey = passthroughHotkey
        self.quickSaveDirectory = quickSaveDirectory
        self.restoreCapacity = restoreCapacity
        self.autoSelectOnCreation = autoSelectOnCreation
        self.detectUIElements = detectUIElements
        self.selectionAspectRatio = selectionAspectRatio
        self.exportShadow = exportShadow
        self.hotCorners = hotCorners
        self.whiteboard = whiteboard
    }

    private enum CodingKeys: String, CodingKey {
        case snipHotkey
        case pinHotkey
        case togglePinsHotkey
        case passthroughHotkey
        case quickSaveDirectory
        case restoreCapacity
        case autoSelectOnCreation
        case detectUIElements
        case selectionAspectRatio
        case exportShadow
        case hotCorners
        case whiteboard
    }

    /// 新字段缺失时用默认值，避免升级后整份旧设置反序列化失败。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snipHotkey = try container.decode(Hotkey.self, forKey: .snipHotkey)
        pinHotkey = try container.decode(Hotkey.self, forKey: .pinHotkey)
        togglePinsHotkey = try container.decode(Hotkey.self, forKey: .togglePinsHotkey)
        passthroughHotkey = try container.decode(Hotkey.self, forKey: .passthroughHotkey)
        quickSaveDirectory = try container.decodeIfPresent(String.self, forKey: .quickSaveDirectory)
        restoreCapacity = try container.decode(Int.self, forKey: .restoreCapacity)
        autoSelectOnCreation = try container.decode(Bool.self, forKey: .autoSelectOnCreation)
        detectUIElements = try container.decodeIfPresent(Bool.self, forKey: .detectUIElements) ?? false
        selectionAspectRatio = try container.decodeIfPresent(
            SelectionAspectRatio.self, forKey: .selectionAspectRatio
        ) ?? .free
        exportShadow = try container.decodeIfPresent(Bool.self, forKey: .exportShadow) ?? false
        hotCorners = try container.decodeIfPresent(HotCornerSettings.self, forKey: .hotCorners) ?? .standard
        whiteboard = try container.decodeIfPresent(WhiteboardSettings.self, forKey: .whiteboard) ?? .standard
    }

    public static let standard = Settings()

    public func hotkey(for action: HotkeyAction) -> Hotkey {
        switch action {
        case .snip: return snipHotkey
        case .pin: return pinHotkey
        case .togglePins: return togglePinsHotkey
        case .passthrough: return passthroughHotkey
        }
    }

    public mutating func setHotkey(_ hotkey: Hotkey, for action: HotkeyAction) {
        switch action {
        case .snip: snipHotkey = hotkey
        case .pin: pinHotkey = hotkey
        case .togglePins: togglePinsHotkey = hotkey
        case .passthrough: passthroughHotkey = hotkey
        }
    }

    /// 注册顺序即展示顺序，HotkeyManager 按这里的结果逐条注册。
    public var hotkeyBindings: [HotkeyBinding] {
        HotkeyAction.allCases.map { HotkeyBinding(action: $0, hotkey: hotkey(for: $0)) }
    }

    public mutating func clampRestoreCapacity() {
        restoreCapacity = min(
            max(restoreCapacity, Self.restoreCapacityRange.lowerBound),
            Self.restoreCapacityRange.upperBound
        )
    }

    public mutating func clamp() {
        clampRestoreCapacity()
        hotCorners.clampDwell()
    }
}

/// 设置持久化。UserDefaults 注入便于测试用独立 suite，不碰真实偏好。
public struct SettingsStore {
    public static let defaultsKey = "Yaosnap.settings.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Settings {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              var settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return .standard
        }
        settings.clamp()
        return settings
    }

    public func save(_ settings: Settings) {
        var normalized = settings
        normalized.clamp()
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
