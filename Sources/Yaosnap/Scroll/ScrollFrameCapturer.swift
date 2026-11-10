import AppKit
import ScreenCaptureKit

protocol ScrollFrameCapturing: Sendable {
    func capture(globalRect: CGRect) async -> CGImage?
}

/// 抓取指定屏幕上的矩形区域。
///
/// 整个类型是 actor：ScreenCaptureKit 的捕获请求与 Vision 一样必须离开主线程，
/// 放在主 actor 上 await 会让主线程参与 XPC 往返，滚动时整机失去响应。
/// 优先 ScreenCaptureKit 并排除本进程窗口；连续失败后永久退回确定性抓取，
/// 避免每帧都去撞同一个错误。
actor ScreenScrollFrameCapturer: ScrollFrameCapturing {
    private let displayID: CGDirectDisplayID
    private let scale: CGFloat
    private let excludedWindowNumber: Int
    // SCShareableContent 是 macOS 12.3+ 类型，而包的最低部署目标是 12.0；
    // 存储属性无法用 #available 保护，因此缓存按 AnyObject 存放，仅在可用性分支内强转。
    private var cachedContent: AnyObject?
    private var screenCaptureKitFailures = 0
    private static let maximumScreenCaptureKitFailures = 2

    init(displayID: CGDirectDisplayID, scale: CGFloat, excludedWindowNumber: Int) {
        self.displayID = displayID
        self.scale = scale
        self.excludedWindowNumber = excludedWindowNumber
    }

    func capture(globalRect: CGRect) async -> CGImage? {
        if #available(macOS 14.0, *),
           screenCaptureKitFailures < Self.maximumScreenCaptureKitFailures {
            if let image = await captureWithScreenCaptureKit(globalRect) {
                screenCaptureKitFailures = 0
                return image
            }
            screenCaptureKitFailures += 1
        }
        return captureBelowOwnWindow(globalRect)
    }

    @available(macOS 14.0, *)
    private func captureWithScreenCaptureKit(_ rect: CGRect) async -> CGImage? {
        do {
            let content: SCShareableContent
            if let cachedContent = cachedContent as? SCShareableContent {
                content = cachedContent
            } else {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                cachedContent = content
            }

            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                cachedContent = nil
                return nil
            }
            let ownApplications = content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier
            }
            guard !ownApplications.isEmpty else { return nil }

            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
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