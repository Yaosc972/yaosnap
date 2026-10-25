import CoreGraphics
import Testing

@testable import YaosnapCore

struct SelectionResizeTests {
    private let box = CGRect(x: 10, y: 20, width: 100, height: 50)
    private let tolerance: CGFloat = 4

    private func hit(_ x: CGFloat, _ y: CGFloat) -> SelectionEdge? {
        SelectionEdge.hit(point: CGPoint(x: x, y: y), in: box, tolerance: tolerance)
    }

    // MARK: - 命中检测

    /// 四条边各取中点，命中对应方向。
    @Test func hitsAllFourEdges() {
        #expect(hit(60, 70) == .top)
        #expect(hit(60, 20) == .bottom)
        #expect(hit(10, 45) == .left)
        #expect(hit(110, 45) == .right)
    }

    /// 角点同时落在两条边的命中带上，必须返回角而不是边。
    @Test func cornersWinOverEdges() {
        #expect(hit(10, 70) == .topLeft)
        #expect(hit(110, 70) == .topRight)
        #expect(hit(10, 20) == .bottomLeft)
        #expect(hit(110, 20) == .bottomRight)
    }

    /// 边的角区是方形热区：靠近角点的仍归角；超出端点容差才不命中。
    @Test func edgeProjectsOnlyBetweenEndpoints() {
        #expect(hit(107, 70) == .topRight)
        #expect(hit(112, 70) == .topRight)
        #expect(hit(115, 70) == nil)
        #expect(hit(60, 73.5) == .top)
        #expect(hit(60, 75) == nil)
    }

    /// 容差外与选区外远处都不命中；内部深处也不命中。
    @Test func missesOutsideTolerance() {
        #expect(hit(60, 75) == nil)
        #expect(hit(60, 15) == nil)
        #expect(hit(5, 45) == nil)
        #expect(hit(115, 45) == nil)
        #expect(hit(60, 45) == nil)
        #expect(hit(500, 500) == nil)
    }

    /// 空选区没有可拖的边缘。
    @Test func emptyRectNeverHits() {
        #expect(SelectionEdge.hit(point: .zero, in: .zero, tolerance: tolerance) == nil)
    }

    // MARK: - 单边调整

    /// 拖右边只改 maxX，对边与纵向不变。
    @Test func draggingRightOnlyMovesMaxX() {
        let resized = SelectionEdge.resized(box, edge: .right, to: CGPoint(x: 160, y: 200), minimum: 1, within: box.insetBy(dx: -1000, dy: -1000))
        #expect(resized == CGRect(x: 10, y: 20, width: 150, height: 50))
    }

    /// 拖左边只改 minX。
    @Test func draggingLeftOnlyMovesMinX() {
        let resized = SelectionEdge.resized(box, edge: .left, to: CGPoint(x: 0, y: 200), minimum: 1, within: box.insetBy(dx: -1000, dy: -1000))
        #expect(resized == CGRect(x: 0, y: 20, width: 110, height: 50))
    }

    /// 拖上边（maxY）只改高度，下边不动。
    @Test func draggingTopOnlyMovesMaxY() {
        let resized = SelectionEdge.resized(box, edge: .top, to: CGPoint(x: 500, y: 100), minimum: 1, within: box.insetBy(dx: -1000, dy: -1000))
        #expect(resized == CGRect(x: 10, y: 20, width: 100, height: 80))
    }

    /// 拖下边（minY）只改原点与高度。
    @Test func draggingBottomOnlyMovesMinY() {
        let resized = SelectionEdge.resized(box, edge: .bottom, to: CGPoint(x: 500, y: 0), minimum: 1, within: box.insetBy(dx: -1000, dy: -1000))
        #expect(resized == CGRect(x: 10, y: 0, width: 100, height: 70))
    }

    /// 拖角同时改两个方向：右上角改 maxX 与 maxY。
    @Test func draggingCornerMovesBothAxes() {
        let resized = SelectionEdge.resized(box, edge: .topRight, to: CGPoint(x: 150, y: 90), minimum: 1, within: box.insetBy(dx: -1000, dy: -1000))
        #expect(resized == CGRect(x: 10, y: 20, width: 140, height: 70))
    }

    // MARK: - 最小尺寸

    /// 拖过对边时钳在 minimum，不翻转，宽高都不小于 1。
    @Test func clampsToMinimumWhenDraggedPastOppositeEdge() {
        let wide = box.insetBy(dx: -1000, dy: -1000)
        let left = SelectionEdge.resized(box, edge: .left, to: CGPoint(x: 500, y: 45), minimum: 1, within: wide)
        #expect(left.width == 1)
        #expect(left.maxX == box.maxX)

        let right = SelectionEdge.resized(box, edge: .right, to: CGPoint(x: 0, y: 45), minimum: 1, within: wide)
        #expect(right.width == 1)
        #expect(right.minX == box.minX)

        let top = SelectionEdge.resized(box, edge: .top, to: CGPoint(x: 60, y: 0), minimum: 1, within: wide)
        #expect(top.height == 1)
        #expect(top.minY == box.minY)

        let bottom = SelectionEdge.resized(box, edge: .bottom, to: CGPoint(x: 60, y: 500), minimum: 1, within: wide)
        #expect(bottom.height == 1)
        #expect(bottom.maxY == box.maxY)

        let corner = SelectionEdge.resized(box, edge: .topLeft, to: CGPoint(x: 500, y: 500), minimum: 1, within: wide)
        #expect(corner.width >= 1)
        #expect(corner.height >= 1)
        #expect(corner.maxX == box.maxX)
        #expect(corner.minY == box.minY)
    }

    // MARK: - 边界夹取

    /// 拖出屏幕的结果被 bounds 裁回，只裁拖动侧，对边仍不动。
    @Test func resultIsClampedToBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 120, height: 80)
        let right = SelectionEdge.resized(box, edge: .right, to: CGPoint(x: 300, y: 45), minimum: 1, within: bounds)
        #expect(right == CGRect(x: 10, y: 20, width: 110, height: 50))

        let left = SelectionEdge.resized(box, edge: .left, to: CGPoint(x: -50, y: 45), minimum: 1, within: bounds)
        #expect(left == CGRect(x: 0, y: 20, width: 110, height: 50))

        let top = SelectionEdge.resized(box, edge: .top, to: CGPoint(x: 60, y: 200), minimum: 1, within: bounds)
        #expect(top == CGRect(x: 10, y: 20, width: 100, height: 60))

        let bottom = SelectionEdge.resized(box, edge: .bottom, to: CGPoint(x: 60, y: -20), minimum: 1, within: bounds)
        #expect(bottom == CGRect(x: 10, y: 0, width: 100, height: 70))
    }

    // MARK: - 空选区

    /// 空 rect 原样返回，不产生零点矩形。
    @Test func emptyRectIsReturnedUnchanged() {
        let result = SelectionEdge.resized(
            .zero,
            edge: .topLeft,
            to: CGPoint(x: 100, y: 100),
            minimum: 1,
            within: CGRect(x: 0, y: 0, width: 200, height: 200)
        )
        #expect(result == .zero)
    }
}
