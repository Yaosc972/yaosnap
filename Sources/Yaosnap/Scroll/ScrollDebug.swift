import CoreGraphics
import Foundation
import YaosnapCore

/// 滚动截屏的实机取证开关。
///
/// 只有存在标记目录 `/tmp/yaosnap-scroll-debug` 时才记录：正常使用零开销、不写任何文件。
/// 排查时 `mkdir -p /tmp/yaosnap-scroll-debug` 再复现一次，就能拿到逐帧决策与最终长图。
/// 排查结束删掉该目录即可。
enum ScrollDebug {
    private static let directory = "/tmp/yaosnap-scroll-debug"

    static var isEnabled: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: directory,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private static let handle: FileHandle? = {
        guard isEnabled else { return nil }
        let path = directory + "/scroll.log"
        try? FileManager.default.removeItem(atPath: path)
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    static func log(_ message: String) {
        guard let handle else { return }
        let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, message)
        guard let data = line.data(using: .utf8) else { return }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    static func save(_ image: CGImage?, name: String) {
        guard isEnabled, let image, let data = ImageOutput.pngData(from: image) else { return }
        try? data.write(to: URL(fileURLWithPath: directory + "/" + name))
    }

    static func reset() {
        guard isEnabled else { return }
        try? FileManager.default.removeItem(atPath: directory + "/scroll.log")
    }
}
