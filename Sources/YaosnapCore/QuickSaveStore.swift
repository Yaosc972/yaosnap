import Foundation

/// 快捷保存的目录与文件名分配。默认 ~/Pictures/Yaosnap，测试用显式 directory 注入。
public struct QuickSaveStore {
    public static let folderName = "Yaosnap"

    public let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public init(fileManager: FileManager = .default) {
        let pictures = fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
        self.init(
            directory: pictures.appendingPathComponent(Self.folderName, isDirectory: true),
            fileManager: fileManager
        )
    }

    @discardableResult
    public func createDirectory() throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 沿用默认命名；同一秒内重复保存时追加 `-2`、`-3`，不覆盖已有文件。
    public func destinationURL(fileName: String = ImageOutput.defaultFileName()) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(fileName)
        var index = 1
        while fileManager.fileExists(atPath: candidate.path) {
            index += 1
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = directory.appendingPathComponent(name)
        }
        return candidate
    }

    /// 目录不存在时创建，然后写入并返回实际路径。
    public func write(_ data: Data, fileName: String = ImageOutput.defaultFileName()) throws -> URL {
        try createDirectory()
        let url = destinationURL(fileName: fileName)
        try data.write(to: url)
        return url
    }
}
