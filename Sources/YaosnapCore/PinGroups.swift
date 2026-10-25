import Foundation

/// 贴图分组与 Solo 的唯一状态源。只描述「哪些贴图应该可见」，
/// 窗口的实际显隐由 PinController 按这里的结果执行。
public struct PinBoard: Equatable {
    public struct Group: Equatable, Identifiable {
        public let id: Int
        public var name: String

        public var isDefault: Bool { id == PinBoard.defaultGroupID }
    }

    public static let defaultGroupID = 0
    public static let defaultGroupName = "默认"

    public private(set) var groups: [Group]
    public private(set) var activeGroupID = PinBoard.defaultGroupID
    public private(set) var soloPinID: Int?
    /// 已知贴图 -> 分组；默认组的贴图也登记，Solo 才能拒绝不存在的贴图。
    private var assignments: [Int: Int] = [:]
    private var nextGroupID = 1

    public init() {
        groups = [Group(id: Self.defaultGroupID, name: Self.defaultGroupName)]
    }

    public func group(id: Int) -> Group? {
        groups.first { $0.id == id }
    }

    public func groupID(of pinID: Int) -> Int {
        assignments[pinID] ?? Self.defaultGroupID
    }

    public func pins(inGroup id: Int) -> [Int] {
        assignments.filter { $0.value == id }.keys.sorted()
    }

    /// 组名去掉首尾空白后必须非空且不与现有组重名。
    @discardableResult
    public mutating func addGroup(named rawName: String) -> Int? {
        guard let name = Self.normalizedName(rawName),
              !groups.contains(where: { $0.name == name }) else { return nil }
        let id = nextGroupID
        nextGroupID += 1
        groups.append(Group(id: id, name: name))
        return id
    }

    @discardableResult
    public mutating func renameGroup(id: Int, to rawName: String) -> Bool {
        guard let name = Self.normalizedName(rawName),
              let index = groups.firstIndex(where: { $0.id == id }),
              !groups.contains(where: { $0.id != id && $0.name == name }) else { return false }
        groups[index].name = name
        return true
    }

    /// 删除组时把组内贴图移到默认组，返回被移动的贴图。默认组不可删。
    @discardableResult
    public mutating func deleteGroup(id: Int) -> [Int] {
        guard id != Self.defaultGroupID, group(id: id) != nil else { return [] }
        let moved = pins(inGroup: id)
        for pinID in moved {
            assignments[pinID] = Self.defaultGroupID
        }
        groups.removeAll { $0.id == id }
        if activeGroupID == id {
            activeGroupID = Self.defaultGroupID
            soloPinID = nil
        }
        return moved
    }

    /// 切组是「看这一组」的明确意图，优先级高于 Solo。
    @discardableResult
    public mutating func activateGroup(id: Int) -> Bool {
        guard group(id: id) != nil else { return false }
        activeGroupID = id
        soloPinID = nil
        return true
    }

    public mutating func assign(pinID: Int, toGroup id: Int) {
        assignments[pinID] = group(id: id) == nil ? Self.defaultGroupID : id
    }

    public mutating func forget(pinID: Int) {
        assignments.removeValue(forKey: pinID)
        if soloPinID == pinID {
            soloPinID = nil
        }
    }

    /// Solo 期间只有那张贴图可见，否则只有激活组的贴图可见。
    public func shouldShow(pinID: Int) -> Bool {
        if let soloPinID {
            return pinID == soloPinID
        }
        return groupID(of: pinID) == activeGroupID
    }

    /// 只允许一张贴图处于 Solo；对另一张开 Solo 会直接接管。
    @discardableResult
    public mutating func beginSolo(pinID: Int) -> Bool {
        guard assignments[pinID] != nil else { return false }
        soloPinID = pinID
        return true
    }

    @discardableResult
    public mutating func endSolo() -> Bool {
        guard soloPinID != nil else { return false }
        soloPinID = nil
        return true
    }

    private static func normalizedName(_ rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
