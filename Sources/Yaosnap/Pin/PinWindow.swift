import AppKit
import YaosnapCore

/// 无边框置顶贴图窗口。内容按图像点尺寸显示，超大图在初始化时缩到屏幕的 80%。
@MainActor
final class PinWindow: NSWindow {
    private let pinView = PinContentView(frame: .zero)

    init(pasteImage: PasteImage, screen: NSScreen, cascadeIndex: Int) {
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
        // 后续贴图错开叠放，否则多张完全重合看不出有几张。
        let offset = CGFloat(cascadeIndex % 6) * 24
        var origin = CGPoint(
            x: visible.midX - size.width / 2 + offset,
            y: visible.maxY - visible.height * 0.12 - size.height - offset
        )
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
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false

        pinView.image = NSImage(cgImage: pasteImage.image, size: pasteImage.pointSize)
        contentView = pinView
        makeFirstResponder(pinView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 双击关闭、Esc 关闭，单击拖动窗口。
@MainActor
private final class PinContentView: NSView {
    var image: NSImage?
    private var dragStart: NSPoint?
    private var windowStart: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.close()
            return
        }
        window?.makeKey()
        dragStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let windowStart else { return }
        let current = NSEvent.mouseLocation
        window?.setFrameOrigin(CGPoint(
            x: windowStart.x + current.x - dragStart.x,
            y: windowStart.y + current.y - dragStart.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        windowStart = nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            window?.close()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        window?.close()
    }
}
