import AppKit
import YaosnapCore

/// 无边框置顶贴图窗口。窗口尺寸、旋转、翻转与透明度都只由 transform 派生。
@MainActor
final class PinWindow: NSWindow {
    private let pinView = PinContentView(frame: .zero)
    let pasteImage: PasteImage
    /// 控制器分配的身份，分组与 Solo 只按它记账，不用窗口对象。
    let pinID: Int
    /// 多选与整组拖动由控制器协调，窗口只把交互意图转过去。
    weak var pinController: PinController?
    private(set) var transform: PinTransform = .identity
    /// 背景只影响绘制，不进入 transform，也不参与任何导出。
    private(set) var background: PinBackground = .transparent
    /// 是否在多选集合里；控制器是唯一写入口。
    private(set) var isMultiSelected = false
    /// Shift+Esc 销毁的贴图不进恢复列表，普通关闭才进。
    private(set) var canRestore = true
    /// 初始适配到屏幕 80% 后的尺寸。transform.scale 从 1 起，首次变换才不会跳回原图尺寸。
    let basePointSize: CGSize

    /// 每次裁剪前的保留区域，⌘Z 逐级退回。原始的 pasteImage 始终未改动。
    private var cropHistory: [CGRect?] = []
    private var imageCache: (key: ImageKey, image: CGImage, pointSize: CGSize)?

    private struct ImageKey: Equatable {
        let crop: CGRect?
        let grayscale: Bool
        let inverted: Bool
    }

    private var pixelSize: CGSize {
        CGSize(width: pasteImage.image.width, height: pasteImage.image.height)
    }

