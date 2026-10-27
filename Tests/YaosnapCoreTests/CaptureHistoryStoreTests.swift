import CoreGraphics
import Foundation
import Testing
@testable import YaosnapCore

struct CaptureHistoryStoreTests {
    private let fileManager = FileManager.default

    private func temporaryDirectory() -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("CaptureHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        try #require(WhiteboardImage.make(
            width: width,
            height: height,
            background: .solid(.black)
        ))
    }

    private func makeEntry(
        width: Int,
        height: Int,
        displaySize: CGSize? = nil,
        at time: TimeInterval
    ) throws -> CaptureHistoryEntry {
        CaptureHistoryEntry(
            image: try makeImage(width: width, height: height),
            displaySize: displaySize ?? CGSize(width: width / 2, height: height / 2),
            createdAt: Date(timeIntervalSince1970: time)
        )
    }

    private func pngFiles(in directory: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }
    }

    @Test func appendThenLoadRoundTripsImageAndMetadata() throws {
        let directory = temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let store = CaptureHistoryStore(directory: directory, limit: 5)
        let entry = try makeEntry(
            width: 40,
            height: 30,
            displaySize: CGSize(width: 120, height: 90),
            at: 1_700_000_000
        )

        try store.append(entry)
        // 新建实例读盘，等价于进程重启后重新载入历史。
        let loaded = try CaptureHistoryStore(directory: directory, limit: 5).load()

        #expect(loaded.count == 1)
        let first = try #require(loaded.first)
        #expect(first.image.width == 40)
        #expect(first.image.height == 30)
        #expect(first.displaySize == CGSize(width: 120, height: 90))
        #expect(first.createdAt.timeIntervalSince1970 == 1_700_000_000)
        #expect(first.region == nil)
        #expect(try pngFiles(in: directory).count == 1)
    }

    @Test func appendBeyondLimitDropsOldestFileAndIndexEntry() throws {
        let directory = temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let store = CaptureHistoryStore(directory: directory, limit: 2)

        for index in 0..<3 {
            try store.append(try makeEntry(
                width: 10 + index,
                height: 10,
                at: 1_700_000_000 + Double(index)
            ))
        }

        let loaded = try store.load()
        #expect(loaded.count == 2)
        #expect(loaded.map(\.image.width) == [12, 11])
        #expect(try pngFiles(in: directory).count == 2)
    }

    @Test func clearEmptiesMemoryViewAndDisk() throws {
        let directory = temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let store = CaptureHistoryStore(directory: directory, limit: 5)
        try store.append(try makeEntry(width: 20, height: 20, at: 1_700_000_000))
        try store.append(try makeEntry(width: 21, height: 20, at: 1_700_000_001))
        #expect(try store.load().count == 2)

        try store.clear()

        #expect(try store.load().isEmpty)
        #expect(try pngFiles(in: directory).isEmpty)
        #expect(!fileManager.fileExists(
            atPath: directory.appendingPathComponent(CaptureHistoryStore.indexFileName).path
        ))
    }

    @Test func loadSkipsCorruptAndMissingFiles() throws {
        let directory = temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let store = CaptureHistoryStore(directory: directory, limit: 5)
        for index in 0..<3 {
            try store.append(try makeEntry(
                width: 30 + index,
                height: 20,
                at: 1_700_000_000 + Double(index)
            ))
        }

        // 文件名带毫秒时间戳，按名称排序即按写入时间从旧到新。
        let files = try pngFiles(in: directory).sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
        #expect(files.count == 3)
        try Data([0x00, 0x01, 0x02]).write(to: files[0])
        try fileManager.removeItem(at: files[1])

        let loaded = try store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.image.width == 32)
    }

    @Test func missingDirectoryIsCreatedOnAppendAndLoadsAsEmpty() throws {
        let directory = temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let store = CaptureHistoryStore(directory: directory, limit: 5)

        #expect(!fileManager.fileExists(atPath: directory.path))
        #expect(try store.load().isEmpty)

        try store.append(try makeEntry(width: 15, height: 15, at: 1_700_000_000))

        #expect(fileManager.fileExists(atPath: directory.path))
        #expect(try store.load().count == 1)
    }

    @Test func appendThenLoadPreservesRegion() throws {
        let directory = temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let store = CaptureHistoryStore(directory: directory, limit: 5)
        let region = CaptureRegion(
            displayID: 1,
            rect: CGRect(x: 120, y: 60, width: 400, height: 300),
            displayBounds: CGRect(x: 0, y: 0, width: 1470, height: 956)
        )
        let entry = CaptureHistoryEntry(
            image: try makeImage(width: 800, height: 600),
            displaySize: CGSize(width: 400, height: 300),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            region: region
        )
        try store.append(entry)

        let loaded = try CaptureHistoryStore(directory: directory, limit: 5).load()
        let first = try #require(loaded.first)
        #expect(first.region == region)
    }
}
