import Carbon.HIToolbox

/// 基于 Carbon RegisterEventHotKey 的全局热键管理器。
/// 必须在主线程使用。
public final class HotkeyManager {
    public typealias Handler = () -> Void

    private struct Registration {
        let ref: EventHotKeyRef
        let handler: Handler
    }

    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private var handlerInstalled = false

    public init() {
        var type = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotkeyManager>
                    .fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                manager.registrations[hotKeyID.id]?.handler()
                return noErr
            },
            1,
            &type,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        handlerInstalled = installStatus == noErr
    }

    deinit {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    /// 注册全局热键；组合已被占用、系统拒绝或事件分发未装好时返回 false。
    @discardableResult
    public func register(_ hotkey: Hotkey, handler: @escaping Handler) -> Bool {
        guard handlerInstalled else { return false }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        // signature 'yaos'
        let hotKeyID = EventHotKeyID(signature: OSType(0x79616F73), id: id)
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return false }
        registrations[id] = Registration(ref: ref, handler: handler)
        return true
    }
}
