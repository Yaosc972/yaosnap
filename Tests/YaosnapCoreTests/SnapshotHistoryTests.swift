import Testing
@testable import YaosnapCore

struct SnapshotHistoryTests {
    @Test func undoRedoRoundTrip() {
        var history = SnapshotHistory<[Int]>()
        history.record([1])
        history.record([1, 2])
        #expect(history.undo(current: [1, 2, 3]) == [1, 2])
        #expect(history.undo(current: [1, 2]) == [1])
        #expect(history.undo(current: [1]) == nil)
        #expect(history.redo(current: [1]) == [1, 2])
        #expect(history.redo(current: [1, 2]) == [1, 2, 3])
        #expect(history.redo(current: [1, 2, 3]) == nil)
    }

    @Test func newRecordClearsRedoBranch() {
        var history = SnapshotHistory<[String]>()
        history.record(["a"])
        #expect(history.undo(current: ["a", "b"]) == ["a"])
        #expect(history.canRedo)

        history.record(["a", "c"])
        #expect(!history.canRedo)
        #expect(history.redo(current: ["a", "c", "d"]) == nil)
    }

    @Test func discardRedoKeepsUndoAvailable() {
        var history = SnapshotHistory<Int>()
        history.record(1)
        history.record(2)
        #expect(history.undo(current: 3) == 2)
        history.discardRedo()
        #expect(!history.canRedo)
        #expect(history.undo(current: 2) == 1)
    }

    @Test func removeAllClearsBothDirections() {
        var history = SnapshotHistory<Int>()
        history.record(1)
        _ = history.undo(current: 2)
        history.removeAll()
        #expect(!history.canUndo)
        #expect(!history.canRedo)
    }

    @Test func emptyUndoDoesNotRecordRedo() {
        var history = SnapshotHistory<Int>()
        #expect(history.undo(current: 5) == nil)
        #expect(!history.canRedo)
    }
}
