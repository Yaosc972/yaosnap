import CoreGraphics
import Foundation
import ImageIO

/// 磁盘上的截图历史：每张图存成一个 PNG，同目录的 `index.json` 记录文件名、
/// 创建时间与当时的显示尺寸。`load()` 会跳过损坏或缺失图片的索引项，
/// 单条坏数据不会让整份历史不可用。
public final class CaptureHistoryStore {
    /// 索引项。不要把 CGImage 直接编码进 JSON，图片本体永远单独存文件。
    private struct IndexEntry: Codable {
        let fileName: String
        let createdAt: Date
        let displayWidth: Double
        let displayHeight: Double
        /// 旧索引没有这个字段，缺失时回放退回等比居中。
        var region: StoredRegion?
    }

    /// 选区在源屏上的位置，回放时按它还原原始大小与位置。
    private struct StoredRegion: Codable {
        let displayID: UInt32
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let displayBoundsWidth: Double
        let displayBoundsHeight: Double

        init(_ region: CaptureRegion) {
            displayID = region.displayID
            x = region.rect.origin.x
            y = region.rect.origin.y
            width = region.rect.width
            height = region.rect.height
            displayBoundsWidth = region.displayBounds.width
            displayBoundsHeight = region.displayBounds.height
        }

        var captureRegion: CaptureRegion {
            CaptureRegion(
                displayID: displayID,
                rect: CGRect(x: x, y: y, width: width, height: height),
                displayBounds: CGRect(
                    x: 0,
                    y: 0,
                    width: displayBoundsWidth,
                    height: displayBoundsHeight
                )
            )
        }
    }

    public enum StoreError: Error, Equatable {
        case pngEncodingFailed
    }

    public static let indexFileName = "index.json"

    public let directory: URL
    public let limit: Int
    private let fileManager: FileManager

    public init(directory: URL, limit: Int = 10, fileManager: FileManager = .default) {
        self.directory = directory
        self.limit = limit
        self.fileManager = fileManager
    }

    /// ~/Library/Application Support/Yaosnap/history
    public static func defaultDirectory() -> URL {
        let fileManager = FileManager.default
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Yaosnap", isDirectory: true)
            .appendingPathComponent("history", isDirectory: true)
    }

    private var indexURL: URL {
        directory.appendingPathComponent(Self.indexFileName)
    }

    /// 目录不存在时返回空历史；索引项按存储顺序（新→旧）还原。
    public func load() throws -> [CaptureHistoryEntry] {
        guard fileManager.fileExists(atPath: indexURL.path) else { return [] }
        let records = try readIndex()
        let capped = records.prefix(max(0, limit))
        var entries: [CaptureHistoryEntry] = []
        for record in capped {
            let url = directory.appendingPathComponent(record.fileName)
            guard fileManager.fileExists(atPath: url.path),
                  let image = Self.loadImage(at: url) else { continue }
            entries.append(CaptureHistoryEntry(
                image: image,
                displaySize: CGSize(
                    width: record.displayWidth,
                    height: record.displayHeight
                ),
                createdAt: record.createdAt,
                region: record.region?.captureRegion
            ))
        }
        return entries
    }

    /// 新图写盘并置顶；超过上限时删除最旧的文件与索引项。
    public func append(_ entry: CaptureHistoryEntry) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        guard let data = ImageOutput.pngData(from: entry.image) else {
            throw StoreError.pngEncodingFailed
        }
        let fileName = Self.fileName(for: entry.createdAt)
        try data.write(
            to: directory.appendingPathComponent(fileName),
            options: .atomic
        )

        // 索引损坏时以空表继续，新图仍然可写；旧文件可能成为孤儿，但不影响可用性。
        var records = (try? readIndex()) ?? []
        records.insert(IndexEntry(
            fileName: fileName,
            createdAt: entry.createdAt,
            displayWidth: Double(entry.displaySize.width),
            displayHeight: Double(entry.displaySize.height),
            region: entry.region.map(StoredRegion.init)
        ), at: 0)

        let capacity = max(0, limit)
        if records.count > capacity {
            let removed = records[capacity...]
            records.removeSubrange(capacity...)
            for item in removed {
                try? fileManager.removeItem(at: fileURL(named: item.fileName))
            }
        }
        try writeIndex(records)
    }

    /// 删除目录里的历史图片与索引，目录本身保留。
    public func clear() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for url in contents {
            let isHistoryFile = url.lastPathComponent == Self.indexFileName
                || url.pathExtension.lowercased() == "png"
            guard isHistoryFile else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    private func fileURL(named name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    private func readIndex() throws -> [IndexEntry] {
        let data = try Data(contentsOf: indexURL)
        return try JSONDecoder().decode([IndexEntry].self, from: data)
    }

    private func writeIndex(_ records: [IndexEntry]) throws {
        let data = try JSONEncoder().encode(records)
        try data.write(to: indexURL, options: .atomic)
    }

    /// 毫秒时间戳 + 随机后缀，同一秒内连续截图也不会撞名。
    private static func fileName(for date: Date) -> String {
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        return "history-\(millis)-\(UUID().uuidString.prefix(8)).png"
    }

    private static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
