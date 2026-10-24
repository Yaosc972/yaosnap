import CoreGraphics
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
}
