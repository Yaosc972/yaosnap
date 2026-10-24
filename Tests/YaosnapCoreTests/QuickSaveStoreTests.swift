import Foundation
import Testing
@testable import YaosnapCore

struct QuickSaveStoreTests {
    private func workspace() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("yaosnap-quicksave-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func defaultDirectorySitsUnderPictures() {
        let store = QuickSaveStore()
        #expect(store.directory.lastPathComponent == "Yaosnap")
        #expect(store.directory.deletingLastPathComponent().lastPathComponent == "Pictures")
    }

    @Test func writeCreatesMissingDirectoryAndUsesDefaultName() throws {
        let root = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Yaosnap", isDirectory: true)
        let store = QuickSaveStore(directory: directory)

        let url = try store.write(Data("png".utf8))

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        #expect(url.lastPathComponent.hasPrefix("Yaosnap_"))
        #expect(url.pathExtension == "png")
    }

    @Test func destinationURLReusesTimestampName() {
        let root = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QuickSaveStore(directory: root)

        let first = store.destinationURL(fileName: "Yaosnap_2026-10-25_10-00-00.png")
        let second = store.destinationURL(fileName: "Yaosnap_2026-10-25_10-00-00.png")

        #expect(first.lastPathComponent == "Yaosnap_2026-10-25_10-00-00.png")
        #expect(second == first)
    }

    @Test func existingFileGetsNumericSuffix() throws {
        let root = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("Yaosnap_2026-10-25_10-00-00.png"))
        let store = QuickSaveStore(directory: root)

        let next = store.destinationURL(fileName: "Yaosnap_2026-10-25_10-00-00.png")

        #expect(next.lastPathComponent == "Yaosnap_2026-10-25_10-00-00-2.png")
    }
}
