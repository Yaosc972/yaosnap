import AppKit
import YaosnapCore

/// 翻译结果浮窗。非模态，原文与译文并排可选中复制，初始高度随文字行数自适应。
@MainActor
final class TranslationResultWindow: NSWindowController {
    /// 持有当前窗口，关闭即释放；再次翻译时替换。
    private static var current: TranslationResultWindow?

    private let translatedText: String
    private let copyButton: NSButton

    static func show(source: String, translated: String) {
        let controller = TranslationResultWindow(source: source, translated: translated)
        current = controller
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(source: String, translated: String) {
        translatedText = translated
        let longest = max(source, translated)
        let lineCount = longest.components(separatedBy: .newlines).count
        // 每行约 19pt 加面板与按钮的固定开销，短文本不撑高、长文本钳到 600。
        let height = min(max(CGFloat(lineCount) * 19 + 150, 320), 600)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "翻译结果"
        window.minSize = NSSize(width: 560, height: 320)
        // 程序创建的窗口默认关闭即释放，实例由 current 持有到下一次翻译。
        window.isReleasedWhenClosed = false
        copyButton = NSButton(title: "复制译文", target: nil, action: nil)
        super.init(window: window)

        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyTranslated)

        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded

        let panes = NSStackView(views: [
            Self.makePane(title: "原文", text: source),
            Self.makePane(title: "译文", text: translated),
        ])
        panes.orientation = .horizontal
        panes.distribution = .fillEqually
        panes.alignment = .top
        panes.spacing = 16

        let buttonRow = NSStackView(views: [NSView(), copyButton, closeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let content = NSStackView(views: [panes, buttonRow])
        content.orientation = .vertical
        // 竖排用 .width 让双栏与按钮行都撑满窗宽，空白 view 才能把按钮推到右侧。
        content.alignment = .width
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        // 按钮行按固有高度贴底，剩余高度全部给双栏文本。
        panes.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = content
        pin(content, to: window.contentView!)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未使用")
    }

    private func pin(_ view: NSView, to container: NSView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private static func makePane(title: String, text: String) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor

        let textView = NSTextView()
        textView.string = text
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        let pane = NSStackView(views: [label, scroll])
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = 4
        scroll.widthAnchor.constraint(equalTo: pane.widthAnchor).isActive = true
        return pane
    }

    @objc private func copyTranslated() {
        guard ClipboardService.copyString(translatedText) else {
            print("[translate] error: 译文写入剪贴板失败")
            NSSound.beep()
            return
        }
        let original = "复制译文"
        copyButton.title = "已复制"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.title = original
        }
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }
}
