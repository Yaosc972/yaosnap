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

    /// Snipaste 的扫码失败行为：清空系统剪贴板，避免旧内容被误当识别结果。
    public static func clear() {
        NSPasteboard.general.clearContents()
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

    /// 把图像写成临时 PNG，剪贴板里放文件 URL。对标 Snipaste 的「复制为文件」。
    /// PNG 按像素落盘，scale 不参与编码。
    @discardableResult
    public static func copyFile(_ image: CGImage, scale: CGFloat) -> Bool {
        guard let url = writeTemporaryPNG(image) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([url as NSURL])
    }

    private static func writeTemporaryPNG(_ image: CGImage) -> URL? {
        guard let data = ImageOutput.pngData(from: image) else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Yaosnap-Copy", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let url = uniqueURL(in: directory, now: Date())
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("[clipboard] error: 写入临时截图失败 \(error.localizedDescription)")
            return nil
        }
    }

    /// 同一秒内连续复制会撞名，退到 `-2`、`-3`。
    private static func uniqueURL(in directory: URL, now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "Yaosnap-\(formatter.string(from: now))"
        var url = directory.appendingPathComponent("\(base).png")
        var sequence = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base)-\(sequence).png")
            sequence += 1
        }
        return url
    }
}
