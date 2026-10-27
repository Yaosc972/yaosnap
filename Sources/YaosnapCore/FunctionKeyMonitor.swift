import CoreGraphics
import Foundation

/// F1、F2 是 WindowServer 独占的亮度键，Carbon 热键注册成功也收不到事件。
/// 用 CGEventTap 在键盘层直接监听，只把登记的 keyCode 交给调用方。
public final class FunctionKeyMonitor {
    public typealias Handler = () -> Void

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var handlers: [UInt32: Handler] = [:]

    public init() {}

    /// 亮度和静音这类独佔键的 keyCode，Carbon 收不到，需要走事件监听。
    public static func requiresEventTap(keyCode: UInt32, modifiers: UInt32) -> Bool {
        guard modifiers == 0 else { return false }
        return keyCode == 122 || keyCode == 120 || keyCode == 107
    }

    @discardableResult
    public func register(keyCode: UInt32, handler: @escaping Handler) -> Bool {
        handlers[keyCode] = handler
        return ensureTap()
    }

    public func unregisterAll() {
        handlers.removeAll()
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        self.tap = nil
        self.source = nil
    }

    private func ensureTap() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue)
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, _, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<FunctionKeyMonitor>
                    .fromOpaque(refcon).takeUnretainedValue()
                // 长按的系统重复事件不重复触发。
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    let code = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
                    monitor.handlers[code]?()
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        tap = created
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        return true
    }
}
