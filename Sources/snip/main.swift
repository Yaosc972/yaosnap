import AppKit
import Foundation
import YaosnapCore

private func message(for error: Error) -> String {
    guard let error = error as? CommandLineParseError else {
        return String(describing: error)
    }
    switch error {
    case .unknownArgument(let argument):
        return "无法识别的参数：\(argument)"
    case .missingValue(let option):
        return "\(option) 缺少参数"
    case .extraArgument(let argument):
        return "多余的参数：\(argument)"
    case .invalidNumber(let value):
        return "坐标必须是数字：\(value)"
    }
}

/// app 进程的工作目录与调用 CLI 的目录不同，保存路径必须在这里就变成绝对路径。
private func resolveSavePath(_ request: CommandLineRequest) -> CommandLineRequest {
    guard case .save(let path) = request.command else { return request }
    let expanded = (path as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded).standardizedFileURL
    return CommandLineRequest(command: .save(path: url.path))
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch try CommandLineParser.parse(arguments) {
    case .help:
        print(CommandLineParser.usage)
    case .request(let request):
        let resolved = resolveSavePath(request)
        guard NSWorkspace.shared.open(resolved.url) else {
            FileHandle.standardError.write(
                Data("无法交给 Yaosnap 处理：\(resolved.url.absoluteString)\n".utf8)
            )
            exit(1)
        }
    }
} catch {
    FileHandle.standardError.write(
        Data("参数错误：\(message(for: error))\n\n\(CommandLineParser.usage)\n".utf8)
    )
    exit(2)
}
