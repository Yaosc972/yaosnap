import CoreGraphics

/// 贴图多选集合。只记录选中的贴图 ID，可见性与分组仍由 PinBoard 决定。
public struct PinSelection: Equatable {
    public private(set) var ids: Set<Int>

    public init(ids: Set<Int> = []) {
        self.ids = ids
    }

    public var count: Int { ids.count }
    public var isEmpty: Bool { ids.isEmpty }

    public func contains(_ pinID: Int) -> Bool { ids.contains(pinID) }

    /// Shift 点击：已在集合里则移出，否则加入。返回操作后是否被选中。
    @discardableResult
    public mutating func toggle(_ pinID: Int) -> Bool {
        if ids.contains(pinID) {
            ids.remove(pinID)
            return false
        }
        ids.insert(pinID)
        return true
    }

    public mutating func remove(_ pinID: Int) { ids.remove(pinID) }

    public mutating func selectAll(_ pinIDs: [Int]) { ids = Set(pinIDs) }

    public mutating func clear() { ids.removeAll() }

    /// 整组拖动：每张贴图加同一个偏移，任何一张都不会被落下或多走。
    public static func moved(origins: [Int: CGPoint], by delta: CGPoint) -> [Int: CGPoint] {
        origins.mapValues { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
    }
}
