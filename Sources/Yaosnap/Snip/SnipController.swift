import AppKit
import YaosnapCore

@MainActor
final class SnipController {
    private var windows: [SnipOverlayWindow] = []

    func start() {
        guard windows.isEmpty else { return }
        guard ScreenCaptureService.hasPermission() else {
            ScreenCaptureService.requestPermission()
            showPermissionAlert()
            return
        }
        let shots = ScreenCaptureService.captureAllDisplays()
        guard !shots.isEmpty else {
            showPermissionAlert()
            return
        }

        for shot in shots {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                    .uint32Value == shot.displayID
            }) else { continue }
            let window = SnipOverlayWindow(screen: screen)
            window.contentView = OverlayView(shot: shot)
            window.makeFirstResponder(window.contentView)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        // 激活后确保首屏窗口成为 key window，接收键盘（Esc）。
        windows.first?.makeKey()
    }

    func cancel() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "请在 系统设置 → 隐私与安全性 → 屏幕录制 中勾选 Yaosnap，然后重启 Yaosnap 后重试。"
        alert.runModal()
    }
}
