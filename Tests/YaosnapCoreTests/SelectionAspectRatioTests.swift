import CoreGraphics
import Testing
@testable import YaosnapCore

struct SelectionAspectRatioTests {
    private let bounds = CGRect(x: 0, y: 0, width: 4000, height: 3000)
    private let sixteenNine = 16.0 / 9.0

    // 横向拖拽位移更大时由宽度定尺寸，高度按比例推出
    @Test func horizontalDragUsesWidthAsDominantAxis() {
        let rect = RectMath.aspectRect(
            from: CGPoint(x: 100, y: 100),
            to: CGPoint(x: 800, y: 500),
            ratio: sixteenNine,
            within: bounds
        )
        #expect(abs(rect.width - 700) < 0.01)
        #expect(abs(rect.height - 700 / sixteenNine) < 0.01)
        #expect(abs(rect.width / rect.height - sixteenNine) < 0.001)
    }

    // 纵向拖拽位移更大时由高度定尺寸，宽度按比例推出
    @Test func verticalDragUsesHeightAsDominantAxis() {
        let rect = RectMath.aspectRect(
            from: CGPoint(x: 100, y: 100),
            to: CGPoint(x: 200, y: 900),
            ratio: sixteenNine,
            within: bounds
        )
        #expect(abs(rect.height - 800) < 0.01)
        #expect(abs(rect.width - 800 * sixteenNine) < 0.01)
        #expect(abs(rect.width / rect.height - sixteenNine) < 0.001)
    }

    // 极短拖拽也要满足最小边长，且比例不被破坏
    @Test func tinyDragKeepsBothSidesAboveMinimum() {
        let rect = RectMath.aspectRect(
            from: CGPoint(x: 500, y: 500),
            to: CGPoint(x: 502, y: 501),
            ratio: sixteenNine,
            within: bounds,
            minimumSide: 10
        )
        #expect(rect.width >= 10)
        #expect(rect.height >= 10)
        #expect(abs(rect.width / rect.height - sixteenNine) < 0.001)
    }
}
