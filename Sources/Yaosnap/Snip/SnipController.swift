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
        /// 选区在源屏上的位置，成功输出后写进历史供重复上次区域使用。
        let region: CaptureRegion?
    }

    /// 打开保存面板时的快照。面板期间其他屏仍可提交，保存只能写这里的内容。
    private struct SaveJob {
        let panel: NSSavePanel
        let image: CGImage
        let displaySize: CGSize
        let region: CaptureRegion?
    }

    private var windows: [SnipOverlayWindow] = []
    private var shots: [DisplayShot] = []
    /// 最近成功输出的截图，只保留内存副本，供新会话回放。
    private var history: [CaptureHistoryEntry] = []
    private static let historyLimit = 10
    var historyCount: Int { history.count }
    /// 菜单栏与验收读取的历史快照，与 `,` `.` 回放共用这一份。
    var historySnapshot: [CaptureHistoryEntry] { history }
    var latestCapture: CaptureHistoryEntry? { history.first }
    var isActive: Bool { !windows.isEmpty }
    /// 当前待输出选区，绑定提交它的屏幕。输出请求必须带同一 displayID。
    private var pendingRegion: PendingRegion?
    private var saveJob: SaveJob?
    /// 系统分享面板。展示期间必须持有，否则回调前就被释放。
    private var sharePicker: NSSharingServicePicker?
    /// 快捷保存根目录。验收 harness 注入临时目录，生产用 ~/Pictures/Yaosnap。
    var quickSaveDirectory: URL?

    /// 延时截屏只跑计时器，到点才抓帧开会话，期间不显示覆盖层。
    private var delayDeadline: Date?
    private var delayTimer: Timer?

    var delayRemainingSeconds: Int? {
        guard let delayDeadline else { return nil }
        return max(0, Int(ceil(delayDeadline.timeIntervalSinceNow)))
    }

    /// 设置存储。验收 harness 可换成独立 suite 的实例。
    var settingsStore = SettingsStore()
    /// 十字光标是否生效。保存面板等场景需要临时恢复箭头。
    private var isCrosshairActive = false

    func start() {
        // 延时中再次触发视为取消，这是 Snipaste 的取舍：第二次按键不该再排一个延时。
        if delayDeadline != nil {
            cancelDelay()
            return
        }
        startSession(pickColor: false, replayIndex: nil, initialRegion: nil, whiteboard: nil)
    }

    /// CLI / URL 入口的白板会话。颜色缺省时取设置里的默认背景色。
    func startWhiteboard(color: RGBAColor?, activeScreen: Bool) {
        guard windows.isEmpty, delayDeadline == nil else { return }
        let resolved = WhiteboardSession(
            color: color ?? settingsStore.load().whiteboard.color,
            activeScreenOnly: activeScreen
        )
        print("[snip] whiteboard color=\(resolved.color.hexString) activeScreen=\(activeScreen)")
        startSession(
            pickColor: false,
            replayIndex: nil,
            initialRegion: nil,
            whiteboard: resolved
        )
    }

    func startPickColor() {
        startSession(pickColor: true, replayIndex: nil, initialRegion: nil, whiteboard: nil)
    }

    /// 从菜单历史进入：会话直接停在选中的那张，index 0 为最新。
    func startReplayingHistory(at index: Int) {
        guard history.indices.contains(index) else { return }
        startSession(pickColor: false, replayIndex: index + 1, initialRegion: nil, whiteboard: nil)
    }

    func startDelayed(seconds: Int) {
        guard DelayCapture.range.contains(seconds) else {
            NSSound.beep()
            return
        }
        guard windows.isEmpty else { return }
        if delayDeadline != nil {
            cancelDelay()
            return
        }
        print("[snip] delay \(seconds)s")
        delayDeadline = Date().addingTimeInterval(TimeInterval(seconds))
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.delayTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        delayTimer = timer
    }

    func cancelDelay() {
        guard delayDeadline != nil || delayTimer != nil else { return }
        delayTimer?.invalidate()
        delayTimer = nil
        delayDeadline = nil
        print("[snip] delay cancelled")
    }

    private func delayTick() {
        guard let deadline = delayDeadline, Date() >= deadline else { return }
        delayTimer?.invalidate()
        delayTimer = nil
        delayDeadline = nil
        startSession(pickColor: false, replayIndex: nil, initialRegion: nil, whiteboard: nil)
    }

    /// 用最顶层普通窗口的矩形开会话；拿不到候选时提示音而不是回退全屏。
    func startActiveWindow() {
        guard windows.isEmpty else { return }
        let all = WindowDetector.onScreenWindows(ownPID: getpid())
        guard let window = ActiveWindow.pick(from: all, ownPID: getpid()),
              let region = makeRegion(containing: window.bounds) else {
            print("[snip] 没有可用的活动窗口")
            NSSound.beep()
            return
        }
        print("[snip] active window \(window.ownerName) rect=\(window.bounds)")
        startSession(pickColor: false, replayIndex: nil, initialRegion: region, whiteboard: nil)
    }

    /// 上次选区映射到鼠标所在屏；没有历史或映射为空时提示音。
    func repeatLastRegion() {
        guard windows.isEmpty else { return }
        guard let last = history.first?.region,
              let displayID = displayUnderMouse() else {
            print("[snip] 重复上次区域失败：没有历史选区")
            NSSound.beep()
            return
        }
        let bounds = CGDisplayBounds(displayID)
        let mapped = RepeatRegion.map(last, onto: bounds)
        guard !mapped.isEmpty else {
            NSSound.beep()
            return
        }
        print("[snip] repeat last region \(mapped)")
        startSession(
            pickColor: false,
            replayIndex: nil,
            initialRegion: CaptureRegion(displayID: displayID, rect: mapped, displayBounds: bounds),
            whiteboard: nil
        )
    }

    private func displayUnderMouse() -> CGDirectDisplayID? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main,
              let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber else { return nil }
        return number.uint32Value
    }

    /// 窗口矩形可能带阴影、跨屏或贴边；取重叠面积最大的屏并裁到屏内。
    private func makeRegion(containing rect: CGRect) -> CaptureRegion? {
        var best: (id: CGDirectDisplayID, bounds: CGRect, area: CGFloat)?
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            let bounds = CGDisplayBounds(id)
            let overlap = rect.intersection(bounds)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > (best?.area ?? 0) {
                best = (id, bounds, area)
            }
        }
        guard let best else { return nil }
        let clamped = RectMath.clamp(rect, to: best.bounds)
        guard !clamped.isEmpty else { return nil }
        return CaptureRegion(displayID: best.id, rect: clamped, displayBounds: best.bounds)
    }

    private func startSession(
        pickColor: Bool,
        replayIndex: Int?,
        initialRegion: CaptureRegion?,
        whiteboard: WhiteboardSession?
    ) {
        print("[snip] start called\(pickColor ? " (pick-color)" : "")")
        guard windows.isEmpty else { return }
        guard ScreenCaptureService.hasPermission() else {
            print("[snip] no screen capture permission")
            ScreenCaptureService.requestPermission()
            showPermissionAlert()
            return
        }
        let settings = settingsStore.load()
        // 显式白板会话优先；没有显式请求时由设置里的全局开关决定。
        let activeWhiteboard = whiteboard
            ?? (settings.whiteboard.enabled
                ? WhiteboardSession(color: settings.whiteboard.color)
                : nil)
        let mouse = NSEvent.mouseLocation
        let keyDisplayID = displayUnderMouse()
        let captures = preparedCaptures(
            whiteboard: activeWhiteboard,
            activeDisplayID: keyDisplayID
        )
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
            let initialHistory = shot.displayID == keyDisplayID ? replayIndex ?? 0 : 0
            let view = OverlayView(
                shot: shot,
                history: history,
                pickColorMode: pickColor,
                initialHistoryIndex: initialHistory,
                whiteboardMode: activeWhiteboard != nil
            )
            view.autoSelectOnCreation = settings.autoSelectOnCreation
            view.elementDetectionEnabled = settings.detectUIElements
            view.selectionAspectRatio = settings.selectionAspectRatio
            if pickColor {
                view.onPickColor = { [weak self] in self?.cancel() }
            }
            window.contentView = view
            window.makeFirstResponder(window.contentView)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
            shots.append(shot)
            // 预置选区必须等 shots 入列：提交通知会按 displayID 回查冻结帧。
            if let initialRegion, initialRegion.displayID == shot.displayID {
                let clamped = RectMath.clamp(initialRegion.rect, to: shot.bounds)
                view.applyInitialSelection(RectMath.toViewRect(
                    globalRect: clamped,
                    displayBounds: shot.bounds,
                    viewHeight: shot.bounds.height
                ))
            }
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
        let keyWindow = windows.first { $0.screen?.frame.contains(mouse) == true } ?? windows.first
        keyWindow?.makeKey()
    }

    /// 白板模式只替换冻结帧，像素尺寸保持不变，裁剪与多屏几何不用改。
    /// --active-screen 时先按光标所在屏过滤，白板会话不会在其余屏留下覆盖层。
    private func preparedCaptures(
        whiteboard: WhiteboardSession?,
        activeDisplayID: CGDirectDisplayID?
    ) -> [DisplayShot] {
        let shots = ScreenCaptureService.captureAllDisplays()
        guard let whiteboard else { return shots }
        let selected = whiteboard.activeScreenOnly
            ? shots.filter { $0.displayID == activeDisplayID }
            : shots
        return selected.map { shot in
            guard let solid = WhiteboardImage.make(
                width: shot.image.width,
                height: shot.image.height,
                color: whiteboard.color
            ) else { return shot }
            return DisplayShot(
                displayID: shot.displayID,
                image: solid,
                bounds: shot.bounds,
                scale: shot.scale
            )
        }
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
        sharePicker = nil
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
        let displayBounds = shots.first { $0.displayID == displayID }?.bounds
        let region = displayBounds.map {
            CaptureRegion(
                displayID: displayID,
                rect: RectMath.toGlobalRect(
                    viewRect: viewRect,
                    displayBounds: $0,
                    viewHeight: viewHeight
                ),
                displayBounds: $0
            )
        }
        pendingRegion = PendingRegion(
            displayID: displayID,
            viewRect: viewRect,
            sourceImage: sourceImage,
            cropRectPx: cropRectPx,
            scale: outputScale,
            region: region
        )
    }

    func copyPendingImage(_ notification: Notification) {
        guard let pending = validatedPending(for: notification, action: "复制") else { return }
        let settings = settingsStore.load()
        guard let image = renderPendingOutput(
            pending,
            applyShadow: settings.exportShadow
        ) else {
            abortWithError("合成标注图像失败")
            return
        }
        let optionHeld = (notification.userInfo?[.modifierFlags] as? NSEvent.ModifierFlags)?
            .contains(.option) ?? false
        let copied = settings.copyAsFileTrigger.copiesAsFile(optionHeld: optionHeld)
            ? ClipboardService.copyFile(image, scale: pending.scale)
            : ClipboardService.copyToPasteboard(image, scale: pending.scale)
        guard copied else {
            print("[snip] error: 写入剪贴板失败")
            NSSound.beep()
            return
        }
        print("[snip] copied")
        remember(image, displaySize: pending.viewRect.size, region: pending.region)
        cancel()
    }

    func savePendingImage(_ notification: Notification) {
        guard saveJob == nil,
              let pending = validatedPending(for: notification, action: "保存") else { return }
        guard let image = renderPendingOutput(
            pending,
            applyShadow: settingsStore.load().exportShadow
        ) else {
            abortWithError("合成标注图像失败")
            return
        }
        if notification.userInfo?[.quickSave] as? Bool == true {
            quickSave(image, displaySize: pending.viewRect.size, region: pending.region)
            return
        }
        let parent = overlayWindow(for: pending.displayID) ?? NSApp.keyWindow ?? windows.first
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
            displaySize: pending.viewRect.size,
            region: pending.region
        )
        // 保存面板里需要可见鼠标
        setCrosshair(false)
        panel.beginSheetModal(for: parent) { [weak self] response in
            MainActor.assumeIsolated {
                self?.finishSave(response)
            }
        }
    }

    /// 分享：与复制同一张导出图，交给系统分享选择器。
    func sharePendingImage(_ notification: Notification) {
        guard let pending = validatedPending(for: notification, action: "分享") else { return }
        guard let image = renderPendingOutput(
            pending,
            applyShadow: settingsStore.load().exportShadow
        ) else {
            abortWithError("合成标注图像失败")
            return
        }
        let pointSize = CGSize(
            width: CGFloat(image.width) / pending.scale,
            height: CGFloat(image.height) / pending.scale
        )
        let shareImage = NSImage(cgImage: image, size: pointSize)
        guard !NSSharingService.sharingServices(forItems: [shareImage]).isEmpty else {
            print("[snip] 没有可用的分享服务")
            NSSound.beep()
            return
        }
        guard let view = overlayWindow(for: pending.displayID)?.contentView as? OverlayView else {
            abortWithError("没有可用的覆盖窗口")
            return
        }
        let picker = NSSharingServicePicker(items: [shareImage])
        sharePicker = picker
        picker.show(relativeTo: view.selectionRect, of: view, preferredEdge: .minY)
    }

    /// 提取选区文字。Vision 在后台跑，识别完回主线程写剪贴板并提示。
    func recognizeTextPending(_ notification: Notification) {
        guard let pending = validatedPending(for: notification, action: "提取文字") else { return }
        guard let image = renderPendingOutput(pending, applyShadow: false) else {
            NSSound.beep()
            return
        }
        let displayID = pending.displayID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = TextRecognizer.recognizeText(in: image)
            Task { @MainActor in
                self?.finishTextRecognition(text, displayID: displayID)
            }
        }
    }

    /// 识别选区里的二维码 / 条形码。
    func scanBarcodePending(_ notification: Notification) {
        guard let pending = validatedPending(for: notification, action: "识别码") else { return }
        guard let image = renderPendingOutput(pending, applyShadow: false) else {
            NSSound.beep()
            return
        }
        let displayID = pending.displayID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let payload = BarcodeScanner.scanFirstPayload(in: image)
            Task { @MainActor in
                self?.finishBarcodeScan(payload, displayID: displayID)
            }
        }
    }

    private func finishTextRecognition(_ text: String, displayID: UInt32) {
        guard !text.isEmpty else {
            print("[snip] 文字识别没有结果")
            NSSound.beep()
            return
        }
        guard ClipboardService.copyString(text) else {
            print("[snip] error: 文字写入剪贴板失败")
            NSSound.beep()
            return
        }
        print("[snip] 提取文字 \(text.count) 字")
        (overlayWindow(for: displayID)?.contentView as? OverlayView)?
            .showToolbarMessage("文字已复制")
    }

    private func finishBarcodeScan(_ payload: String?, displayID: UInt32) {
        guard let payload, !payload.isEmpty else {
            // Snipaste 的扫码失败行为：清空系统剪贴板。
            ClipboardService.clear()
            print("[snip] 没有识别到二维码 / 条形码，已清空剪贴板")
            NSSound.beep()
            return
        }
        guard ClipboardService.copyString(payload) else {
            print("[snip] error: 识别结果写入剪贴板失败")
            NSSound.beep()
            return
        }
        print("[snip] 识别码 \(payload.count) 字符")
        (overlayWindow(for: displayID)?.contentView as? OverlayView)?
            .showToolbarMessage("识别码已复制")
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
            remember(job.image, displaySize: job.displaySize, region: job.region)
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

    /// ⌘ + 保存按钮：直接写快捷保存目录，成功路径与面板保存一致，只是不弹面板。
    private func quickSave(_ image: CGImage, displaySize: CGSize, region: CaptureRegion?) {
        guard let data = ImageOutput.pngData(from: image) else {
            print("[snip] error: PNG 编码失败")
            NSSound.beep()
            resumeSessionAfterSavePanel()
            return
        }
        let store = quickSaveDirectory.map { QuickSaveStore(directory: $0) } ?? QuickSaveStore()
        do {
            let url = try store.write(data)
            print("[snip] quick saved to \(url.path)")
            remember(image, displaySize: displaySize, region: region)
            NSSound(named: "Glass")?.play()
            cancel()
        } catch {
            print("[snip] error: 快捷保存失败: \(error.localizedDescription)")
            NSSound.beep()
            resumeSessionAfterSavePanel()
        }
    }

    // MARK: - 命令行

    func copyLatestCapture() {
        guard let entry = recentCaptureOrReport("复制") else { return }
        guard ClipboardService.copyToPasteboard(entry.image, scale: entry.scaleX) else {
            print("[cli] error: 最近截图写入剪贴板失败")
            NSSound.beep()
            return
        }
        print("[cli] 最近截图已复制")
    }

    func saveLatestCapture(to path: String) {
        guard let entry = recentCaptureOrReport("保存") else { return }
        guard let data = ImageOutput.pngData(from: entry.image) else {
            print("[cli] error: PNG 编码失败")
            NSSound.beep()
            return
        }
        let url = URL(fileURLWithPath: path)
        do {
            try data.write(to: url)
            print("[cli] 最近截图已保存到 \(url.path)")
        } catch {
            print("[cli] error: 写入 \(url.path) 失败: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    func quickSaveLatestCapture() {
        guard let entry = recentCaptureOrReport("快捷保存") else { return }
        guard let data = ImageOutput.pngData(from: entry.image) else {
            print("[cli] error: PNG 编码失败")
            NSSound.beep()
            return
        }
        let store = quickSaveDirectory.map { QuickSaveStore(directory: $0) } ?? QuickSaveStore()
        do {
            let url = try store.write(data)
            print("[cli] 最近截图已快捷保存到 \(url.path)")
            NSSound(named: "Glass")?.play()
        } catch {
            print("[cli] error: 快捷保存失败: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    /// 全屏抓取后逐屏识别，命中第一条结果就写入剪贴板。
    func scanScreenForBarcode() {
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
        let images = captures.map(\.image)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var payload: String?
            for image in images {
                if let found = BarcodeScanner.scanFirstPayload(in: image) {
                    payload = found
                    break
                }
            }
            Task { @MainActor in
                self?.finishScreenBarcodeScan(payload)
            }
        }
    }

    private func finishScreenBarcodeScan(_ payload: String?) {
        guard let payload, !payload.isEmpty else {
            ClipboardService.clear()
            print("[cli] 屏幕上没有识别到二维码 / 条形码，已清空剪贴板")
            NSSound.beep()
            return
        }
        guard ClipboardService.copyString(payload) else {
            print("[cli] error: 识别结果写入剪贴板失败")
            NSSound.beep()
            return
        }
        print("[cli] 识别码 \(payload.count) 字符")
    }

    private func recentCaptureOrReport(_ action: String) -> CaptureHistoryEntry? {
        guard let entry = history.first else {
            print("[cli] \(action)失败：还没有成功输出的截图")
            NSSound.beep()
            return nil
        }
        return entry
    }

    private func abortWithError(_ message: String) {
        print("[snip] error: \(message)")
        NSSound.beep()
        cancel()
    }

    /// 复制 / 保存 / 分享共用的最终图合成：输出源裁剪 + 该屏画布上的标注。
    /// 阴影边距按输出像素缩放，24pt / 12pt 在 Retina 上仍是观感一致的尺寸。
    private func renderPendingOutput(_ pending: PendingRegion, applyShadow: Bool) -> CGImage? {
        let annotations = (overlayWindow(for: pending.displayID)?.contentView as? OverlayView)?
            .annotations ?? []
        guard let rendered = AnnotationExport.flatten(
            base: pending.sourceImage,
            cropRectPx: pending.cropRectPx,
            annotations: annotations,
            scale: pending.scale
        ) else { return nil }
        guard applyShadow else { return rendered }
        return ImageShadow.apply(
            to: rendered,
            margin: ImageShadow.defaultMargin * pending.scale,
            blur: ImageShadow.defaultBlur * pending.scale
        )
    }

    /// 最近成功输出的截图按时间倒序保留，最多 10 张。
    private func remember(_ image: CGImage, displaySize: CGSize, region: CaptureRegion?) {
        history.insert(
            CaptureHistoryEntry(image: image, displaySize: displaySize, region: region),
            at: 0
        )
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
    }

    /// 复制 / 保存 / 识别共用：取本屏待输出选区，核对请求来源。
    private func validatedPending(
        for notification: Notification,
        action: String
    ) -> PendingRegion? {
        guard let pending = pendingRegion else { return nil }
        guard let displayID = notification.userInfo?[.displayID] as? UInt32,
              displayID == pending.displayID else {
            rejectMismatch(action, notification: notification, pending: pending)
            return nil
        }
        return pending
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
