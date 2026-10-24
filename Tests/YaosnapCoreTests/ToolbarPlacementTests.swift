import CoreGraphics
import Testing
@testable import YaosnapCore

struct ToolbarPlacementTests {
    private let toolbarSize = CGSize(width: 100, height: 44)
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test func belowSelectionWhenSpaceAllows() {
        let selection = CGRect(x: 50, y: 100, width: 300, height: 200)
        let origin = ToolbarPlacement.origin(
            toolbarSize: toolbarSize, selection: selection, within: screen
        )
        #expect(origin == CGPoint(x: 250, y: 50))
    }

    @Test func fallsBackAboveWhenBelowClipped() {
        // 选区贴近屏幕底：下方放不下，翻到上方外侧
        let selection = CGRect(x: 50, y: 20, width: 300, height: 20)
        let origin = ToolbarPlacement.origin(
            toolbarSize: toolbarSize, selection: selection, within: screen
        )
        #expect(origin == CGPoint(x: 250, y: 46))
    }

    @Test func fallsBackInsideWhenBothClipped() {
        // 选区几乎占满屏幕：上下外侧都放不下，退回选区内右下
        let selection = CGRect(x: 50, y: 10, width: 300, height: 770)
        let origin = ToolbarPlacement.origin(
            toolbarSize: toolbarSize, selection: selection, within: screen
        )
        #expect(origin.y == 16)
        #expect(origin.x == 250)
    }

    @Test func clampsXToScreenEdges() {
        // 选区右缘贴到屏幕边：钳到右缘内 4pt
        let overRight = ToolbarPlacement.origin(
            toolbarSize: toolbarSize,
            selection: CGRect(x: 500, y: 100, width: 500, height: 200),
            within: screen
        )
        #expect(overRight.x == 896)

        // 选区太靠左：钳到左缘 4pt
        let overLeft = ToolbarPlacement.origin(
            toolbarSize: toolbarSize,
            selection: CGRect(x: 10, y: 100, width: 40, height: 200),
            within: screen
        )
        #expect(overLeft.x == 4)
    }
}
