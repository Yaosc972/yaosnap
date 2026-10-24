import AppKit
import UniformTypeIdentifiers
import YaosnapCore

@MainActor
final class SnipController {
    private struct PendingOutput {
        let displayID: UInt32
        let image: CGImage
    }

    private var windows: [SnipOverlayWindow] = []
    private var shots: [DisplayShot] = []
    /// 当前待输出选区，绑定提交它的屏幕。输出请求必须带同一 displayID。
    private var pendingOutput: PendingOutput?
    private var savePanel: NSSavePanel?
    private var isCursorHidden = false

    func start() {
        guard windows.isEmpty else { return }
        guard ScreenCaptureService.hasPermission() else {
            ScreenCaptureService.requestPermission()
            showPermissionAlert()
            return
        }
        let captures = ScreenCaptureService.captureAllDisplays()
        guard !captures.isEmpty else {
            showPermissionAlert()
            return
        }

        shots = captures
        pendingOutput = nil
        for shot in captures {
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
        guard !windows.isEmpty else {
            shots.removeAll()
            return
        }
        hideCursor()
        NSApp.activate(ignoringOtherApps: true)
        // 激活后确保首屏窗口成为 key window，接收键盘（Esc）。
        windows.first?.makeKey()
    }

    func cancel() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        shots.removeAll()
        pendingOutput = nil
        restoreCursor()
    }

    // MARK: - 输出

    /// 选区确定：按 displayID 找到冻结帧并裁剪，结果留给 Enter / 双击 / ⌘S。
    func commitSelection(_ notification: Notification) {
        pendingOutput = nil
        guard let info = notification.userInfo,
              let viewRect = info["viewRect"] as? CGRect,
              let viewHeight = info["viewHeight"] as? CGFloat,
              let scale = info["scale"] as? CGFloat,
              let displayID = info["displayID"] as? UInt32
        else {
            abortWithError("选区通知缺少必要字段")
            return
        }
        print("[snip] committed displayID=\(displayID) rect=\(viewRect)")

        guard let shot = shots.first(where: { $0.displayID == displayID }) else {
            abortWithError("displayID \(displayID) 没有对应的冻结帧")
            return
        }
        let imageRect = RectMath.imageRect(
            fromViewRect: viewRect,
            viewHeight: viewHeight,
            scale: scale
        )
        guard let cropped = ImageOutput.crop(shot.image, to: imageRect) else {
            abortWithError("裁剪失败 rect=\(imageRect) image=\(shot.image.width)x\(shot.image.height)")
            return
        }
        pendingOutput = PendingOutput(displayID: displayID, image: cropped)
    }

    func copyPendingImage(_ notification: Notification) {
        guard let pending = pendingOutput else { return }
        guard let displayID = notification.userInfo?["displayID"] as? UInt32,
              displayID == pending.displayID else {
            rejectMismatch("复制", notification: notification, pending: pending)
            return
        }
        guard ClipboardService.copyToPasteboard(pending.image) else {
            print("[snip] error: 写入剪贴板失败")
            NSSound.beep()
            return
        }
        print("[snip] copied")
        cancel()
    }

    func savePendingImage(_ notification: Notification) {
        guard let pending = pendingOutput, savePanel == nil else { return }
        guard let displayID = notification.userInfo?["displayID"] as? UInt32,
              displayID == pending.displayID else {
            rejectMismatch("保存", notification: notification, pending: pending)
            return
        }
        let parent = overlayWindow(for: displayID) ?? NSApp.keyWindow ?? windows.first
        guard let parent else {
            abortWithError("没有可用的覆盖窗口")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ImageOutput.defaultFileName()
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first

        savePanel = panel
        // 保存面板里需要可见鼠标
        restoreCursor()
        panel.beginSheetModal(for: parent) { [weak self] response in
            MainActor.assumeIsolated {
                self?.finishSave(response)
            }
        }
    }

    private func finishSave(_ response: NSApplication.ModalResponse) {
        let url = savePanel?.url
        savePanel = nil
        guard response == .OK else {
            print("[snip] save cancelled")
            resumeSessionAfterSavePanel()
            return
        }
        guard let url else {
            print("[snip] error: 保存面板未返回路径")
            NSSound.beep()
            resumeSessionAfterSavePanel()
            return
        }
        guard let image = pendingOutput?.image, let data = ImageOutput.pngData(from: image) else {
            print("[snip] error: PNG 编码失败")
            NSSound.beep()
            resumeSessionAfterSavePanel()
            return
        }
        do {
            try data.write(to: url)
            print("[snip] saved to \(url.path)")
            cancel()
        } catch {
            print("[snip] error: 写入 \(url.path) 失败: \(error.localizedDescription)")
            NSSound.beep()
            resumeSessionAfterSavePanel()
        }
    }

    private func resumeSessionAfterSavePanel() {
        guard !windows.isEmpty else { return }
        hideCursor()
    }

    private func abortWithError(_ message: String) {
        print("[snip] error: \(message)")
        NSSound.beep()
        cancel()
    }

    /// 输出请求来自另一块屏的覆盖层。拒绝，避免输出错屏内容。
    private func rejectMismatch(
        _ action: String,
        notification: Notification,
        pending: PendingOutput
    ) {
        let requested = notification.userInfo?["displayID"] as? UInt32
        print("[snip] error: \(action)请求 displayID=\(requested.map(String.init) ?? "缺失") 与待输出 displayID=\(pending.displayID) 不匹配")
        NSSound.beep()
    }

    private func overlayWindow(for displayID: UInt32?) -> SnipOverlayWindow? {
        guard let displayID else { return nil }
        return windows.first {
            ($0.contentView as? OverlayView)?.shot.displayID == displayID
        }
    }

    // MARK: - 光标

    // NSCursor.hide/unhide 是进程级计数，hide 与 unhide 必须严格成对，
    // 否则光标会在会话结束后永久消失。
    private func hideCursor() {
        guard !isCursorHidden else { return }
        isCursorHidden = true
        NSCursor.crosshair.set()
        NSCursor.hide()
    }

    private func restoreCursor() {
        guard isCursorHidden else { return }
        isCursorHidden = false
        NSCursor.arrow.set()
        NSCursor.unhide()
    }

    private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "请在 系统设置 → 隐私与安全性 → 屏幕录制 中勾选 Yaosnap，然后重启 Yaosnap 后重试。"
        alert.runModal()
    }
}
