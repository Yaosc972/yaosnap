import AppKit
import ScreenCaptureKit

@MainActor
protocol ScrollFrameCapturing: AnyObject {
    func capture(globalRect: CGRect) async -> CGImage?
}

/// 抓取指定屏幕上的矩形区域。优先 ScreenCaptureKit 并排除本进程窗口，
/// 保证覆盖层的遮罩与边框不会进入拼接结果；失败时退回"抓本窗口之下"。
@MainActor
final class ScreenScrollFrameCapturer: ScrollFrameCapturing {
    private let displayID: CGDirectDisplayID
    private let scale: CGFloat
    private let excludedWindowNumber: Int
    // ScreenCaptureKit 需要 macOS 12.3+（截图 API 14.0+），而包的最低部署目标是
    // macOS 12.0，因此缓存按 AnyObject 存放，仅在可用性分支内做强转。
    private var cachedContent: AnyObject?

    init(displayID: CGDirectDisplayID, scale: CGFloat, excludedWindowNumber: Int) {
        self.displayID = displayID
        self.scale = scale
        self.excludedWindowNumber = excludedWindowNumber
    }

    func capture(globalRect: CGRect) async -> CGImage? {
        if #available(macOS 14.0, *),
           let image = await captureWithScreenCaptureKit(globalRect) {
            return image
        }
        return captureBelowOwnWindow(globalRect)
    }

    @available(macOS 14.0, *)
    private func captureWithScreenCaptureKit(_ rect: CGRect) async -> CGImage? {
        do {
            let content: SCShareableContent
            if let cached = cachedContent as? SCShareableContent {
                content = cached
            } else {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                cachedContent = content
            }

            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                // 缓存内容可能已过期（显示器拔插/会话变化），清掉以免永久卡在回退路径。
                cachedContent = nil
                return nil
            }
            let ownApplications = content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier
            }
            // 枚举结果里没有本进程时，应用级排除什么也排不掉，会把自己的遮罩/边框拼进图里；
            // 此时宁可放弃 SCK，交给确定性的“抓本窗口之下”回退。
            guard !ownApplications.isEmpty else {
                return nil
            }
            // 同时按 windowID 精确定位覆盖层窗口做窗口级排除，不依赖 applications 列表。
            let ownWindows = content.windows.filter {
                $0.windowID == CGWindowID(excludedWindowNumber)
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: ownWindows
            )
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(
                x: rect.minX - display.frame.minX,
                y: rect.minY - display.frame.minY,
                width: rect.width,
                height: rect.height
            )
            config.width = max(1, Int((rect.width * scale).rounded()))
            config.height = max(1, Int((rect.height * scale).rounded()))
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            return nil
        }
    }

    private func captureBelowOwnWindow(_ rect: CGRect) -> CGImage? {
        CGWindowListCreateImage(
            rect,
            .optionOnScreenBelowWindow,
            CGWindowID(excludedWindowNumber),
            [.bestResolution]
        )
    }
}
