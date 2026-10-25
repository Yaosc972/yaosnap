import CoreGraphics
import Testing
@testable import YaosnapCore

struct PinBackgroundTests {
    @Test func transparentDrawsNothing() {
        #expect(PinBackground.transparent.fill == nil)
        #expect(PinBackground.transparent.checkerAlternate == nil)
    }

    @Test func pseudoTransparentIsSemiTransparentWhite() {
        guard let fill = PinBackground.pseudoTransparent.fill else {
            Issue.record("伪透明缺少底色")
            return
        }
        #expect(fill.red == 1)
        #expect(fill.green == 1)
        #expect(fill.blue == 1)
        #expect(fill.alpha > 0 && fill.alpha < 1)
        #expect(PinBackground.pseudoTransparent.checkerAlternate == nil)
    }

    @Test func checkerboardsUseTwoOpaqueTones() {
        #expect(PinBackground.checkerCellSize == 8)
        for mode in [PinBackground.darkCheckerboard, PinBackground.lightCheckerboard] {
            guard let fill = mode.fill, let alternate = mode.checkerAlternate else {
                Issue.record("\(mode.rawValue) 缺少棋盘色")
                return
            }
            #expect(fill.alpha == 1)
            #expect(alternate.alpha == 1)
            #expect(fill != alternate)
        }
    }

    @Test func darkAndLightCheckersSitOnOppositeSides() {
        guard let dark = PinBackground.darkCheckerboard.fill,
              let light = PinBackground.lightCheckerboard.fill else {
            Issue.record("棋盘模式缺少底色")
            return
        }
        #expect(dark.red < 0.5)
        #expect(light.red > 0.8)
    }

    @Test func cycleVisitsEveryModeAndWraps() {
        var mode = PinBackground.transparent
        var seen: Set<PinBackground> = []
        for _ in PinBackground.allCases {
            seen.insert(mode)
            mode = mode.next()
        }
        #expect(seen == Set(PinBackground.allCases))
        #expect(mode == .transparent)
    }
}
