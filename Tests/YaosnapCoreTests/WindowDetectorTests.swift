import CoreGraphics
import Testing
@testable import YaosnapCore

struct WindowDetectorTests {
    private func cand(
        _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
        layer: Int = 0, owner: String = "App"
    ) -> WindowCandidate {
        WindowCandidate(
            bounds: CGRect(x: x, y: y, width: w, height: h),
            ownerName: owner,
            layer: layer,
            windowID: Int.random(in: 1...99999)
        )
    }

    // 过滤：排除非 0 层（菜单栏/Dock 浮层）与零尺寸窗口
    @Test func snapCandidatesFiltersLayersAndEmpty() {
        let all = [
            cand(0, 0, 100, 100, layer: 0),
            cand(0, 0, 1000, 25, layer: 25, owner: "Window Server"),
            cand(0, 0, 0, 0, layer: 0),
        ]
        let result = WindowDetector.snapCandidates(from: all, ownPID: 1)
        #expect(result.count == 1)
        #expect(result.first?.layer == 0)
    }

    // 命中最顶层窗口（数组顶层在前）
    @Test func windowAtPointReturnsTopmost() {
        let top = cand(0, 0, 500, 500, owner: "Top")
        let bottom = cand(0, 0, 1000, 1000, owner: "Bottom")
        let hit = WindowDetector.window(at: CGPoint(x: 10, y: 10), in: [top, bottom])
        #expect(hit?.ownerName == "Top")
    }

    // 点不在任何窗口内 → nil
    @Test func windowAtPointMiss() {
        let w = cand(0, 0, 100, 100)
        #expect(WindowDetector.window(at: CGPoint(x: 200, y: 200), in: [w]) == nil)
    }
}
