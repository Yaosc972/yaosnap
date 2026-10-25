import CoreGraphics
import Foundation

/// 一次成功截图的选区，保留源屏几何以便在新会话里按比例重放。
/// rect 与 displayBounds 均为 CG 全局坐标（主屏左上原点，y 向下）。
public struct CaptureRegion: Equatable {
    public let displayID: CGDirectDisplayID
    public let rect: CGRect
    public let displayBounds: CGRect

    public init(displayID: CGDirectDisplayID, rect: CGRect, displayBounds: CGRect) {
        self.displayID = displayID
        self.rect = rect
        self.displayBounds = displayBounds
    }

    public var isUsable: Bool {
        !rect.isEmpty && displayBounds.width > 0 && displayBounds.height > 0
    }
}

/// 重复上次区域：按选区在源屏内的相对位置与比例映射到目标屏。
public enum RepeatRegion {
    public static func map(_ region: CaptureRegion, onto displayBounds: CGRect) -> CGRect {
        guard region.isUsable, displayBounds.width > 0, displayBounds.height > 0 else {
            return .zero
        }
        let scaleX = displayBounds.width / region.displayBounds.width
        let scaleY = displayBounds.height / region.displayBounds.height
        let mapped = CGRect(
            x: displayBounds.minX + (region.rect.minX - region.displayBounds.minX) * scaleX,
            y: displayBounds.minY + (region.rect.minY - region.displayBounds.minY) * scaleY,
            width: region.rect.width * scaleX,
            height: region.rect.height * scaleY
        )
        return RectMath.clamp(mapped, to: displayBounds)
    }
}

/// 延时截屏的秒数范围。解析与校验放在 Core，菜单与 CLI 共用。
public enum DelayCapture {
    public static let range = 1...60

    public static func seconds(from raw: String) -> Int? {
        guard let value = Int(raw), range.contains(value) else { return nil }
        return value
    }
}

/// 活动窗口候选：z 序顶层在前，排除自身进程与非普通窗口层。
public enum ActiveWindow {
    public static func pick(from windows: [WindowCandidate], ownPID: pid_t) -> WindowCandidate? {
        windows.first {
            $0.ownerPID != ownPID
                && $0.layer == 0
                && $0.bounds.width >= 1
                && $0.bounds.height >= 1
        }
    }
}
