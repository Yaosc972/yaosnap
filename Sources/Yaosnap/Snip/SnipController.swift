import AppKit
import UniformTypeIdentifiers
import YaosnapCore

@MainActor
final class SnipController {
    private var windows: [SnipOverlayWindow] = []
    private var shots: [DisplayShot] = []
    /// 当前已确定选区对应的裁剪结果。snipCommitted 时写入，会话结束时清空。
    private var pendingImage: CGImage?
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
        pendingImage = nil
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
        pendingImage = nil
        restoreCursor()
    }

    // MARK: - 输出

    /// 选区确定：按 displayID 找到冻结帧并裁剪，结果留给 Enter / 双击 / ⌘S。
    func commitSelection(_ notification: Notification) {
        pendingImage = nil
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
        pendingImage = cropped
    }

    func copyPendingImage() {
        guard let image = pendingImage else { return }
        guard ClipboardService.copyToPasteboard(image) else {
            print("[snip] error: 写入剪贴板失败")
            NSSound.beep()
            return
        }
        print("[snip] copied")
        cancel()
    }

    func savePendingImage(_ notification: Notification) {
        guard pendingImage != nil, savePanel == nil else { return }
        let displayID = notification.userInfo?["displayID"] as? UInt32
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
        guard let image = pendingImage, let data = ImageOutput.pngData(from: image) else {
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
