import ApplicationServices
import CoreGraphics
import Foundation

/// 光标下 UI 元素的纯查询层。AX 坐标是主屏左上原点、y 向下，与 CG 全局坐标一致；
/// 换到视图坐标统一走 `RectMath.toViewRect`。
public enum UIElementDetector {
    /// 可上溯的父级层数上限。再深只会得到应用级容器，对选区没有意义。
    public static let maximumLevel = 5

    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 首次开启时把本进程登记进「辅助功能」列表。列表里没有条目时用户无从勾选，
    /// 所以必须先请求一次，即使当前仍是未授权。
    @discardableResult
    public static func requestTrust() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    public static func element(at screenPoint: CGPoint) -> CGRect? {
        elementRect(at: screenPoint, inPID: nil)
    }

    /// 指定应用内的元素查询。截图覆盖层压在目标窗口之上，系统级命中只会拿到本进程，
    /// 因此覆盖层按光标下窗口的 pid 定向查询。
    public static func element(at screenPoint: CGPoint, inPID pid: pid_t?) -> CGRect? {
        elementRect(at: screenPoint, inPID: pid)
    }

    public static func parentRect(of screenPoint: CGPoint, levels: Int) -> CGRect? {
        parentRect(of: screenPoint, levels: levels, inPID: nil)
    }

    public static func parentRect(of screenPoint: CGPoint, levels: Int, inPID pid: pid_t?) -> CGRect? {
        guard var element = elementAt(screenPoint, in: pid) else { return nil }
        for _ in 0..<clampLevel(levels) {
            guard let parent = parent(of: element) else { return nil }
            element = parent
        }
        return rect(of: element)
    }

    /// AX 屏幕矩形 → 本屏覆盖窗口内的视图坐标。
    public static func viewRect(
        fromAXRect axRect: CGRect,
        displayBounds: CGRect,
        viewHeight: CGFloat
    ) -> CGRect {
        RectMath.toViewRect(
            globalRect: axRect,
            displayBounds: displayBounds,
            viewHeight: viewHeight
        )
    }

    /// 元素矩形能否作为吸附候选。过小的控件和越出本屏的矩形回落到窗口吸附。
    public static func isUsable(
        _ rect: CGRect,
        minimumSide: CGFloat,
        within displayBounds: CGRect
    ) -> Bool {
        guard rect.width.isFinite, rect.height.isFinite,
              rect.width >= minimumSide, rect.height >= minimumSide else { return false }
        return displayBounds.contains(rect)
    }

    public static func clampLevel(_ level: Int) -> Int {
        min(max(level, 0), maximumLevel)
    }

    private static func elementRect(at screenPoint: CGPoint, inPID pid: pid_t?) -> CGRect? {
        guard let element = elementAt(screenPoint, in: pid) else { return nil }
        return rect(of: element)
    }

    private static func elementAt(_ point: CGPoint, in pid: pid_t?) -> AXUIElement? {
        let root = pid.map { AXUIElementCreateApplication($0) } ?? AXUIElementCreateSystemWide()
        if pid != nil {
            // 目标应用无响应时默认的 AX 超时会让每次 mouseMoved 卡秒级，这里收紧到 0.25 秒。
            AXUIElementSetMessagingTimeout(root, 0.25)
        }
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            root,
            Float(point.x),
            Float(point.y),
            &element
        ) == .success, let element else { return nil }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let owner = processID(of: element), owner != ownPID else { return nil }
        if let pid, owner != pid { return nil }
        return element
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXParentAttribute as CFString,
            &value
        ) == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func rect(of element: AXUIElement) -> CGRect? {
        guard let origin = pointAttribute(kAXPositionAttribute, of: element),
              let size = sizeAttribute(kAXSizeAttribute, of: element),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func pointAttribute(_ name: String, of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(_ name: String, of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func processID(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }
}
