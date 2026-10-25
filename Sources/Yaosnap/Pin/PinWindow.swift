import AppKit
import YaosnapCore

/// 无边框置顶贴图窗口。窗口尺寸、旋转、翻转与透明度都只由 transform 派生。
@MainActor
final class PinWindow: NSWindow {
    private let pinView = PinContentView(frame: .zero)
    let pasteImage: PasteImage
    private(set) var transform: PinTransform = .identity
    /// Shift+Esc 销毁的贴图不进恢复列表，普通关闭才进。
    private(set) var canRestore = true
    /// 初始适配到屏幕 80% 后的尺寸。transform.scale 从 1 起，首次变换才不会跳回原图尺寸。
    let basePointSize: CGSize

    /// topLeft 使用主屏左上角为原点的屏幕坐标（y 向下），与 CLI 的 --pos 一致。
    init(pasteImage: PasteImage, screen: NSScreen, cascadeIndex: Int, topLeft requestedTopLeft: CGPoint? = nil) {
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
        pinView.image = NSImage(cgImage: pasteImage.image, size: pasteImage.pointSize)
    }

    /// 从恢复列表重建。frame 与 transform 都取关闭时的原值，尺寸不再重新适配屏幕。
    init(pasteImage: PasteImage, restoring entry: PinRestoreEntry) {
        basePointSize = entry.basePointSize
        self.pasteImage = pasteImage
        super.init(
            contentRect: entry.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        configureWindow()
        transform = entry.transform
        alphaValue = entry.transform.opacity
        pinView.baseSize = entry.basePointSize
        pinView.image = NSImage(cgImage: pasteImage.image, size: pasteImage.pointSize)
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

    func resetTransform() {
        transform.reset()
        applyTransform()
    }

    /// 以当前中心为锚重设尺寸，再保证窗口留在屏幕可见区域。
    private func applyTransform() {
        pinView.transform = transform
        let size = transform.windowSize(base: basePointSize)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        alphaValue = transform.opacity
        setFrame(
            CGRect(
                x: floor(center.x - size.width / 2),
                y: floor(center.y - size.height / 2),
                width: size.width,
                height: size.height
            ),
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

    private var dragStart: NSPoint?
    private var windowStart: NSPoint?
    private var resizeState: ResizeState?

    private let hotZone: CGFloat = 8

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
        guard let image, baseSize.width > 0, baseSize.height > 0,
              let context = NSGraphicsContext.current?.cgContext else { return }
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
    }

    override func mouseDown(with event: NSEvent) {
        guard let pinWindow = window as? PinWindow else { return }
        if event.clickCount == 2 {
            if event.modifierFlags.contains(.shift) {
                pinWindow.toggleThumbnail()
            } else {
                pinWindow.close()
            }
            return
        }
        pinWindow.makeKey()
        let point = convert(event.locationInWindow, from: nil)
        if let edge = edge(at: point) {
            beginResize(edge, in: pinWindow)
            return
        }
        resizeState = nil
        dragStart = NSEvent.mouseLocation
        windowStart = pinWindow.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pinWindow = window as? PinWindow else { return }
        if let resizeState {
            updateResize(resizeState, in: pinWindow, mouse: NSEvent.mouseLocation)
            return
        }
        guard let dragStart, let windowStart else { return }
        let current = NSEvent.mouseLocation
        pinWindow.setFrameOrigin(CGPoint(
            x: windowStart.x + current.x - dragStart.x,
            y: windowStart.y + current.y - dragStart.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        windowStart = nil
        resizeState = nil
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
            if event.modifierFlags.contains(.shift) {
                pinWindow.destroy()
            } else {
                pinWindow.close()
            }
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.charactersIgnoringModifiers ?? ""
        if flags.contains(.control) {
            // Ctrl+W 的 characters 可能是控制字符，keyCode 更可靠。
            if event.keyCode == 13 || characters.lowercased() == "w" {
                pinWindow.close()
                return
            }
            switch characters {
            case "+", "=":
                pinWindow.adjustOpacity(by: 0.1)
            case "-", "_":
                pinWindow.adjustOpacity(by: -0.1)
            default:
                break
            }
            return
        }
        switch characters {
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
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        window?.close()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
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
