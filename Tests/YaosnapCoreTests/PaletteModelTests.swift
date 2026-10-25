import Foundation
import Testing
@testable import YaosnapCore

struct PaletteModelTests {
    private let customA = RGBAColor(r: 0.13, g: 0.42, b: 0.77, a: 0.6)
    private let customB = RGBAColor(r: 0.71, g: 0.18, b: 0.34, a: 1)

    @Test func addingCustomAppendsAndKeepsAlpha() {
        var model = PaletteModel.standard

        let added = model.addCustom(customA)

        #expect(added)
        #expect(model.colors.count == RGBAColor.palette.count + 1)
        #expect(model.customColors.count == 1)
        #expect(model.customColors[0] == customA)
        #expect(model.colors.last?.a == 0.6)
    }

    @Test func duplicateAndBuiltInColorsAreNotAdded() {
        var model = PaletteModel.standard

        let first = model.addCustom(customA)
        let duplicate = model.addCustom(customA)
        let builtIn = model.addCustom(RGBAColor.palette[0])
        // 量化到 1/255 后同一个颜色也算重复。
        let nearDuplicate = model.addCustom(RGBAColor(r: 0.1301, g: 0.42, b: 0.77, a: 0.6))

        #expect(first)
        #expect(!duplicate)
        #expect(!builtIn)
        #expect(!nearDuplicate)
        #expect(model.colors.count == RGBAColor.palette.count + 1)
    }

    @Test func customColorsAreCappedByDroppingOldest() {
        var model = PaletteModel.standard
        for index in 1...13 {
            model.addCustom(RGBAColor(r: CGFloat(index) / 20, g: 0.1, b: 0.2, a: 1))
        }

        #expect(model.customColors.count == PaletteModel.customLimit)
        #expect(model.customColors.first?.r == 0.1) // index 1 被挤出
        #expect(model.colors.count == RGBAColor.palette.count + PaletteModel.customLimit)
    }

    @Test func moveReordersWithoutChangingContent() {
        var model = PaletteModel.standard
        model.addCustom(customA)
        model.addCustom(customB)
        let before = Set(model.colors)

        model.move(from: 13, to: 0)

        #expect(model.colors[0] == customB)
        #expect(model.colors.last == customA)
        #expect(Set(model.colors) == before)
        #expect(model.colors.count == before.count)
    }

    @Test func moveIgnoresOutOfRangeIndexes() {
        var model = PaletteModel.standard
        let before = model.colors

        model.move(from: 0, to: 99)
        model.move(from: -1, to: 0)
        model.move(from: 3, to: 3)

        #expect(model.colors == before)
    }

    @Test func jsonRoundTripPreservesOrderAndAlpha() throws {
        var model = PaletteModel.standard
        model.addCustom(customA)
        model.addCustom(customB)
        model.move(from: 12, to: 0)

        let decoded = try #require(PaletteModel.decode(try model.jsonData()))

        #expect(decoded == model)
    }

    @Test func decodingRestoresMissingBuiltInsAndDropsInvalidCustoms() throws {
        let onlyCustom = PaletteModel(colors: [customA])
        let decoded = try #require(PaletteModel.decode(try onlyCustom.jsonData()))

        #expect(decoded.colors.first == customA)
        #expect(decoded.customColors.count == 1)
        #expect(decoded.colors.count == RGBAColor.palette.count + 1)
        #expect(PaletteModel.builtInColors.allSatisfy { decoded.colors.contains($0) })
    }

    @Test func resetRestoresBuiltInOrder() {
        var model = PaletteModel.standard
        model.addCustom(customA)
        model.move(from: 12, to: 0)

        model.reset()

        #expect(model.colors == RGBAColor.palette)
        #expect(model.customColors.isEmpty)
    }

    @Test func storeRoundTripsThroughInjectedDefaults() throws {
        let suite = "yaosnap.palette.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PaletteStore(defaults: defaults)

        #expect(store.load() == .standard)

        var model = store.load()
        model.addCustom(customA)
        model.move(from: 12, to: 0)
        store.save(model)

        #expect(store.load() == model)
    }
}
