import CoreGraphics
import Foundation
import Testing
@testable import YaosnapCore

struct AnnotationSelectionTests {
    private let style = Style(color: RGBAColor(r: 1, g: 0, b: 0), pen: .p3)

    private func annotation(_ rect: CGRect) -> Annotation {
        Annotation(shape: .rect(rect), style: style)
    }

    @Test func marqueeHitsIntersectingShapesAndTouchingEdges() {
        let left = annotation(CGRect(x: 0, y: 0, width: 10, height: 10))
        let right = annotation(CGRect(x: 20, y: 0, width: 10, height: 10))
        let far = annotation(CGRect(x: 50, y: 50, width: 10, height: 10))
        let annotations = [left, right, far]

        let both = AnnotationSelection.ids(
            in: annotations,
            intersecting: CGRect(x: 10, y: 5, width: 10, height: 5)
        )
        #expect(both == [left.id, right.id], "选框左右边分别与两个矩形相切，应同时命中")

        let single = AnnotationSelection.ids(
            in: annotations,
            intersecting: CGRect(x: 9.5, y: 5, width: 0.5, height: 5)
        )
        #expect(single == [left.id], "只与左侧矩形相交")

        let gap = AnnotationSelection.ids(
            in: annotations,
            intersecting: CGRect(x: 11, y: 5, width: 8, height: 5)
        )
        #expect(gap.isEmpty, "两矩形之间的空隙不命中任何标注")

        let dot = AnnotationSelection.ids(
            in: annotations,
            intersecting: CGRect(x: 10, y: 5, width: 0, height: 0)
        )
        #expect(dot == [left.id], "零面积选框仍在边界相切时命中")
    }

    @Test func marqueeUsesBoundsForLineShapes() {
        let horizontal = Annotation(
            shape: .line(from: CGPoint(x: 0, y: 5), to: CGPoint(x: 40, y: 5)),
            style: style
        )
        let vertical = Annotation(
            shape: .line(from: CGPoint(x: 60, y: 0), to: CGPoint(x: 60, y: 40)),
            style: style
        )

        let hits = AnnotationSelection.ids(
            in: [horizontal, vertical],
            intersecting: CGRect(x: -5, y: 0, width: 10, height: 10)
        )
        #expect(hits == [horizontal.id], "水平线落在选框内，垂直线在选框外")

        let crossing = AnnotationSelection.ids(
            in: [horizontal, vertical],
            intersecting: CGRect(x: 59, y: 4, width: 2, height: 2)
        )
        #expect(crossing == [vertical.id], "与垂直线相切")
    }

    @Test func groupTranslationMovesEveryBoundsBySameDelta() {
        let rect = Annotation(shape: .rect(CGRect(x: 10, y: 20, width: 30, height: 40)), style: style)
        let ellipse = Annotation(shape: .ellipse(CGRect(x: 100, y: 50, width: 20, height: 10)), style: style)
        let untouched = Annotation(
            shape: .rect(CGRect(x: 200, y: 200, width: 5, height: 5)),
            style: style
        )
        let delta = CGPoint(x: 12, y: -7)

        let moved = AnnotationSelection.translating(
            [rect, ellipse, untouched],
            ids: [rect.id, ellipse.id],
            by: delta
        )

        #expect(moved.map(\.id) == [rect.id, ellipse.id, untouched.id])
        #expect(moved[0].shape.bounds == rect.shape.bounds.offsetBy(dx: 12, dy: -7))
        #expect(moved[1].shape.bounds == ellipse.shape.bounds.offsetBy(dx: 12, dy: -7))
        #expect(
            moved[0].shape.bounds.origin.x - rect.shape.bounds.origin.x
                == moved[1].shape.bounds.origin.x - ellipse.shape.bounds.origin.x
        )
        #expect(moved[2].shape == untouched.shape, "未选中的标注保持原位")
    }

    @Test func groupRemovalDropsExactlyTheSelectedIDs() {
        let first = annotation(CGRect(x: 0, y: 0, width: 10, height: 10))
        let second = annotation(CGRect(x: 20, y: 0, width: 10, height: 10))
        let third = annotation(CGRect(x: 40, y: 0, width: 10, height: 10))

        let removed = AnnotationSelection.removing(
            [first.id, third.id],
            from: [first, second, third]
        )

        #expect(removed.map(\.id) == [second.id])
    }

    @Test func selectionBoundsUnionSelectedShapes() {
        let first = annotation(CGRect(x: 0, y: 0, width: 10, height: 10))
        let second = annotation(CGRect(x: 50, y: 20, width: 10, height: 10))

        let bounds = AnnotationSelection.bounds(of: [first, second], ids: [first.id, second.id])

        #expect(bounds == CGRect(x: 0, y: 0, width: 60, height: 30))
        #expect(AnnotationSelection.bounds(of: [first], ids: []) == nil)
    }
}
