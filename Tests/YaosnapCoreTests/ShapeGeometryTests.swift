import CoreGraphics
import Testing
@testable import YaosnapCore

struct ShapeGeometryTests {
    @Test func boundsOfAllShapes() {
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        #expect(Shape.rect(rect).bounds == rect)
        #expect(Shape.roundedRect(rect, radius: 5).bounds == rect)
        #expect(Shape.ellipse(rect).bounds == rect)
    }

    // 正反向线段包围盒一致，归一化到最小角
    @Test func lineBoundsNormalizesDirection() {
        let forward = Shape.line(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 40, y: 60)).bounds
        let backward = Shape.line(from: CGPoint(x: 40, y: 60), to: CGPoint(x: 10, y: 20)).bounds
        #expect(forward == CGRect(x: 10, y: 20, width: 30, height: 40))
        #expect(backward == forward)
    }

    @Test func arrowBoundsNormalizesDirection() {
        let forward = Shape.arrow(from: CGPoint(x: 5, y: 5), to: CGPoint(x: -5, y: 15)).bounds
        #expect(forward == CGRect(x: -5, y: 5, width: 10, height: 10))
        let backward = Shape.arrow(from: CGPoint(x: -5, y: 15), to: CGPoint(x: 5, y: 5)).bounds
        #expect(backward == forward)
    }

    @Test func pointListBounds() {
        let brush = Shape.brush([
            CGPoint(x: 0, y: 0),
            CGPoint(x: 5, y: 10),
            CGPoint(x: 3, y: 20),
        ]).bounds
        #expect(brush == CGRect(x: 0, y: 0, width: 5, height: 20))

        let marker = Shape.marker([CGPoint(x: 2, y: 2)]).bounds
        #expect(marker == CGRect(x: 2, y: 2, width: 0, height: 0))

        #expect(Shape.mosaic([]).bounds == .zero)
    }

    @Test func textBoundsMatchMeasurement() {
        let origin = CGPoint(x: 12, y: 30)
        let shape = Shape.text("Hello", origin: origin, fontSize: 22)
        let expected = TextMetrics.boundingRect("Hello", fontSize: 22, origin: origin)
        #expect(shape.bounds == expected)
        #expect(shape.bounds.maxY > origin.y)
        #expect(shape.bounds.minY < origin.y)
    }

    @Test func catalogShapeOrderAndFilter() {
        // 数组顺序即未来工具条顺序
        #expect(ShapeCatalog.entries.map(\.kind) == [
            .rect, .roundedRect, .ellipse, .line, .arrow, .brush, .marker, .mosaic, .text,
        ])
        #expect(ShapeCatalog.p2.count == 9)
        #expect(ShapeCatalog.entry(for: .rect)?.symbol == "rectangle")
        #expect(ShapeCatalog.entry(for: .mosaic) != nil)
        #expect(ShapeCatalog.entry(for: .text)?.shortcut == "T")
    }

    // MARK: - 命中测试

    @Test func rectFamilyHitUsesInflatedBounds() {
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        let shapes: [Shape] = [
            .rect(rect),
            .roundedRect(rect, radius: 5),
        ]
        for shape in shapes {
            #expect(shape.contains(CGPoint(x: 25, y: 40), tolerance: 0))
            #expect(shape.contains(CGPoint(x: 5, y: 40), tolerance: 6), "左外侧 5pt 在容差 6 内")
            #expect(!shape.contains(CGPoint(x: 5, y: 40), tolerance: 4), "左外侧 5pt 超出容差 4")
            #expect(shape.contains(CGPoint(x: 43, y: 62), tolerance: 4), "右上角外扩 3pt 应在容差内")
            #expect(!shape.contains(CGPoint(x: 0, y: 0), tolerance: 4))
        }
    }

    @Test func ellipseHitFollowsEllipseEquation() {
        let shape = Shape.ellipse(CGRect(x: 10, y: 20, width: 30, height: 40))
        #expect(shape.contains(CGPoint(x: 25, y: 40), tolerance: 0), "中心命中")
        #expect(shape.contains(CGPoint(x: 42, y: 40), tolerance: 4), "右边缘外扩命中")
        #expect(!shape.contains(CGPoint(x: 43, y: 62), tolerance: 4), "包围盒四角在椭圆外")
        #expect(!shape.contains(CGPoint(x: 0, y: 0), tolerance: 4))
    }

    @Test func textHitUsesInflatedBounds() {
        let origin = CGPoint(x: 20, y: 30)
        let shape = Shape.text("Hello", origin: origin, fontSize: 22)
        let bounds = shape.bounds
        #expect(shape.contains(CGPoint(x: bounds.midX, y: bounds.midY), tolerance: 0))
        #expect(shape.contains(CGPoint(x: bounds.minX - 2, y: bounds.midY), tolerance: 3))
        #expect(!shape.contains(CGPoint(x: bounds.minX - 5, y: bounds.midY), tolerance: 3))
    }

    @Test func lineAndArrowHitUsesPointToSegmentDistance() {
        let shapes: [Shape] = [
            .line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 0)),
            .arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 0)),
        ]
        for shape in shapes {
            #expect(shape.contains(CGPoint(x: 5, y: 2), tolerance: 3))
            #expect(!shape.contains(CGPoint(x: 5, y: 4), tolerance: 3))
            // 投影落在端点外，按端点距离算
            #expect(shape.contains(CGPoint(x: 13, y: 0), tolerance: 3))
            #expect(!shape.contains(CGPoint(x: 14, y: 0), tolerance: 3))
        }
    }

    @Test func pointListHitUsesAnySegment() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)]
        let shapes: [Shape] = [.brush(points), .marker(points), .mosaic(points)]
        for shape in shapes {
            #expect(shape.contains(CGPoint(x: 5, y: 2), tolerance: 3), "第一段附近")
            #expect(shape.contains(CGPoint(x: 12, y: 5), tolerance: 3), "第二段附近")
            #expect(!shape.contains(CGPoint(x: 5, y: 5), tolerance: 3), "折线外侧")
        }
        // 单点笔画退化成点距离
        #expect(Shape.mosaic([CGPoint(x: 5, y: 5)]).contains(CGPoint(x: 6, y: 5), tolerance: 2))
        #expect(!Shape.mosaic([CGPoint(x: 5, y: 5)]).contains(CGPoint(x: 10, y: 5), tolerance: 2))
        #expect(!Shape.brush([]).contains(.zero, tolerance: 10), "空点列不命中任何点")
    }

    // MARK: - 平移

    @Test func translatedMovesBoundsWithoutResizing() {
        let delta = CGPoint(x: 12, y: -7)
        let shapes: [Shape] = [
            .rect(CGRect(x: 10, y: 20, width: 30, height: 40)),
            .roundedRect(CGRect(x: 10, y: 20, width: 30, height: 40), radius: 5),
            .ellipse(CGRect(x: 10, y: 20, width: 30, height: 40)),
            .line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 20)),
            .arrow(from: CGPoint(x: 3, y: 4), to: CGPoint(x: -1, y: 9)),
            .brush([CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5)]),
            .marker([CGPoint(x: 2, y: 2), CGPoint(x: 8, y: 8)]),
            .mosaic([CGPoint(x: 4, y: 4)]),
            .text("Hi", origin: CGPoint(x: 6, y: 8), fontSize: 22),
        ]
        for shape in shapes {
            let moved = shape.translated(by: delta)
            #expect(moved.kind == shape.kind)
            #expect(moved.bounds.size == shape.bounds.size, "\(shape) 尺寸不应变化")
            #expect(moved.bounds.minX == shape.bounds.minX + delta.x)
            #expect(moved.bounds.minY == shape.bounds.minY + delta.y)
        }
    }

    @Test func translatedTextMovesOrigin() {
        let origin = CGPoint(x: 6, y: 8)
        let delta = CGPoint(x: 12, y: 12)
        guard case .text(_, let movedOrigin, let fontSize) =
            Shape.text("Hi", origin: origin, fontSize: 22).translated(by: delta) else {
            Issue.record("平移后应仍是文本")
            return
        }
        #expect(movedOrigin == CGPoint(x: origin.x + delta.x, y: origin.y + delta.y))
        #expect(fontSize == 22)
    }
}
