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
}
