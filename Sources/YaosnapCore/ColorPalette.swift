import CoreGraphics
import Foundation

/// 调色板：内置色与自定义色的有序列表。顺序即显示顺序，拖拽、导入都会改写它。
/// 自定义色由“不在内置集合中”派生，不再单独存一份索引，避免两份数据失同步。
public struct PaletteModel: Equatable, Codable {
    public static let customLimit = 12

    public static var builtInColors: [RGBAColor] { RGBAColor.palette }

    public static var standard: PaletteModel { PaletteModel() }

    public private(set) var colors: [RGBAColor]

    public init(colors: [RGBAColor] = RGBAColor.palette) {
        self.colors = colors
    }

    public var customColors: [RGBAColor] {
        colors.filter { !Self.isBuiltIn($0) }
    }

    public func isCustom(at index: Int) -> Bool {
        guard colors.indices.contains(index) else { return false }
        return !Self.isBuiltIn(colors[index])
    }

    public static func isBuiltIn(_ color: RGBAColor) -> Bool {
        builtInColors.contains { isSameColor($0, color) }
    }

    public static func isValid(_ color: RGBAColor) -> Bool {
        [color.r, color.g, color.b, color.a].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
    }

    /// 加入自定义色，已存在则不重复。超出上限时丢弃最靠前的自定义色。
    /// 返回是否真的写入。
    @discardableResult
    public mutating func addCustom(_ color: RGBAColor) -> Bool {
        guard Self.isValid(color) else { return false }
        guard !colors.contains(where: { Self.isSameColor($0, color) }) else { return false }
        colors.append(color)
        while customColors.count > Self.customLimit,
              let index = colors.firstIndex(where: { !Self.isBuiltIn($0) }) {
            colors.remove(at: index)
        }
        return true
    }

    public mutating func move(from source: Int, to destination: Int) {
        guard colors.indices.contains(source),
              colors.indices.contains(destination),
              source != destination else { return }
        let color = colors.remove(at: source)
        colors.insert(color, at: destination)
    }

    public mutating func reset() {
        colors = Self.builtInColors
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// 外部 JSON 是边界数据：丢弃非法通道与重复色，自定义色截断到上限，
    /// 并补齐缺失的内置色，避免导入后固定入口消失。
    public static func decode(_ data: Data) -> PaletteModel? {
        guard var model = try? JSONDecoder().decode(PaletteModel.self, from: data),
              !model.colors.isEmpty else { return nil }
        model.normalize()
        return model
    }

    private mutating func normalize() {
        var kept: [RGBAColor] = []
        var customCount = 0
        for color in colors where Self.isValid(color) {
            guard !kept.contains(where: { Self.isSameColor($0, color) }) else { continue }
            if !Self.isBuiltIn(color) {
                guard customCount < Self.customLimit else { continue }
                customCount += 1
            }
            kept.append(color)
        }
        for builtIn in Self.builtInColors
        where !kept.contains(where: { Self.isSameColor($0, builtIn) }) {
            kept.append(builtIn)
        }
        colors = kept
    }

    /// 色块是用户可见的量化颜色，按 1/255 取整后比较，
    /// 避免 NSColorPanel 往返产生的浮点噪声把同一颜色存成两份。
    static func isSameColor(_ lhs: RGBAColor, _ rhs: RGBAColor) -> Bool {
        func quantize(_ value: CGFloat) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }
        return quantize(lhs.r) == quantize(rhs.r)
            && quantize(lhs.g) == quantize(rhs.g)
            && quantize(lhs.b) == quantize(rhs.b)
            && quantize(lhs.a) == quantize(rhs.a)
    }
}

/// 调色板持久化。UserDefaults 注入便于测试用独立 suite，不碰真实偏好。
public struct PaletteStore {
    public static let defaultsKey = "Yaosnap.palette.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> PaletteModel {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let model = PaletteModel.decode(data) else {
            return .standard
        }
        return model
    }

    public func save(_ model: PaletteModel) {
        guard let data = try? model.jsonData() else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
