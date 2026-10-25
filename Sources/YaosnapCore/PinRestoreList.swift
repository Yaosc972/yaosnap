import CoreGraphics
import Foundation

/// 关闭原因决定是否进入恢复列表：销毁（Shift+Esc）不进，普通关闭才进。
public enum PinCloseKind: Equatable {
    case closed
    case destroyed
}

/// 重建一张贴图所需的最小状态。窗口尺寸由 basePointSize 与 transform 推导，frame 记录关闭时的位置。
public struct PinRestoreEntry {
    public let image: PasteImage
    public let transform: PinTransform
    public let frame: CGRect
    public let basePointSize: CGSize

    public init(image: PasteImage, transform: PinTransform, frame: CGRect, basePointSize: CGSize) {
        self.image = image
        self.transform = transform
        self.frame = frame
        self.basePointSize = basePointSize
    }
}

/// 最近关闭的贴图，超出容量时丢最旧的。
public struct PinRestoreList<Entry> {
    public let capacity: Int
    private var entries: [Entry] = []

    public init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public var mostRecent: Entry? { entries.last }

    public mutating func record(_ entry: Entry, kind: PinCloseKind) {
        guard kind == .closed, capacity > 0 else { return }
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// 恢复即消费，避免同一张关闭的贴图被反复贴出。
    public mutating func takeMostRecent() -> Entry? {
        entries.popLast()
    }
}

public enum PinHitTest {
    /// frames 按从底到顶排列，返回光标下最上层可见贴图的下标。
    public static func topmostIndex(of point: CGPoint, in frames: [CGRect], visible: [Bool]) -> Int? {
        guard frames.count == visible.count else { return nil }
        return frames.indices.last { index in
            visible[index] && frames[index].contains(point)
        }
    }
}

public enum PinPassthrough {
    /// index 为 nil 表示光标下没有贴图，此时取消全部穿透。
    public static func toggled(index: Int?, states: [Bool]) -> [Bool] {
        guard let index, states.indices.contains(index) else {
            return states.map { _ in false }
        }
        var next = states
        next[index].toggle()
        return next
    }
}

extension PasteImage {
    /// 判定剪贴板内容是否仍是上次贴出的那一份：点尺寸与位图字节都相同。
    public static func sameContent(_ lhs: PasteImage?, _ rhs: PasteImage?) -> Bool {
        guard let lhs, let rhs else { return false }
        guard lhs.pointSize == rhs.pointSize,
              lhs.image.width == rhs.image.width,
              lhs.image.height == rhs.image.height else { return false }
        guard let left = lhs.image.dataProvider?.data as Data?,
              let right = rhs.image.dataProvider?.data as Data? else {
            return lhs.image === rhs.image
        }
        return left == right
    }
}
