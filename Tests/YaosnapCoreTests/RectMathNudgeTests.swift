import CoreGraphics
import Testing
@testable import YaosnapCore

struct RectMathNudgeTests {
    private let bounds = CGRect(x: 0, y: 0, width: 500, height: 400)
    private let base = CGRect(x: 100, y: 100, width: 200, height: 100)

    // 方向键整体平移 1pt，尺寸不变
    @Test func moveShiftsWholeRect() {
        #expect(RectMath.nudge(base, direction: .up, mode: .move, within: bounds)
            == CGRect(x: 100, y: 101, width: 200, height: 100))
        #expect(RectMath.nudge(base, direction: .down, mode: .move, within: bounds)
            == CGRect(x: 100, y: 99, width: 200, height: 100))
        #expect(RectMath.nudge(base, direction: .left, mode: .move, within: bounds)
            == CGRect(x: 99, y: 100, width: 200, height: 100))
        #expect(RectMath.nudge(base, direction: .right, mode: .move, within: bounds)
            == CGRect(x: 101, y: 100, width: 200, height: 100))
    }

    // Control 加方向键：向该方向扩 1pt
    @Test func expandGrowsTowardDirection() {
        #expect(RectMath.nudge(base, direction: .up, mode: .expand, within: bounds)
            == CGRect(x: 100, y: 100, width: 200, height: 101))
        #expect(RectMath.nudge(base, direction: .down, mode: .expand, within: bounds)
            == CGRect(x: 100, y: 99, width: 200, height: 101))
        #expect(RectMath.nudge(base, direction: .left, mode: .expand, within: bounds)
            == CGRect(x: 99, y: 100, width: 201, height: 100))
        #expect(RectMath.nudge(base, direction: .right, mode: .expand, within: bounds)
            == CGRect(x: 100, y: 100, width: 201, height: 100))
    }

    // Shift 加方向键：从该方向缩 1pt
    @Test func shrinkTrimsTowardDirection() {
        #expect(RectMath.nudge(base, direction: .up, mode: .shrink, within: bounds)
            == CGRect(x: 100, y: 100, width: 200, height: 99))
        #expect(RectMath.nudge(base, direction: .down, mode: .shrink, within: bounds)
            == CGRect(x: 100, y: 101, width: 200, height: 99))
        #expect(RectMath.nudge(base, direction: .left, mode: .shrink, within: bounds)
            == CGRect(x: 101, y: 100, width: 199, height: 100))
        #expect(RectMath.nudge(base, direction: .right, mode: .shrink, within: bounds)
            == CGRect(x: 100, y: 100, width: 199, height: 100))
    }

    // 贴边后继续平移不再越界
    @Test func moveStopsAtBounds() {
        let rightEdge = CGRect(x: 400, y: 0, width: 100, height: 100)
        #expect(RectMath.nudge(rightEdge, direction: .right, mode: .move, within: bounds) == rightEdge)
        let topEdge = CGRect(x: 0, y: 350, width: 100, height: 50)
        #expect(RectMath.nudge(topEdge, direction: .up, mode: .move, within: bounds) == topEdge)
        let bottomLeft = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(RectMath.nudge(bottomLeft, direction: .left, mode: .move, within: bounds) == bottomLeft)
        #expect(RectMath.nudge(bottomLeft, direction: .down, mode: .move, within: bounds) == bottomLeft)
    }

    // 贴边扩大不越过屏幕
    @Test func expandStopsAtBounds() {
        let leftEdge = CGRect(x: 0, y: 100, width: 100, height: 100)
        #expect(RectMath.nudge(leftEdge, direction: .left, mode: .expand, within: bounds) == leftEdge)
        let topEdge = CGRect(x: 100, y: 300, width: 100, height: 100)
        #expect(RectMath.nudge(topEdge, direction: .up, mode: .expand, within: bounds) == topEdge)
    }

    // 缩到最小边长后不再缩破
    @Test func shrinkRespectsMinimumSide() {
        let tiny = CGRect(x: 100, y: 100, width: 1, height: 1)
        #expect(RectMath.nudge(tiny, direction: .left, mode: .shrink, within: bounds) == tiny)
        #expect(RectMath.nudge(tiny, direction: .down, mode: .shrink, within: bounds) == tiny)
        #expect(RectMath.nudge(tiny, direction: .up, mode: .shrink, within: bounds) == tiny)
        #expect(RectMath.nudge(tiny, direction: .right, mode: .shrink, within: bounds) == tiny)
    }

    // 空选区不参与调整
    @Test func emptyRectUnchanged() {
        #expect(RectMath.nudge(.zero, direction: .up, mode: .move, within: bounds) == .zero)
    }
}
