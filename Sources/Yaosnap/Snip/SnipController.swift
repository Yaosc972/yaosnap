import AppKit
import UniformTypeIdentifiers
import YaosnapCore

@MainActor
final class SnipController {
    /// 已确定的选区。提交时只记信息，复制 / 保存时才拉标注并合成最终图，
    /// 让标注改动无需重新提交选区。
    private struct PendingRegion {
        let displayID: CGDirectDisplayID
        let viewRect: CGRect
        /// 输出源可以是当前屏冻结帧，也可以是回放中的历史截图。
        let sourceImage: CGImage
        let cropRectPx: CGRect
        let scale: CGFloat
    }

    /// 打开保存面板时的快照。面板期间其他屏仍可提交，保存只能写这里的内容。
    private struct SaveJob {
        let panel: NSSavePanel
        let image: CGImage
        let displaySize: CGSize
    }

    private var windows: [SnipOverlayWindow] = []
    private var shots: [DisplayShot] = []
    /// 最近成功输出的截图，只保留内存副本，供新会话回放。
    private var history: [CaptureHistoryEntry] = []
    private static let historyLimit = 10
    var historyCount: Int { history.count }
    /// 当前待输出选区，绑定提交它的屏幕。输出请求必须带同一 displayID。
    private var pendingRegion: PendingRegion?
    private var saveJob: SaveJob?
    /// 十字光标是否生效。保存面板等场景需要临时恢复箭头。
    private var isCrosshairActive = false

