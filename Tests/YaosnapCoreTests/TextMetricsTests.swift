import CoreGraphics
import CoreText
import Testing
@testable import YaosnapCore

struct TextMetricsTests {
    @Test func widthGrowsWithTextLength() {
        let origin = CGPoint(x: 10, y: 20)
        let short = TextMetrics.boundingRect("A", fontSize: 22, origin: origin)
        let long = TextMetrics.boundingRect("AAAAAAAAAA", fontSize: 22, origin: origin)
        #expect(long.width > short.width)
    }

    @Test func boundsAnchorAtBaselineOrigin() {
        let origin = CGPoint(x: 5, y: 40)
        let rect = TextMetrics.boundingRect("Hello", fontSize: 18, origin: origin)
        #expect(rect.minX == origin.x)
        #expect(rect.minY < origin.y)
        #expect(rect.maxY > origin.y)
        #expect(rect.width > 0)
    }

    @Test func multilineHeightDoublesForTwoLines() {
        let origin = CGPoint(x: 10, y: 80)
        let single = TextMetrics.boundingRect("Hello", fontSize: 22, origin: origin)
        let double = TextMetrics.boundingRect("Hello\nHello", fontSize: 22, origin: origin)
        #expect(abs(double.height - single.height * 2) < 0.5)
        #expect(abs(double.width - single.width) < 0.01)

        let layout = TextMetrics.multiline("Hello\nHello", fontSize: 22, origin: origin)
        #expect(layout.lines.count == 2)
        #expect(layout.lines[0].baseline == origin)
        #expect(layout.lines[1].baseline.x == origin.x)
        #expect(layout.lines[1].baseline.y < origin.y)
    }

    @Test func emptyLineStillOccupiesRowHeight() {
        let origin = CGPoint(x: 0, y: 60)
        let single = TextMetrics.boundingRect("A", fontSize: 22, origin: origin)
        let layout = TextMetrics.multiline("A\n\nA", fontSize: 22, origin: origin)
        #expect(layout.lines.count == 3)
        #expect(abs(layout.rect.height - single.height * 3) < 0.5)
    }

    /// 中文走 fallback 字体，字面高度高于主字体；行距取实测行高才不重叠。
    @Test func chineseLinesDoNotOverlap() {
        let origin = CGPoint(x: 0, y: 100)
        let layout = TextMetrics.multiline("测试文字\n测试文字", fontSize: 22, origin: origin)
        #expect(layout.lines.count == 2)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(layout.lines[0].line, &ascent, &descent, nil)
        let step = layout.lines[0].baseline.y - layout.lines[1].baseline.y
        #expect(step >= ascent + descent - 0.01)
        #expect(layout.rect.minY <= layout.lines[1].baseline.y - descent + 0.01)
        #expect(layout.rect.maxY >= origin.y + ascent - 0.01)
    }
}
