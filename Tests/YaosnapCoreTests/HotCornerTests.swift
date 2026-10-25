import CoreGraphics
import Foundation
import Testing
@testable import YaosnapCore

struct HotCornerTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let bottomLeft = CGPoint(x: 2, y: 2)
    private let middle = CGPoint(x: 700, y: 450)

    private func makeTracker(
        enabled: Bool = true,
        corners: Set<ScreenCorner> = Set(ScreenCorner.allCases),
        dwell: TimeInterval = 0.5
    ) -> HotCornerTracker {
        HotCornerTracker(configuration: .init(
            enabled: enabled,
            corners: corners,
            dwell: dwell,
            zoneSize: 4
        ))
    }

    @Test func firesOnlyAfterDwellElapsesInsideCorner() {
        var tracker = makeTracker()
        #expect(tracker.update(cursor: bottomLeft, screens: [screen], at: 0) == nil)
        #expect(tracker.update(cursor: bottomLeft, screens: [screen], at: 0.49) == nil)
        #expect(tracker.update(cursor: bottomLeft, screens: [screen], at: 0.5) == .bottomLeft)
    }

    @Test func leavingTheCornerRearmsTheSameCorner() {
        var tracker = makeTracker()
        _ = tracker.update(cursor: bottomLeft, screens: [screen], at: 0)
        #expect(tracker.update(cursor: bottomLeft, screens: [screen], at: 1) == .bottomLeft)
        #expect(tracker.update(cursor: bottomLeft, screens: [screen], at: 2) == nil)
        #expect(tracker.update(cursor: middle, screens: [screen], at: 3) == nil)
        #expect(tracker.update(cursor: bottomLeft, screens: [screen], at: 4) == nil)
        #expect(tracker.update(cursor: bottomLeft, screens: [screen], at: 4.5) == .bottomLeft)
    }

    @Test func dwellTimerDoesNotRunOutsideCorners() {
        var tracker = makeTracker()
        _ = tracker.update(cursor: bottomLeft, screens: [screen], at: 0)
        _ = tracker.update(cursor: middle, screens: [screen], at: 0.3)
        #expect(tracker.update(cursor: bottomLeft, screens: [screen], at: 1) == nil)
        #expect(tracker.update(cursor: bottomLeft, screens: [screen], at: 1.5) == .bottomLeft)
    }

    @Test func disabledOrUnselectedCornersNeverFire() {
        var disabled = makeTracker(enabled: false)
        #expect(disabled.update(cursor: bottomLeft, screens: [screen], at: 0) == nil)
        #expect(disabled.update(cursor: bottomLeft, screens: [screen], at: 10) == nil)

        var topRightOnly = makeTracker(corners: [.topRight])
        #expect(topRightOnly.update(cursor: bottomLeft, screens: [screen], at: 0) == nil)
        #expect(topRightOnly.update(cursor: bottomLeft, screens: [screen], at: 10) == nil)
        let topRight = CGPoint(x: 1438, y: 898)
        #expect(topRightOnly.update(cursor: topRight, screens: [screen], at: 11) == nil)
        #expect(topRightOnly.update(cursor: topRight, screens: [screen], at: 11.5) == .topRight)
    }

    @Test func eachScreenContributesItsOwnCorners() {
        var tracker = makeTracker()
        let second = CGRect(x: 1440, y: 0, width: 1280, height: 800)
        let secondTopLeft = CGPoint(x: 1441, y: 798)
        #expect(tracker.update(cursor: secondTopLeft, screens: [screen, second], at: 0) == nil)
        #expect(tracker.update(cursor: secondTopLeft, screens: [screen, second], at: 0.5) == .topLeft)
    }
}
