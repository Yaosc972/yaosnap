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
            let bounds = CGDisplayBounds(id)
            return DisplayShot(
                displayID: id,
                image: image,
                bounds: bounds,
                scale: deriveScale(for: id, imageWidth: image.width, bounds: bounds)
            )
        }
    }

    /// 以冻结帧实际像素宽度 / 屏幕点宽度推导 scale（裁剪必须与图像对齐）。
    /// 与 NSScreen.backingScaleFactor 不一致时告警并采用推导值。
    static func deriveScale(
        for displayID: CGDirectDisplayID,
        imageWidth: Int,
        bounds: CGRect
    ) -> CGFloat {
        let reported = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        }?.backingScaleFactor

        guard bounds.width > 0 else {
            print("[capture] warning: displayID=\(displayID) bounds 宽度为 0，scale 退回 \(reported ?? 1)")
            return reported ?? 1
        }
        let derived = CGFloat(imageWidth) / bounds.width
        if let reported, abs(reported - derived) > 0.001 {
            print("[capture] warning: displayID=\(displayID) scale 不一致，NSScreen=\(reported) 图像推导=\(derived)，采用推导值")
        }
        return derived
    }
}
