import CoreGraphics
import Testing
@testable import YaosnapCore

struct PinSelectionTests {
    @Test func toggleAddsThenRemoves() {
        var selection = PinSelection()
        let added = selection.toggle(3)
        #expect(added)
        #expect(selection.count == 1)
        #expect(selection.contains(3))

        let removed = selection.toggle(3)
        #expect(!removed)
        #expect(selection.isEmpty)
    }

    @Test func removeDropsOnlyThatPin() {
        var selection = PinSelection(ids: [1, 2, 3])
        selection.remove(2)
        #expect(selection.ids == [1, 3])
    }

    @Test func selectAllReplacesAndClearEmpties() {
        var selection = PinSelection(ids: [1])
        selection.selectAll([2, 3, 4])
        #expect(selection.ids == [2, 3, 4])

        selection.clear()
        #expect(selection.isEmpty)
        #expect(selection.count == 0)
    }

    @Test func groupMoveAppliesTheSameOffsetToEveryPin() {
        let origins: [Int: CGPoint] = [
            1: CGPoint(x: 10, y: 20),
            2: CGPoint(x: 100, y: 200),
            3: CGPoint(x: -5, y: 0),
        ]
        let delta = CGPoint(x: 7, y: -3)
        let moved = PinSelection.moved(origins: origins, by: delta)

        for (pinID, origin) in origins {
            guard let newOrigin = moved[pinID] else {
                Issue.record("贴图 \(pinID) 没有跟随移动")
                continue
            }
            #expect(newOrigin.x - origin.x == delta.x)
            #expect(newOrigin.y - origin.y == delta.y)
        }
    }
}
