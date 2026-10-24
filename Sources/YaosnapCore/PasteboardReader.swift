import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// 归一化到 0...1 的 sRGB 颜色。
public struct RGBColor: Equatable {
    public let red: CGFloat
    public let green: CGFloat
    public let blue: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

/// 贴出用的位图与它的点尺寸。位图可能是原始像素尺寸，窗口按点尺寸显示。
public struct PasteImage {
    public let image: CGImage
    public let pointSize: CGSize

    public init(image: CGImage, pointSize: CGSize) {
        self.image = image
        self.pointSize = pointSize
    }
}

public struct PasteboardContent {
    public enum Kind: Equatable {
        case image
        case color
        case text
        case filePath
    }

    public enum Visual {
        case image(PasteImage)
        case color(RGBColor)
        case text(String)
    }

    /// 来源种类仅供日志与测试区分；visual 才是要贴出的内容。
    public let kind: Kind
    public let visual: Visual

    public init(kind: Kind, visual: Visual) {
        self.kind = kind
        self.visual = visual
    }
}

/// 剪贴板内容判定与贴图渲染。判定与解析是纯函数，渲染只依赖 CoreGraphics / CoreText。
public enum PasteboardReader {
    /// 与截图文字标注默认字号一致。
    public static let textFontSize: CGFloat = PenSize.p3.textFontSize
    public static let textPadding: CGFloat = 16
    public static let textMaxWidth: CGFloat = 600
    public static let renderScale: CGFloat = 2
    public static let colorBlockSize = CGSize(width: 160, height: 160)

    private static let backgroundColor = CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    private static let textColor = CGColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1)

    // MARK: - 读取

    /// 优先级：位图、文件、文本、HTML。浏览器同时写图像与 HTML 时贴图像更符合预期。
    public static func read(from pasteboard: NSPasteboard) -> PasteboardContent? {
        if let image = pasteboardImage(pasteboard) {
            return PasteboardContent(kind: .image, visual: .image(image))
        }
        if let url = fileURL(pasteboard) {
            return content(forFile: url)
        }
        if let text = plainText(pasteboard) {
            return resolve(text: text)
        }
        return nil
    }

    /// text 为 nil 时只看 fileURL。文件路径存在且是图片就贴图，否则把路径当文本。
    public static func resolve(text: String?, fileURL: URL? = nil) -> PasteboardContent? {
        if let fileURL {
            guard fileURL.isFileURL else { return nil }
            return content(forFile: fileURL)
        }
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let color = parseColor(trimmed) {
            return PasteboardContent(kind: .color, visual: .color(color))
        }
        let path = (trimmed as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: path) {
            return content(forFile: URL(fileURLWithPath: path))
        }
        return PasteboardContent(kind: .text, visual: .text(text))
    }

    /// 支持 `#RRGGBB` 与 `R, G, B`。三个分量都不超过 1 时按 0...1 解释，否则按 0...255。
    public static func parseColor(_ raw: String) -> RGBColor? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") {
            let hex = text.dropFirst()
            guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
            return RGBColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255
            )
        }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3,
              let red = Double(parts[0]),
              let green = Double(parts[1]),
              let blue = Double(parts[2]) else { return nil }
        let values = [red, green, blue]
        guard values.allSatisfy({ $0 >= 0 }) else { return nil }
        if values.allSatisfy({ $0 <= 1 }) {
            return RGBColor(red: red, green: green, blue: blue)
        }
        guard values.allSatisfy({ $0 <= 255 }) else { return nil }
        return RGBColor(red: red / 255, green: green / 255, blue: blue / 255)
    }

    // MARK: - 渲染

    public static func render(_ content: PasteboardContent) -> PasteImage? {
        switch content.visual {
        case .image(let image):
            return image
        case .color(let color):
            return renderColor(color)
        case .text(let text):
            return renderText(text)
        }
    }

    // MARK: - 剪贴板适配

    private static func pasteboardImage(_ pasteboard: NSPasteboard) -> PasteImage? {
        guard let nsImage = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?
            .first as? NSImage else { return nil }
        var proposed = CGRect(origin: .zero, size: nsImage.size)
        guard let image = nsImage.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            return nil
        }
        // 没有点尺寸的 NSImage 按 2x 位图折算，避免贴出两倍大。
        let pointSize = nsImage.size.width > 0 && nsImage.size.height > 0
            ? nsImage.size
            : CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
        return PasteImage(image: image, pointSize: pointSize)
    }

    private static func fileURL(_ pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let items = pasteboard.readObjects(forClasses: [NSURL.self], options: options),
              let url = items.first as? NSURL else { return nil }
        return url as URL
    }

    private static func plainText(_ pasteboard: NSPasteboard) -> String? {
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return string
        }
        guard let data = pasteboard.data(forType: .html),
              let attributed = try? NSAttributedString(
                  data: data,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue,
                  ],
                  documentAttributes: nil),
              !attributed.string.isEmpty else { return nil }
        return attributed.string
    }

    private static func content(forFile url: URL) -> PasteboardContent {
        if let image = loadImage(at: url) {
            return PasteboardContent(kind: .filePath, visual: .image(image))
        }
        return PasteboardContent(kind: .filePath, visual: .text(url.path))
    }

    private static func loadImage(at url: URL) -> PasteImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var scale: CGFloat = 1
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let dpi = properties[kCGImagePropertyDPIWidth] as? Double, dpi > 0 {
            scale = CGFloat(dpi / 72)
        }
        return PasteImage(
            image: image,
            pointSize: CGSize(
                width: CGFloat(image.width) / scale,
                height: CGFloat(image.height) / scale
            )
        )
    }

    // MARK: - 位图输出

    private static func makeContext(pixelWidth: Int, pixelHeight: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: max(1, pixelWidth),
            height: max(1, pixelHeight),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func renderColor(_ color: RGBColor) -> PasteImage? {
        let width = Int(colorBlockSize.width * renderScale)
        let height = Int(colorBlockSize.height * renderScale)
        guard let context = makeContext(pixelWidth: width, pixelHeight: height) else { return nil }
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        return PasteImage(image: image, pointSize: colorBlockSize)
    }

    private static func renderText(_ text: String) -> PasteImage? {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return nil }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): TextMetrics.font(size: textFontSize),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor,
        ]
        let attributed = NSAttributedString(string: trimmed, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var fitRange = CFRange(location: 0, length: 0)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: textMaxWidth, height: .greatestFiniteMagnitude),
            &fitRange
        )
        let contentSize = CGSize(
            width: max(1, ceil(min(suggested.width, textMaxWidth))),
            height: max(1, ceil(suggested.height))
        )
        let pointSize = CGSize(
            width: contentSize.width + textPadding * 2,
            height: contentSize.height + textPadding * 2
        )
        guard let context = makeContext(
            pixelWidth: Int((pointSize.width * renderScale).rounded(.up)),
            pixelHeight: Int((pointSize.height * renderScale).rounded(.up))
        ) else { return nil }

        context.scaleBy(x: renderScale, y: renderScale)
        context.setFillColor(backgroundColor)
        context.fill(CGRect(origin: .zero, size: pointSize))
        context.textMatrix = .identity
        let path = CGPath(
            rect: CGRect(
                x: textPadding,
                y: textPadding,
                width: contentSize.width,
                height: contentSize.height
            ),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )
        CTFrameDraw(frame, context)
        guard let image = context.makeImage() else { return nil }
        return PasteImage(image: image, pointSize: pointSize)
    }
}
