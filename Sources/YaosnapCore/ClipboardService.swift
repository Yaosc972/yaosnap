import AppKit

/// 系统粘贴板的图片写入。
public enum ClipboardService {
    @discardableResult
    public static func copyToPasteboard(_ image: CGImage) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let nsImage = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        return pasteboard.writeObjects([nsImage])
    }
}
