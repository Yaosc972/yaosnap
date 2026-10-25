import CoreGraphics
import Testing
@testable import YaosnapCore

struct ShapeResizeTests {
    private let box = CGRect(x: 10, y: 20, width: 100, height: 50)

    /// 拖右上角：左下角固定，宽高由按下点到固定角的距离决定。
    @Test func resizedBoxKeepsOppositeCornerFixed() {
        let resized = ShapeResize.resizedBox(box, corner: .topRight, to: CGPoint(x: 60, y: 40), minimum: 2)
        #expect(resized == CGRect(x: 10, y: 20, width: 50, height: 20))
    }

    /// 两个方向都按最小边长钳制，包围盒朝原方向生长，不会翻到固定角另一侧。
    @Test func resizedBoxClampsToMinimumBothDirections() {
        let shrunken = ShapeResize.resizedBox(
            box, corner: .topRight, to: CGPoint(x: 10.5, y: 20.2), minimum: 2
        )
        #expect(shrunken == CGRect(x: 10, y: 20, width: 2, height: 2))

        let flipped = ShapeResize.resizedBox(
            box, corner: .topRight, to: CGPoint(x: 9.5, y: 19.8), minimum: 2
        )
        #expect(flipped == CGRect(x: 8, y: 18, width: 2, height: 2))
    }

    /// 拖过对角后包围盒翻到固定点另一侧，固定点仍是同一个世界坐标。
    @Test func resizedBoxCrossesOppositeCorner() {
        let resized = ShapeResize.resizedBox(box, corner: .topLeft, to: CGPoint(x: 200, y: 120), minimum: 2)
        #expect(resized == CGRect(x: 110, y: 20, width: 90, height: 100))
    }

    /// 只有面状形状进入缩放分支。线状、笔迹、文字都不显示控制点。
    @Test func onlyFaceShapesSupportResizeHandles() {
        #expect(Shape.rect(.zero).supportsResizeHandles)
        #expect(Shape.roundedRect(.zero, radius: 4).supportsResizeHandles)
        #expect(Shape.ellipse(.zero).supportsResizeHandles)

        let lineLike: [Shape] = [
            .line(from: .zero, to: CGPoint(x: 10, y: 10)),
            .arrow(from: .zero, to: CGPoint(x: 10, y: 10)),
            .polyline([.zero, CGPoint(x: 10, y: 10)]),
            .brush([.zero, CGPoint(x: 10, y: 10)]),
            .marker([.zero, CGPoint(x: 10, y: 10)]),
            .mosaic([.zero, CGPoint(x: 10, y: 10)]),
            .blur([.zero, CGPoint(x: 10, y: 10)]),
            .text("a", origin: .zero, fontSize: 12, rotation: 0),
            .serial(value: 1, center: .zero, radius: 8),
        ]
        for shape in lineLike {
            #expect(!shape.supportsResizeHandles, "\(shape.kind.rawValue) 不应支持包围盒缩放")
            #expect(shape.resized(to: box) == shape, "\(shape.kind.rawValue) 的几何不应被缩放改动")
        }
    }

    /// 圆角矩形缩放时半径保持原值，只在渲染层按新短边钳制。
    @Test func resizedKeepsRoundedRadius() {
        let resized = Shape.roundedRect(box, radius: 12).resized(to: CGRect(x: 0, y: 0, width: 40, height: 30))
        #expect(resized == .roundedRect(CGRect(x: 0, y: 0, width: 40, height: 30), radius: 12))
    }

    /// 线型三档循环，且只对描边类形状有意义。
    @Test func lineStyleCyclesAndAppliesOnlyToStrokeKinds() {
        #expect(LineStyle.solid.next == .dashed)
        #expect(LineStyle.dashed.next == .dotted)
        #expect(LineStyle.dotted.next == .solid)
        #expect(LineStyle.solid.dashPattern(lineWidth: 5) == nil)

        for kind in [ShapeKind.rect, .roundedRect, .ellipse, .line, .arrow, .polyline] {
            #expect(kind.supportsLineStyle, "\(kind.rawValue) 应支持线型")
        }
        for kind in [ShapeKind.brush, .marker, .mosaic, .blur, .text, .serial, .eraser] {
            #expect(!kind.supportsLineStyle, "\(kind.rawValue) 不应支持线型")
        }
    }
}
