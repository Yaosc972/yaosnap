import AppKit
import CoreGraphics

public struct DisplayShot {
    public let displayID: CGDirectDisplayID
    public let image: CGImage
    public let bounds: CGRect   // CG 全局坐标（左上原点）
    public let scale: CGFloat   // backingScaleFactor

    public init(displayID: CGDirectDisplayID, image: CGImage, bounds: CGRect, scale: CGFloat) {
        self.displayID = displayID
        self.image = image
        self.bounds = bounds
        self.scale = scale
    }
}

public enum ScreenCaptureService {
    public static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 触发系统授权对话框；首次授权后需重启 app 才完全生效（TCC 行为）。
    @discardableResult
    public static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// 捕获全部活动屏幕的冻结帧。无权限时返回空数组。
    public static func captureAllDisplays() -> [DisplayShot] {
        guard hasPermission() else { return [] }

        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)

        return ids.compactMap { id in
            guard let image = CGDisplayCreateImage(id) else { return nil }
            return DisplayShot(
                displayID: id,
                image: image,
                bounds: CGDisplayBounds(id),
                scale: scaleFactor(for: id)
            )
        }
    }

    private static func scaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        }?.backingScaleFactor ?? 1
    }
}
