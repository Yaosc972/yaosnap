import CoreGraphics
import CoreText
import Foundation

/// 文本的 CoreText 度量。渲染与 bounds 都走 multiline，
/// 字号解析和 typographic 高度只在这里算一次。
public enum TextMetrics {
    public struct MultilineLayout {
        public let lines: [(line: CTLine, baseline: CGPoint)]
        /// 画布坐标下的包围盒，覆盖所有行：宽度取最长行，上边界到首行 ascent，下边界到末行 descent。
        public let rect: CGRect
    }

    public static func font(size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    /// 主字体的 ascent/descent。空字符串量不出行高，编辑框定位用这个。
    public static func lineHeight(fontSize: CGFloat) -> (ascent: CGFloat, descent: CGFloat) {
        let f = font(size: fontSize)
        return (CTFontGetAscent(f), CTFontGetDescent(f))
    }

    /// `\n` 硬拆行。第一行基线是 origin，后续行按统一行距下移。行距取所有行里最高的
    /// ascent 与最深的 descent 之和：中文走 fallback 字体，度量与主字体不同，
    /// 按单行高度或主字体度量会让相邻行重叠。
    public static func multiline(
        _ text: String,
        fontSize: CGFloat,
        origin: CGPoint,
        foreground: CGColor? = nil
    ) -> MultilineLayout {
        let rows = text.components(separatedBy: "\n")
        let fallback = lineHeight(fontSize: fontSize)
        let lines = rows.map { makeLine($0, fontSize: fontSize, foreground: foreground) }
        let measured = lines.map { line -> (ascent: CGFloat, descent: CGFloat, width: CGFloat) in
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            // 空行没有字形，typographic bounds 可能全为 0；退回字体度量，否则行距塌成 0。
            guard ascent + descent > 0 else {
                return (fallback.ascent, fallback.descent, width)
            }
            return (ascent, descent, width)
        }
        let step = (measured.map(\.ascent).max() ?? fallback.ascent)
            + (measured.map(\.descent).max() ?? fallback.descent)

        var layoutLines: [(line: CTLine, baseline: CGPoint)] = []
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        var maxWidth: CGFloat = 0
        for (index, line) in lines.enumerated() {
            let row = measured[index]
            let baseline = CGPoint(x: origin.x, y: origin.y - CGFloat(index) * step)
            layoutLines.append((line, baseline))
            minY = min(minY, baseline.y - row.descent)
            maxY = max(maxY, baseline.y + row.ascent)
            maxWidth = max(maxWidth, row.width)
        }
        return MultilineLayout(
            lines: layoutLines,
            rect: CGRect(x: origin.x, y: minY, width: maxWidth, height: maxY - minY)
        )
    }

    public static func boundingRect(
        _ text: String,
        fontSize: CGFloat,
        origin: CGPoint
    ) -> CGRect {
        multiline(text, fontSize: fontSize, origin: origin).rect
    }

    private static func makeLine(
        _ text: String,
        fontSize: CGFloat,
        foreground: CGColor?
    ) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: fontSize),
        ]
        // CTLineDraw 取属性串里的前景色，context 的 fillColor 不参与文字着色。
        if let foreground {
            attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = foreground
        }
        let attributed = NSAttributedString(string: text, attributes: attributes)
        return CTLineCreateWithAttributedString(attributed as CFAttributedString)
    }
}