    /// topLeft 使用主屏左上角为原点的屏幕坐标（y 向下），与 CLI 的 --pos 一致。
    init(
        pasteImage: PasteImage,
        pinID: Int,
        screen: NSScreen,
        cascadeIndex: Int,
        topLeft requestedTopLeft: CGPoint? = nil
    ) {
        let visible = screen.visibleFrame
        let source = pasteImage.pointSize
        let fit = min(
            1,
            visible.width * 0.8 / max(1, source.width),
            visible.height * 0.8 / max(1, source.height)
        )
        let size = CGSize(
            width: max(1, floor(source.width * fit)),
            height: max(1, floor(source.height * fit))
        )
        basePointSize = size
        self.pasteImage = pasteImage
        self.pinID = pinID
        var origin: CGPoint
        if let requestedTopLeft {
            // 窗口 frame 的原点是左下角，而请求给的是左上角。
            origin = CGPoint(x: requestedTopLeft.x, y: requestedTopLeft.y - size.height)
        } else {
            // 后续贴图错开叠放，否则多张完全重合看不出有几张。
            let offset = CGFloat(cascadeIndex % 6) * 24
            origin = CGPoint(
                x: visible.midX - size.width / 2 + offset,
                y: visible.maxY - visible.height * 0.12 - size.height - offset
            )
        }
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        // 非整数原点会让 AppKit 把 frame 向外取整，尺寸凭空多 1 点。
        origin = CGPoint(x: floor(origin.x), y: floor(origin.y))

        super.init(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        configureWindow()

        pinView.baseSize = size
        refreshImage()
    }

    /// 从恢复列表重建。frame 与 transform 都取关闭时的原值，尺寸不再重新适配屏幕。
    init(pasteImage: PasteImage, pinID: Int, restoring entry: PinRestoreEntry) {
        basePointSize = entry.basePointSize
        self.pasteImage = pasteImage
        self.pinID = pinID
        super.init(
            contentRect: entry.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        configureWindow()
        transform = entry.transform
        alphaValue = entry.transform.opacity
        refreshImage()
        pinView.transform = entry.transform
        pinView.needsDisplay = true
    }

    private func configureWindow() {
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        contentView = pinView
        makeFirstResponder(pinView)
    }

    /// 销毁：关闭且不留下可恢复的副本。
    func destroy() {
        canRestore = false
        close()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func setScale(_ value: CGFloat) {
        transform.setScale(value)
        applyTransform()
    }

    func adjustScale(by delta: CGFloat) {
        transform.adjustScale(by: delta)
        applyTransform()
    }

    func rotate(byQuarterTurns turns: Int) {
        transform.rotate(byQuarterTurns: turns)
        applyTransform()
    }

    func toggleFlipHorizontal() {
        transform.toggleFlipHorizontal()
        applyTransform()
    }

    func toggleFlipVertical() {
        transform.toggleFlipVertical()
        applyTransform()
    }

    func setOpacity(_ value: CGFloat) {
        transform.setOpacity(value)
        applyTransform()
    }

    func adjustOpacity(by delta: CGFloat) {
        transform.adjustOpacity(by: delta)
        applyTransform()
    }

    func toggleThumbnail() {
        transform.toggleThumbnail()
        applyTransform()
    }

    func toggleGrayscale() {
        transform.toggleGrayscale()
        applyTransform()
    }

    func toggleInverted() {
        transform.toggleInverted()
        applyTransform()
    }

    func setBackground(_ mode: PinBackground) {
        guard background != mode else { return }
        background = mode
        pinView.background = mode
        pinView.needsDisplay = true
    }

    func cycleBackground() {
        setBackground(background.next())
        print("[pin] background=\(background.rawValue) pin=\(pinID)")
    }

    func setMultiSelected(_ selected: Bool) {
        guard isMultiSelected != selected else { return }
        isMultiSelected = selected
        pinView.isSelected = selected
    }

    func resetTransform() {
        transform.reset()
        cropHistory.removeAll()
        applyTransform()
    }

    /// 裁剪只改 transform 里的保留区域，原图不复制也不删。窗口左上角保持不动。
    @discardableResult
    func applyCrop(viewSelection: CGRect) -> Bool {
        guard !transform.isThumbnail,
              let selection = PinCrop.clampedSelection(viewSelection, in: pinView.bounds),
              let rect = PinCrop.pixelRect(
                  fromViewRect: selection,
                  viewSize: pinView.bounds.size,
                  imagePixelSize: pixelSize,
                  transform: transform,
                  basePointSize: basePointSize
              ) else { return false }
        cropHistory.append(transform.cropRect)
        transform.setCrop(rect)
        applyTransform(anchor: .topLeft)
        return true
    }

    @discardableResult
    func undoLastCrop() -> Bool {
        guard let previous = cropHistory.popLast() else { return false }
        transform.setCrop(previous)
        applyTransform(anchor: .topLeft)
        return true
    }

    /// 效果与裁剪都烘进同一张显示图，导出走同一份成品，而不是在视图上叠滤镜。
    private func refreshImage() {
        let key = ImageKey(
            crop: transform.cropRect,
            grayscale: transform.isGrayscale,
            inverted: transform.isInverted
        )
        if imageCache?.key != key {
            imageCache = (
                key,
                PinImageEffects.render(
                    pasteImage.image,
                    crop: key.crop,
                    grayscale: key.grayscale,
                    inverted: key.inverted
                ),
                transform.displayedSize(original: pasteImage.pointSize, imagePixelSize: pixelSize)
            )
        }
        guard let imageCache else { return }
        pinView.image = NSImage(cgImage: imageCache.image, size: imageCache.pointSize)
        pinView.baseSize = transform.displayedSize(
            original: basePointSize,
            imagePixelSize: pixelSize
        )
    }

    private enum Anchor {
        case center
        case topLeft
    }

    /// 以当前中心（裁剪时以左上角）为锚重设尺寸，再保证窗口留在屏幕可见区域。
    private func applyTransform(anchor: Anchor = .center) {
        pinView.transform = transform
        refreshImage()
        let size = transform.windowSize(base: pinView.baseSize)
        let oldFrame = frame
        alphaValue = transform.opacity
        let origin: CGPoint
        switch anchor {
        case .center:
            origin = CGPoint(
                x: floor(oldFrame.midX - size.width / 2),
                y: floor(oldFrame.midY - size.height / 2)
            )
        case .topLeft:
            origin = CGPoint(x: oldFrame.minX, y: oldFrame.maxY - size.height)
        }
        setFrame(
            CGRect(origin: origin, size: size),
            display: true
        )
        pinView.needsDisplay = true
        clampToVisibleFrame()
        invalidateCursorRects(for: pinView)
    }

    func clampToVisibleFrame() {
        guard let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let current = frame
        let x = min(max(current.minX, visible.minX), max(visible.minX, visible.maxX - current.width))
        let y = min(max(current.minY, visible.minY), max(visible.minY, visible.maxY - current.height))
        guard x != current.minX || y != current.minY else { return }
        setFrameOrigin(CGPoint(x: x, y: y))
    }
}

/// 键盘变换、双击关闭、边缘缩放、滚轮缩放与拖动移动。
@MainActor
private final class PinContentView: NSView {
    var image: NSImage?
    var baseSize: CGSize = .zero
    var transform: PinTransform = .identity
    var background: PinBackground = .transparent
    var isSelected = false {
        didSet {
            if isSelected != oldValue { needsDisplay = true }
        }
    }

    private var dragStart: NSPoint?
    private var windowStart: NSPoint?
    private var resizeState: ResizeState?
    private var isCropping = false
    private var cropStart: CGPoint?
    private var cropSelection: CGRect?

    private let hotZone: CGFloat = 8

    /// 棋盘格瓦片按模式缓存，颜色只有四种组合，重复构造 CGImage 是纯浪费。
    private static var checkerTiles: [PinBackground: CGImage] = [:]

    private struct ResizeState {
        let edge: PinEdge
        let anchorFraction: CGPoint
        let anchorGlobal: CGPoint
        let startMouse: CGPoint
        let baseSize: CGSize
        let quarterTurnsOdd: Bool
    }

    private enum PinEdge {
        case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight

        var anchorFraction: CGPoint {
            switch self {
            case .left: return CGPoint(x: 1, y: 0.5)
            case .right: return CGPoint(x: 0, y: 0.5)
            case .top: return CGPoint(x: 0.5, y: 0)
            case .bottom: return CGPoint(x: 0.5, y: 1)
            case .topLeft: return CGPoint(x: 1, y: 0)
            case .topRight: return CGPoint(x: 0, y: 0)
            case .bottomLeft: return CGPoint(x: 1, y: 1)
            case .bottomRight: return CGPoint(x: 0, y: 1)
            }
        }

        var isHorizontal: Bool {
            switch self {
            case .left, .right, .topLeft, .topRight, .bottomLeft, .bottomRight: return true
            case .top, .bottom: return false
            }
        }

        var isVertical: Bool {
            switch self {
            case .top, .bottom, .topLeft, .topRight, .bottomLeft, .bottomRight: return true
            case .left, .right: return false
            }
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawBackground(context)
        guard let image, baseSize.width > 0, baseSize.height > 0 else { return }
        let size = transform.unrotatedSize(base: baseSize)
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        // 先镜像再旋转，翻转才是按屏幕轴生效，而不是跟着图一起转。
        context.scaleBy(
            x: transform.flipHorizontal ? -1 : 1,
            y: transform.flipVertical ? -1 : 1
        )
        // AppKit 的 y 轴向上，负角表示顺时针。
        context.rotate(by: -CGFloat(transform.quarterTurns) * .pi / 2)
        image.draw(in: CGRect(
            x: -size.width / 2,
            y: -size.height / 2,
            width: size.width,
            height: size.height
        ))
        context.restoreGState()
        drawSelectionRing(context)
        drawCropOverlay(context)
    }

    /// 背景铺在图像之下；图像自身的透明区域会露出它。
    private func drawBackground(_ context: CGContext) {
        guard let fill = background.fill else { return }
        context.setFillColor(fill.cgColor)
        context.fill(bounds)
        guard let tile = Self.checkerTile(for: background) else { return }
        context.saveGState()
        // 瓦片是 16px 的整数倍图，最近邻放大才不会把 8pt 格子糊成灰边。
        context.interpolationQuality = .none
        context.draw(tile, in: bounds, byTiling: true)
        context.restoreGState()
    }

    private static func checkerTile(for mode: PinBackground) -> CGImage? {
        if let cached = checkerTiles[mode] { return cached }
        guard let base = mode.fill, let alternate = mode.checkerAlternate else { return nil }
        let cell = Int(PinBackground.checkerCellSize)
        let side = cell * 2
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(base.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(alternate.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: cell, height: cell))
        context.fill(CGRect(x: cell, y: cell, width: cell, height: cell))
        guard let image = context.makeImage() else { return nil }
        checkerTiles[mode] = image
        return image
    }

    private func drawSelectionRing(_ context: CGContext) {
        guard isSelected else { return }
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(2)
        context.stroke(bounds.insetBy(dx: 1, dy: 1))
    }

    /// 裁剪模式下压暗保留区之外，并画出选择框与操作提示。
    private func drawCropOverlay(_ context: CGContext) {
        guard isCropping else { return }
        let dim = NSColor.black.withAlphaComponent(0.45).cgColor
        context.setFillColor(dim)
        if let selection = cropSelection, selection.width > 0, selection.height > 0 {
            let outside = [
                CGRect(x: 0, y: 0, width: bounds.width, height: selection.minY),
                CGRect(x: 0, y: selection.maxY, width: bounds.width, height: bounds.height - selection.maxY),
                CGRect(x: 0, y: selection.minY, width: selection.minX, height: selection.height),
                CGRect(x: selection.maxX, y: selection.minY, width: bounds.width - selection.maxX, height: selection.height)
            ]
            for rect in outside where rect.width > 0 && rect.height > 0 {
                context.fill(rect)
            }
            // 白线外再压一圈深色，浅色贴图上也能看清边界。
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1)
            context.stroke(selection.insetBy(dx: 0.5, dy: 0.5))
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            context.stroke(selection.insetBy(dx: 1.5, dy: 1.5))
        } else {
            context.fill(bounds)
        }
        let hint = (isCropping && cropSelection == nil)
            ? "拖动选择保留区域，Esc 取消"
            : "松开确认，Esc 取消"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let text = hint as NSString
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: (bounds.width - textSize.width) / 2, y: bounds.height - textSize.height - 12),
            withAttributes: attributes
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard let pinWindow = window as? PinWindow else { return }
        pinWindow.makeKey()
        let point = convert(event.locationInWindow, from: nil)
        if isCropping {
            cropStart = point
            cropSelection = nil
            needsDisplay = true
            return
        }
        if event.clickCount == 2 {
            if event.modifierFlags.contains(.shift) {
                pinWindow.toggleThumbnail()
            } else {
                pinWindow.close()
            }
            return
        }
        // Shift 单击只改多选集合，不进入拖动或缩放。
        if event.modifierFlags.contains(.shift) {
            pinWindow.pinController?.toggleSelection(pinID: pinWindow.pinID)
            return
        }
        if let edge = edge(at: point) {
            beginResize(edge, in: pinWindow)
            return
        }
        resizeState = nil
        dragStart = pinWindow.convertPoint(toScreen: event.locationInWindow)
        windowStart = pinWindow.frame.origin
        pinWindow.pinController?.beginDrag(of: pinWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pinWindow = window as? PinWindow else { return }
        if isCropping {
            guard let cropStart else { return }
            let current = convert(event.locationInWindow, from: nil)
            cropSelection = CGRect(
                x: min(cropStart.x, current.x),
                y: min(cropStart.y, current.y),
                width: abs(current.x - cropStart.x),
                height: abs(current.y - cropStart.y)
            ).intersection(bounds)
            needsDisplay = true
            return
        }
        if let resizeState {
            updateResize(resizeState, in: pinWindow, mouse: NSEvent.mouseLocation)
            return
        }
        guard let dragStart, let windowStart else { return }
        let current = pinWindow.convertPoint(toScreen: event.locationInWindow)
        let delta = CGPoint(x: current.x - dragStart.x, y: current.y - dragStart.y)
        if pinWindow.pinController?.dragSelection(by: delta) == true { return }
        pinWindow.setFrameOrigin(CGPoint(
            x: windowStart.x + delta.x,
            y: windowStart.y + delta.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        if isCropping {
            let selection = cropSelection
            endCropMode()
            guard let selection, selection.width >= 1, selection.height >= 1,
                  let pinWindow = window as? PinWindow else { return }
            pinWindow.applyCrop(viewSelection: selection)
            return
        }
        dragStart = nil
        windowStart = nil
        resizeState = nil
        (window as? PinWindow)?.pinController?.endDrag()
    }

    private func beginCrop() {
        guard !transform.isThumbnail, let pinWindow = window as? PinWindow else { return }
        pinWindow.makeKey()
        isCropping = true
        cropStart = nil
        cropSelection = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        NSCursor.crosshair.set()
    }

    private func endCropMode() {
        isCropping = false
        cropStart = nil
        cropSelection = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let pinWindow = window as? PinWindow else { return nil }
        let menu = NSMenu()
        menu.addItem(effectItem(title: "灰度", isOn: transform.isGrayscale, action: #selector(toggleGrayscaleFromMenu)))
        menu.addItem(effectItem(title: "反色", isOn: transform.isInverted, action: #selector(toggleInvertedFromMenu)))

        let backgroundItem = NSMenuItem(title: "背景", action: nil, keyEquivalent: "")
        backgroundItem.submenu = makeBackgroundMenu(current: pinWindow.background)
        menu.addItem(backgroundItem)

        menu.addItem(.separator())
        let crop = NSMenuItem(title: "裁剪", action: #selector(beginCropFromMenu), keyEquivalent: "")
        crop.target = self
        crop.isEnabled = !transform.isThumbnail
        menu.addItem(crop)

        if let controller = pinWindow.pinController, controller.selectedPinCount > 0 {
            let join = NSMenuItem(title: "选中的贴图加入当前分组", action: #selector(joinSelectionFromMenu), keyEquivalent: "")
            join.target = self
            menu.addItem(join)
        }
        return menu
    }

    private func makeBackgroundMenu(current: PinBackground) -> NSMenu {
        let menu = NSMenu()
        for mode in PinBackground.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(backgroundSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func backgroundSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = PinBackground(rawValue: raw) else { return }
        (window as? PinWindow)?.setBackground(mode)
    }

    @objc private func joinSelectionFromMenu() {
        (window as? PinWindow)?.pinController?.joinSelectionToActiveGroup()
    }

    private func effectItem(title: String, isOn: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        return item
    }

    @objc private func toggleGrayscaleFromMenu() {
        (window as? PinWindow)?.toggleGrayscale()
    }

    @objc private func toggleInvertedFromMenu() {
        (window as? PinWindow)?.toggleInverted()
    }

    @objc private func beginCropFromMenu() {
        beginCrop()
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let pinWindow = window as? PinWindow, event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        pinWindow.resetTransform()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let pinWindow = window as? PinWindow else { return }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        if event.modifierFlags.contains(.control) {
            pinWindow.adjustOpacity(by: delta * 0.01)
        } else {
            pinWindow.setScale(pinWindow.transform.scale * exp(delta * 0.01))
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let pinWindow = window as? PinWindow else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            if isCropping {
                endCropMode()
            } else if event.modifierFlags.contains(.shift) {
                pinWindow.destroy()
            } else if pinWindow.pinController?.closeSelection(triggeredBy: pinWindow) == true {
                return
            } else {
                pinWindow.close()
            }
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.charactersIgnoringModifiers ?? ""
        let key = characters.lowercased()
        if flags.contains(.command) {
            if key == "z", pinWindow.undoLastCrop() { return }
            super.keyDown(with: event)
            return
        }
        if flags.contains(.control) {
            // Ctrl+W 的 characters 可能是控制字符，keyCode 更可靠。
            if event.keyCode == 13 || key == "w" {
                pinWindow.close()
                return
            }
            switch key {
            case "+", "=":
                pinWindow.adjustOpacity(by: 0.1)
            case "-", "_":
                pinWindow.adjustOpacity(by: -0.1)
            default:
                break
            }
            return
        }
        switch key {
        case "1":
            pinWindow.rotate(byQuarterTurns: -1)
        case "2":
            pinWindow.rotate(byQuarterTurns: 1)
        case "3":
            pinWindow.toggleFlipHorizontal()
        case "4":
            pinWindow.toggleFlipVertical()
        case "+", "=":
            pinWindow.adjustScale(by: 0.1)
        case "-", "_":
            pinWindow.adjustScale(by: -0.1)
        case "g":
            pinWindow.toggleGrayscale()
        case "i":
            pinWindow.toggleInverted()
        case "b":
            pinWindow.cycleBackground()
        case "c":
            beginCrop()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if isCropping {
            endCropMode()
            return
        }
        if let pinWindow = window as? PinWindow,
           pinWindow.pinController?.closeSelection(triggeredBy: pinWindow) == true {
            return
        }
        window?.close()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isCropping {
            addCursorRect(bounds, cursor: .crosshair)
            return
        }
        guard !transform.isThumbnail else { return }
        let bounds = self.bounds
        let hot = min(hotZone, min(bounds.width, bounds.height) / 2)
        guard hot > 0 else { return }
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: hot), cursor: .resizeUpDown)
        addCursorRect(
            NSRect(x: 0, y: bounds.height - hot, width: bounds.width, height: hot),
            cursor: .resizeUpDown
        )
        addCursorRect(
            NSRect(x: 0, y: hot, width: hot, height: max(0, bounds.height - hot * 2)),
            cursor: .resizeLeftRight
        )
        addCursorRect(
            NSRect(x: bounds.width - hot, y: hot, width: hot, height: max(0, bounds.height - hot * 2)),
            cursor: .resizeLeftRight
        )
        // AppKit 没有公开的对角缩放光标，四角用十字。
        addCursorRect(NSRect(x: 0, y: 0, width: hot, height: hot), cursor: .crosshair)
        addCursorRect(NSRect(x: bounds.width - hot, y: 0, width: hot, height: hot), cursor: .crosshair)
        addCursorRect(NSRect(x: 0, y: bounds.height - hot, width: hot, height: hot), cursor: .crosshair)
        addCursorRect(
            NSRect(x: bounds.width - hot, y: bounds.height - hot, width: hot, height: hot),
            cursor: .crosshair
        )
    }

    private func edge(at point: CGPoint) -> PinEdge? {
        guard !transform.isThumbnail else { return nil }
        let bounds = self.bounds
        let hot = min(hotZone, min(bounds.width, bounds.height) / 2)
        guard hot > 0 else { return nil }
        let nearLeft = point.x <= hot
        let nearRight = point.x >= bounds.maxX - hot
        let nearBottom = point.y <= hot
        let nearTop = point.y >= bounds.maxY - hot
        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearLeft && nearBottom { return .bottomLeft }
        if nearRight && nearBottom { return .bottomRight }
        if nearLeft { return .left }
        if nearRight { return .right }
        if nearTop { return .top }
        if nearBottom { return .bottom }
        return nil
    }

    private func beginResize(_ edge: PinEdge, in pinWindow: PinWindow) {
        let frame = pinWindow.frame
        let fraction = edge.anchorFraction
        resizeState = ResizeState(
            edge: edge,
            anchorFraction: fraction,
            anchorGlobal: CGPoint(
                x: frame.minX + fraction.x * frame.width,
                y: frame.minY + fraction.y * frame.height
            ),
            startMouse: NSEvent.mouseLocation,
            baseSize: pinWindow.basePointSize,
            quarterTurnsOdd: pinWindow.transform.quarterTurns % 2 == 1
        )
        dragStart = nil
        windowStart = nil
    }

    private func updateResize(_ state: ResizeState, in pinWindow: PinWindow, mouse: CGPoint) {
        let dx = abs(mouse.x - state.anchorGlobal.x)
        let dy = abs(mouse.y - state.anchorGlobal.y)
        // 窗口宽高相对未旋转基准轴的对应关系随四分之一圈互换。
        let widthBase = state.quarterTurnsOdd ? state.baseSize.height : state.baseSize.width
        let heightBase = state.quarterTurnsOdd ? state.baseSize.width : state.baseSize.height
        guard widthBase > 0, heightBase > 0 else { return }
        // 角上两个轴都参与，用位移更大的轴定尺度，否则纯纵向拖动会被没动过的横向距离锁死。
        let useHorizontal: Bool
        if state.edge.isHorizontal && state.edge.isVertical {
            let moveX = abs(mouse.x - state.startMouse.x)
            let moveY = abs(mouse.y - state.startMouse.y)
            useHorizontal = moveX >= moveY
        } else {
            useHorizontal = state.edge.isHorizontal
        }
        let rawScale = useHorizontal ? dx / widthBase : dy / heightBase
        pinWindow.setScale(rawScale)
        let frame = pinWindow.frame
        pinWindow.setFrameOrigin(CGPoint(
            x: state.anchorGlobal.x - state.anchorFraction.x * frame.width,
            y: state.anchorGlobal.y - state.anchorFraction.y * frame.height
        ))
        pinWindow.clampToVisibleFrame()
    }
}