    func start() {
        print("[snip] start called")
        guard windows.isEmpty else { return }
        guard ScreenCaptureService.hasPermission() else {
            print("[snip] no screen capture permission")
            ScreenCaptureService.requestPermission()
            showPermissionAlert()
            return
        }
        let captures = ScreenCaptureService.captureAllDisplays()
        guard !captures.isEmpty else {
            showCaptureEmptyAlert()
            return
        }

        shots = []
        pendingRegion = nil
        for shot in captures {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                    .uint32Value == shot.displayID
            }) else {
                print("[snip] warning: displayID=\(shot.displayID) 未匹配到 NSScreen，跳过该屏覆盖层")
                continue
            }
            let window = SnipOverlayWindow(screen: screen)
            window.contentView = OverlayView(shot: shot, history: history)
            window.makeFirstResponder(window.contentView)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
            shots.append(shot)
        }
        if windows.count != captures.count {
            print("[snip] warning: 捕获 \(captures.count) 屏，实际覆盖 \(windows.count) 屏")
        }
        guard !windows.isEmpty else {
            shots.removeAll()
            return
        }
        setCrosshair(true)
        NSApp.activate(ignoringOtherApps: true)
        // 键盘事件交给鼠标所在屏的覆盖层，多屏时 Esc / Enter 落在用户正在看的屏。
        let mouse = NSEvent.mouseLocation
        let keyWindow = windows.first { $0.screen?.frame.contains(mouse) == true } ?? windows.first
        keyWindow?.makeKey()
    }

    func cancel() {
        if let job = saveJob {
            saveJob = nil
            job.panel.cancel(nil)
        }
        // 先复位光标：setCrosshair 依赖 windows 里的视图，清空数组后就漏掉了。
        setCrosshair(false)
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        shots.removeAll()
        pendingRegion = nil
    }

    // MARK: - 输出

    /// 选区确定：按 displayID 记住选区信息，输出时再合成图像。
    func commitSelection(_ notification: Notification) {
        pendingRegion = nil
        guard let info = notification.userInfo,
              let viewRect = info[.viewRect] as? CGRect,
              let viewHeight = info[.viewHeight] as? CGFloat,
              let scale = info[.scale] as? CGFloat,
              let displayID = info[.displayID] as? UInt32
        else {
            abortWithError("选区通知缺少必要字段")
            return
        }
        print("[snip] committed displayID=\(displayID) rect=\(viewRect)")

        guard let shot = shots.first(where: { $0.displayID == displayID }) else {
            abortWithError("displayID \(displayID) 没有对应的冻结帧")
            return
        }
        // 新会话带历史回放时，覆盖层给出实际显示图与像素裁剪矩形；旧通知退回冻结帧。
        let sourceImage: CGImage
        if let raw = info[.sourceImage] {
            sourceImage = raw as! CGImage
        } else {
            sourceImage = shot.image
        }
        let cropRectPx = info[.cropRectPx] as? CGRect
            ?? RectMath.imageRect(fromViewRect: viewRect, viewHeight: viewHeight, scale: shot.scale)
        let outputScale = viewRect.width > 0 ? cropRectPx.width / viewRect.width : scale
        pendingRegion = PendingRegion(
            displayID: displayID,
            viewRect: viewRect,
            sourceImage: sourceImage,
            cropRectPx: cropRectPx,
            scale: outputScale
        )
    }

    func copyPendingImage(_ notification: Notification) {
        guard let pending = pendingRegion else { return }
        guard let displayID = notification.userInfo?[.displayID] as? UInt32,
              displayID == pending.displayID else {
            rejectMismatch("复制", notification: notification, pending: pending)
            return
        }
        guard let image = renderPendingOutput(pending) else {
            abortWithError("合成标注图像失败")
            return
        }
        guard ClipboardService.copyToPasteboard(image, scale: pending.scale) else {
            print("[snip] error: 写入剪贴板失败")
            NSSound.beep()
            return
        }
        print("[snip] copied")
        remember(image, displaySize: pending.viewRect.size)
        cancel()
    }

    func savePendingImage(_ notification: Notification) {
        guard let pending = pendingRegion, saveJob == nil else { return }
        guard let displayID = notification.userInfo?[.displayID] as? UInt32,
              displayID == pending.displayID else {
            rejectMismatch("保存", notification: notification, pending: pending)
            return
        }
        guard let image = renderPendingOutput(pending) else {
            abortWithError("合成标注图像失败")
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

        saveJob = SaveJob(
            panel: panel,
            image: image,
            displaySize: pending.viewRect.size
        )
        // 保存面板里需要可见鼠标
        setCrosshair(false)
        panel.beginSheetModal(for: parent) { [weak self] response in
            MainActor.assumeIsolated {
                self?.finishSave(response)
            }
        }
    }

    private func finishSave(_ response: NSApplication.ModalResponse) {
        guard let job = saveJob else { return }
        saveJob = nil
        let url = job.panel.url
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
        guard let data = ImageOutput.pngData(from: job.image) else {
            print("[snip] error: PNG 编码失败")
            NSSound.beep()
            resumeSessionAfterSavePanel()
            return
        }
        do {
            try data.write(to: url)
            print("[snip] saved to \(url.path)")
            remember(job.image, displaySize: job.displaySize)
            cancel()
        } catch {
            print("[snip] error: 写入 \(url.path) 失败: \(error.localizedDescription)")
            NSSound.beep()
            resumeSessionAfterSavePanel()
        }
    }

    private func resumeSessionAfterSavePanel() {
        guard !windows.isEmpty else { return }
        setCrosshair(true)
    }

    private func abortWithError(_ message: String) {
        print("[snip] error: \(message)")
        NSSound.beep()
        cancel()
    }

    /// 复制 / 保存共用的最终图合成：输出源裁剪 + 该屏画布上的标注。
    private func renderPendingOutput(_ pending: PendingRegion) -> CGImage? {
        let annotations = (overlayWindow(for: pending.displayID)?.contentView as? OverlayView)?
            .annotations ?? []
        return AnnotationExport.flatten(
            base: pending.sourceImage,
            cropRectPx: pending.cropRectPx,
            annotations: annotations,
            scale: pending.scale
        )
    }

    /// 最近成功输出的截图按时间倒序保留，最多 10 张。
    private func remember(_ image: CGImage, displaySize: CGSize) {
        history.insert(CaptureHistoryEntry(image: image, displaySize: displaySize), at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
    }

    /// 输出请求来自另一块屏的覆盖层。拒绝，避免输出错屏内容。
    private func rejectMismatch(
        _ action: String,
        notification: Notification,
        pending: PendingRegion
    ) {
        let requested = notification.userInfo?[.displayID] as? UInt32
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

    // 十字光标通过 cursor rect 实现，不能调用 NSCursor.hide：
    // hide 会把光标整个藏掉，且是进程级计数，恢复不当时光标永久消失。
    private func setCrosshair(_ active: Bool) {
        guard isCrosshairActive != active else { return }
        isCrosshairActive = active
        for window in windows {
            guard let view = window.contentView as? OverlayView else { continue }
            view.showsCrosshair = active
        }
        if active {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "请在 系统设置 → 隐私与安全性 → 屏幕录制 中勾选 Yaosnap，然后重启 Yaosnap 后重试。"
        alert.runModal()
    }

    /// 有权限却拿不到图像是另一类故障，不能继续提示去开权限。
    private func showCaptureEmptyAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "屏幕捕获返回空"
        alert.informativeText = "已获得屏幕录制权限，但系统没有返回任何屏幕图像。请重启 Yaosnap 后重试；若仍失败，请在 系统设置 → 隐私与安全性 → 屏幕录制 中取消勾选再重新勾选 Yaosnap。"
        alert.runModal()
    }
}
