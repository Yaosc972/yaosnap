import CoreGraphics
import Testing
@testable import YaosnapCore

struct UIElementDetectorTests {
    // AX 屏幕矩形（左上原点）→ 视图矩形（左下原点）
    @Test func axRectFlipsToViewCoordinates() {
        let rect = UIElementDetector.viewRect(
            fromAXRect: CGRect(x: 100, y: 50, width: 200, height: 80),
            displayBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            viewHeight: 900
        )
        #expect(rect == CGRect(x: 100, y: 770, width: 200, height: 80))
    }

    // 副屏 origin 非零：屏幕坐标先减去屏幕原点，再按该屏高度翻转
    @Test func axRectOnSecondaryDisplayKeepsLocalOrigin() {
        let rect = UIElementDetector.viewRect(
            fromAXRect: CGRect(x: 2020, y: 50, width: 200, height: 80),
            displayBounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            viewHeight: 1080
        )
        #expect(rect == CGRect(x: 100, y: 950, width: 200, height: 80))
    }

    // 主屏上方的副屏坐标是负数，仍要落到本屏内的正坐标
    @Test func axRectOnDisplayAboveMain() {
        let rect = UIElementDetector.viewRect(
            fromAXRect: CGRect(x: 100, y: -1030, width: 200, height: 80),
            displayBounds: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
            viewHeight: 1080
        )
        #expect(rect == CGRect(x: 100, y: 950, width: 200, height: 80))
    }

    @Test func usableRectPasses() {
        let display = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let rect = CGRect(x: 2000, y: 100, width: 120, height: 40)
        #expect(UIElementDetector.isUsable(rect, minimumSide: 4, within: display))
    }

    @Test func tooSmallRectFallsBack() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(!UIElementDetector.isUsable(
            CGRect(x: 10, y: 10, width: 3, height: 40),
            minimumSide: 4,
            within: display
        ))
        #expect(!UIElementDetector.isUsable(
            CGRect(x: 10, y: 10, width: 40, height: 3),
            minimumSide: 4,
            within: display
        ))
    }

    @Test func minimumSideBoundaryIsUsable() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(UIElementDetector.isUsable(
            CGRect(x: 10, y: 10, width: 4, height: 4),
            minimumSide: 4,
            within: display
        ))
    }

    @Test func rectOutsideDisplayFallsBack() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(!UIElementDetector.isUsable(
            CGRect(x: 1400, y: 10, width: 100, height: 40),
            minimumSide: 4,
            within: display
        ))
        #expect(!UIElementDetector.isUsable(
            CGRect(x: -20, y: 10, width: 100, height: 40),
            minimumSide: 4,
            within: display
        ))
    }

    @Test func levelClampRange() {
        #expect(UIElementDetector.clampLevel(-3) == 0)
        #expect(UIElementDetector.clampLevel(0) == 0)
        #expect(UIElementDetector.clampLevel(3) == 3)
        #expect(UIElementDetector.clampLevel(5) == 5)
        #expect(UIElementDetector.clampLevel(9) == 5)
        #expect(UIElementDetector.maximumLevel == 5)
    }
}
