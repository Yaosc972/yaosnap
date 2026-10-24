import CoreGraphics
import Foundation

/// 屏幕上一个窗口的快照。bounds 为 CG 全局坐标（主屏左上原点，y 向下）。
public struct WindowCandidate: Equatable {
    public let bounds: CGRect
    public let ownerName: String
    public let layer: Int
    public let windowID: Int

    public init(bounds: CGRect, ownerName: String, layer: Int, windowID: Int) {
        self.bounds = bounds
        self.ownerName = ownerName
        self.layer = layer
        self.windowID = windowID
    }
}

public enum WindowDetector {
    /// 当前屏幕上所有窗口，z 序顶层在前；本进程窗口已排除。
    public static func onScreenWindows(ownPID: pid_t) -> [WindowCandidate] {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return infoList.compactMap { info -> WindowCandidate? in
            guard
                let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                ownerPID != ownPID,
                let layer = info[kCGWindowLayer as String] as? Int,
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                let windowID = info[kCGWindowNumber as String] as? Int
            else { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            return WindowCandidate(bounds: bounds, ownerName: owner, layer: layer, windowID: windowID)
        }
    }

    /// 可吸附候选：普通窗口层（layer == 0）且非零尺寸。
    /// ownPID 仅为对齐接口保留；自身窗口已在 `onScreenWindows` 中排除。
    public static func snapCandidates(from all: [WindowCandidate], ownPID: pid_t) -> [WindowCandidate] {
        all.filter { $0.layer == 0 && $0.bounds.width >= 1 && $0.bounds.height >= 1 }
    }

    /// 光标所在的最顶层窗口。candidates 必须按 z 序顶层在前。
    public static func window(at point: CGPoint, in candidates: [WindowCandidate]) -> WindowCandidate? {
        candidates.first { $0.bounds.contains(point) }
    }
}
