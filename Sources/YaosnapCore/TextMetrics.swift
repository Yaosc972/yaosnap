import CoreGraphics
import CoreText
import Foundation

/// 单行文本的 CoreText 度量。渲染与 bounds 都走 layout，
/// 字号解析和 typographic 高度只在这里算一次。
public enum TextMetrics {
    public struct Layout {
        public let line: CTLine
        /// 画布坐标下的包围盒，origin 为基线起点，向下探 descent、向上到 ascent。
        public let rect: CGRect
    }

    public static func font(size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    /// 单行文字的 ascent/descent。空字符串量不出行高，编辑框定位用这个。
    public static func lineHeight(fontSize: CGFloat) -> (ascent: CGFloat, descent: CGFloat) {
        let f = font(size: fontSize)
        return (CTFontGetAscent(f), CTFontGetDescent(f))
    }

    public static func layout(
        _ text: String,
        fontSize: CGFloat,
        origin: CGPoint,
        foreground: CGColor? = nil
    ) -> Layout {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: fontSize),
        ]
        // CTLineDraw 取属性串里的前景色，context 的 fillColor 不参与文字着色。
        if let foreground {
            attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = foreground
        }
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let rect = CGRect(
            x: origin.x,
            y: origin.y - descent,
            width: width,
            height: ascent + descent
        )
        return Layout(line: line, rect: rect)
    }

    public static func boundingRect(
        _ text: String,
        fontSize: CGFloat,
        origin: CGPoint
    ) -> CGRect {
        layout(text, fontSize: fontSize, origin: origin).rect
    }
}
