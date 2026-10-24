import CoreGraphics
import Testing
@testable import YaosnapCore

struct TextTransformTests {
    @Test func rotatedBoundsCoverRotatedCorners() {
        let origin = CGPoint(x: 20, y: 40)
        let horizontal = Shape.text("Wide text", origin: origin, fontSize: 24, rotation: 0)
        let rotated = Shape.text("Wide text", origin: origin, fontSize: 24, rotation: .pi / 2)
        let geometry = TextGeometry(rect: horizontal.bounds, rotation: .pi / 2)

        #expect(rotated.bounds != horizontal.bounds)
        #expect(abs(rotated.bounds.width - horizontal.bounds.height) < 0.001)
        #expect(abs(rotated.bounds.height - horizontal.bounds.width) < 0.001)
        #expect(abs(rotated.bounds.midX - horizontal.bounds.midX) < 0.001)
        #expect(abs(rotated.bounds.midY - horizontal.bounds.midY) < 0.001)
        for corner in geometry.corners {
            #expect(rotated.bounds.insetBy(dx: -0.001, dy: -0.001).contains(corner))
        }
    }

    @Test func rotatedHitMovesWithTheText() {
        let origin = CGPoint(x: 20, y: 40)
        let horizontal = Shape.text("Wide text", origin: origin, fontSize: 24, rotation: 0)
        let rotated = Shape.text("Wide text", origin: origin, fontSize: 24, rotation: .pi / 2)
        let rect = horizontal.bounds
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // 长轴右端：水平时命中，转 90° 后文字移走，该点落空。
        let alongLongAxis = CGPoint(x: center.x + rect.width * 0.45, y: center.y)
        #expect(horizontal.contains(alongLongAxis, tolerance: 0))
        #expect(!rotated.contains(alongLongAxis, tolerance: 0))
        // 长轴转到竖直方向后，中心正上方才是新的文字内部。
        let aboveCenter = CGPoint(x: center.x, y: center.y + rect.width * 0.45)
        #expect(!horizontal.contains(aboveCenter, tolerance: 0))
        #expect(rotated.contains(aboveCenter, tolerance: 0))
    }

    @Test func rotationHandleSitsAboveBoxAndTurnsWithIt() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 40)
        let horizontal = TextGeometry(rect: rect, rotation: 0)
        let top = horizontal.point(for: .rotate)
        #expect(abs(top.x - rect.midX) < 0.001)
        #expect(abs(top.y - (rect.maxY + TextGeometry.rotationHandleOffset)) < 0.001)

        let quarterTurn = TextGeometry(rect: rect, rotation: .pi / 2)
        let side = quarterTurn.point(for: .rotate)
        #expect(side.x < rect.midX)
        #expect(abs(side.y - rect.midY) < 0.001)
        #expect(abs(side.x - (rect.midX - rect.height / 2 - TextGeometry.rotationHandleOffset)) < 0.001)
    }

    @Test func resizeScalesFontByDistanceRatio() {
        #expect(abs(TextGeometry.scaledFontSize(22, from: 100, to: 200) - 44) < 0.001)
        #expect(abs(TextGeometry.scaledFontSize(22, from: 100, to: 50) - 11) < 0.001)
        #expect(TextGeometry.scaledFontSize(22, from: 0, to: 200) == 22)
        #expect(TextGeometry.scaledFontSize(22, from: 100, to: 0) == TextGeometry.minimumFontSize)
    }

    @Test func originCentersTextBox() {
        let center = CGPoint(x: 123, y: 77)
        let text = "测试\nTwo"
        let origin = TextMetrics.origin(text: text, fontSize: 24, centeredAt: center)
        let rect = TextMetrics.boundingRect(text, fontSize: 24, origin: origin)
        #expect(abs(rect.midX - center.x) < 0.001)
        #expect(abs(rect.midY - center.y) < 0.001)
    }
}
