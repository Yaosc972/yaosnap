import Foundation

/// 撤销 / 重做共用的快照栈。
/// record 记录动作前的状态并作废重做分支；undo / redo 在两个方向之间搬运同一份快照。
public struct SnapshotHistory<State> {
    private var undoStack: [State] = []
    private var redoStack: [State] = []

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func record(_ state: State) {
        undoStack.append(state)
        redoStack.removeAll()
    }

    public mutating func undo(current: State) -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    public mutating func redo(current: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }

    /// 改动本身不进撤销栈（例如拖动位置），但仍要让重做分支失效。
    public mutating func discardRedo() {
        redoStack.removeAll()
    }

    public mutating func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
