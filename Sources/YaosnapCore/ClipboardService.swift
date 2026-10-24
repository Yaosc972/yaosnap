import AppKit

/// 系统粘贴板的图片写入。
public enum ClipboardService {
    /// 像素尺寸按屏幕 scale 折算成点尺寸。直接用像素数当点尺寸会让 Retina 截图在其他 App 里显示成两倍大。
    public static func pointSize(for image: CGImage, scale: CGFloat) -> NSSize {
        let scale = scale > 0 ? scale : 1
        return NSSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
    }

    @discardableResult
    public static func copyString(_ string: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(string, forType: .string)
    }

    @discardableResult
    public static func copyToPasteboard(_ image: CGImage, scale: CGFloat) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let nsImage = NSImage(
            cgImage: image,
            size: pointSize(for: image, scale: scale)
        )
        return pasteboard.writeObjects([nsImage])
    }
}
