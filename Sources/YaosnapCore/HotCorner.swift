import CoreGraphics
import Foundation

/// 屏幕四角。Cocoa 全局坐标以左下为原点，top 对应屏幕 frame 的最大 y。
public enum ScreenCorner: String, CaseIterable, Codable, Sendable {
    case bottomLeft
    case bottomRight
    case topLeft
    case topRight

    public var title: String {
        switch self {
        case .topLeft: return "左上"
        case .topRight: return "右上"
        case .bottomLeft: return "左下"
        case .bottomRight: return "右下"
        }
    }

    /// 角落判定区，边长 size 点。
    public func zone(in frame: CGRect, size: CGFloat) -> CGRect {
        let x = (self == .topLeft || self == .bottomLeft) ? frame.minX : frame.maxX - size
        let y = (self == .bottomLeft || self == .bottomRight) ? frame.minY : frame.maxY - size
        return CGRect(x: x, y: y, width: size, height: size)
    }
}

public struct HotCornerSettings: Equatable, Codable {
    public static let dwellRange = 100...3000
    public static let standard = HotCornerSettings()

    public var enabled: Bool
    public var corners: Set<ScreenCorner>
    /// 光标停留多久后触发，毫秒。
    public var dwellMilliseconds: Int

    public init(
        enabled: Bool = false,
        corners: Set<ScreenCorner> = Set(ScreenCorner.allCases),
        dwellMilliseconds: Int = 500
    ) {
        self.enabled = enabled
        self.corners = corners
        self.dwellMilliseconds = dwellMilliseconds
    }

    public var dwell: TimeInterval { TimeInterval(dwellMilliseconds) / 1000 }

    public mutating func clampDwell() {
        dwellMilliseconds = min(
            max(dwellMilliseconds, Self.dwellRange.lowerBound),
            Self.dwellRange.upperBound
        )
    }

    public var trackerConfiguration: HotCornerTracker.Configuration {
        HotCornerTracker.Configuration(enabled: enabled, corners: corners, dwell: dwell)
    }
}

/// 触发角判定。只回答"此刻该不该触发"，监听与截图会话由上层负责。
public struct HotCornerTracker {
    public struct Configuration: Equatable {
        public var enabled: Bool
        public var corners: Set<ScreenCorner>
        public var dwell: TimeInterval
        public var zoneSize: CGFloat

        public init(enabled: Bool, corners: Set<ScreenCorner>, dwell: TimeInterval, zoneSize: CGFloat = 4) {
            self.enabled = enabled
            self.corners = corners
            self.dwell = dwell
            self.zoneSize = zoneSize
        }

        public static let disabled = Configuration(enabled: false, corners: [], dwell: 0)
    }

    private let configuration: Configuration
    private var armed: ScreenCorner?
    private var armedAt: TimeInterval = 0
    /// 已触发的角。光标必须先离开这里，才允许再次触发同一个角。
    private var fired: ScreenCorner?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public mutating func reset() {
        armed = nil
        armedAt = 0
        fired = nil
    }

    public func corner(at cursor: CGPoint, screens: [CGRect]) -> ScreenCorner? {
        for corner in ScreenCorner.allCases where configuration.corners.contains(corner) {
            for screen in screens where corner.zone(in: screen, size: configuration.zoneSize).contains(cursor) {
                return corner
            }
        }
        return nil
    }

    /// 返回本次应触发的角；nil 表示继续等待或仍处于已触发状态。
    public mutating func update(cursor: CGPoint, screens: [CGRect], at now: TimeInterval) -> ScreenCorner? {
        guard configuration.enabled else {
            reset()
            return nil
        }
        guard let hit = corner(at: cursor, screens: screens) else {
            armed = nil
            fired = nil
            return nil
        }
        if fired == hit { return nil }
        fired = nil
        if armed != hit {
            armed = hit
            armedAt = now
            return nil
        }
        guard now - armedAt >= configuration.dwell else { return nil }
        fired = hit
        return hit
    }
}
