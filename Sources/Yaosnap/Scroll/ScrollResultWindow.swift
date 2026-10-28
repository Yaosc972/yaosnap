import AppKit
import YaosnapCore

/// 长图查看窗口：上下滚动查看，复制、保存、贴到屏幕（标注交给贴图窗口）。
@MainActor
final class ScrollResultWindow: NSWindow {
    var onPin: ((CGImage, CGFloat) -> Void)?

    private let image: CGImage
    private let scale: CGFloat

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale

        let pointSize = NSSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 900, height: 700)
        let contentSize = NSSize(
            width: min(pointSize.width, visible.width * 0.7),
            height: min(pointSize.height, visible.height * 0.8)
        )
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "滚动截图"
        isReleasedWhenClosed = false
        center()

        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        container.autoresizingMask = [.width, .height]

        let toolbar = makeToolbar()
        toolbar.frame = NSRect(x: 0, y: contentSize.height - 36, width: contentSize.width, height: 36)
        toolbar.autoresizingMask = [.width, .minYMargin]
        container.addSubview(toolbar)

        let scrollView = NSScrollView(frame: NSRect(
            x: 0, y: 0, width: contentSize.width, height: contentSize.height - 36
        ))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true

        let documentContainer = FlippedView(frame: NSRect(origin: .zero, size: pointSize))
        let imageView = NSImageView(frame: documentContainer.bounds)
        imageView.image = NSImage(cgImage: image, size: pointSize)
        imageView.imageScaling = .scaleNone
        documentContainer.addSubview(imageView)
        scrollView.documentView = documentContainer
        container.addSubview(scrollView)

        contentView = container
    }

    private func makeToolbar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let buttons: [(String, Selector)] = [
            ("复制", #selector(copyTapped)),
            ("保存", #selector(saveTapped)),
            ("贴到屏幕", #selector(pinTapped)),
            ("关闭", #selector(closeTapped))
        ]
        var x: CGFloat = 8
        for (title, action) in buttons {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.sizeToFit()
            button.frame.origin = NSPoint(x: x, y: 5)
            bar.addSubview(button)
            x += button.frame.width + 8
        }
        return bar
    }

    @objc private func copyTapped() {
        _ = ClipboardService.copyToPasteboard(image, scale: scale)
    }

    @objc private func saveTapped() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "滚动截图.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = ImageOutput.pngData(from: image) else { return }
        try? data.write(to: url)
    }

    @objc private func pinTapped() {
        onPin?(image, scale)
    }

    @objc private func closeTapped() {
        close()
    }
}

/// 翻转坐标的文档容器：NSScrollView 的初始滚动位置落在左上，长图从顶部开始看。
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
