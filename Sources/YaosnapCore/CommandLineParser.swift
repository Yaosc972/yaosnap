import Foundation

public enum CommandLineParseOutcome: Equatable, Sendable {
    case help
    case request(CommandLineRequest)
}

public enum CommandLineParseError: Error, Equatable, Sendable {
    case unknownArgument(String)
    case missingValue(String)
    case extraArgument(String)
    case invalidNumber(String)
    case invalidDelay(String)
}

/// 解析 Snipaste 风格的命令行参数。纯函数，不做 I/O，也不启动 app。
public enum CommandLineParser {
    public static let usage = """
    用法：
      snip                         启动截图
      snip --delay N               延时 N 秒截屏（1-60）
      snip -o clipboard            最近截图复制到剪贴板
      snip -o quick-save           最近截图存入快捷保存文件夹
      snip -o FILE_NAME            最近截图保存到指定文件
      snip --pos X Y               最近截图贴到指定位置
      snip pick-color              选取屏幕像素颜色并复制
      snip barcode-scan            识别屏幕二维码/条形码并复制
      snip show-images             显示所有贴图
      snip hide-images             隐藏所有贴图
      snip whiteboard [--color C] [--active-screen]
                                   进入白板模式；C 为颜色名或 #RRGGBB，
                                   --active-screen 只在光标所在屏开启
      snip --help                  显示本帮助
    """

    public static func parse(_ arguments: [String]) throws -> CommandLineParseOutcome {
        var arguments = arguments
        if arguments.first == "snip" {
            arguments.removeFirst()
        }
        if let first = arguments.first, first == "--help" || first == "-h" {
            return .help
        }
        if arguments.isEmpty {
            return .request(CommandLineRequest(command: .snip))
        }
        if arguments.count == 1, let command = standaloneCommand(arguments[0]) {
            return .request(CommandLineRequest(command: command))
        }

        switch arguments[0] {
        case "--delay":
            guard arguments.count >= 2, !arguments[1].isEmpty else {
                throw CommandLineParseError.missingValue("--delay N")
            }
            guard arguments.count == 2 else {
                throw CommandLineParseError.extraArgument(arguments[2])
            }
            guard let seconds = DelayCapture.seconds(from: arguments[1]) else {
                throw CommandLineParseError.invalidDelay(arguments[1])
            }
            return .request(CommandLineRequest(command: .delayedSnip(seconds: seconds)))
        case "-o":
            guard arguments.count >= 2, !arguments[1].isEmpty else {
                throw CommandLineParseError.missingValue("-o")
            }
            guard arguments.count == 2 else {
                throw CommandLineParseError.extraArgument(arguments[2])
            }
            return .request(CommandLineRequest(command: outputCommand(arguments[1])))
        case "--pos":
            guard arguments.count >= 3 else {
                throw CommandLineParseError.missingValue("--pos X Y")
            }
            guard arguments.count == 3 else {
                throw CommandLineParseError.extraArgument(arguments[3])
            }
            return .request(CommandLineRequest(
                command: .pin(x: try coordinate(arguments[1]), y: try coordinate(arguments[2]))
            ))
        case "whiteboard":
            return .request(CommandLineRequest(command: try whiteboardCommand(arguments)))
        default:
            throw CommandLineParseError.unknownArgument(arguments[0])
        }
    }

    private static func standaloneCommand(_ argument: String) -> CommandLineCommand? {
        switch argument {
        case "pick-color": return .pickColor
        case "barcode-scan": return .barcodeScan
        case "show-images": return .showImages
        case "hide-images": return .hideImages
        default: return nil
        }
    }

    /// 白板选项顺序自由，未知选项直接报错，避免把一个拼错的开关当成默认白板启动。
    private static func whiteboardCommand(_ arguments: [String]) throws -> CommandLineCommand {
        var color: RGBAColor?
        var activeScreen = false
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--color":
                guard index + 1 < arguments.count, !arguments[index + 1].isEmpty else {
                    throw CommandLineParseError.missingValue("--color COLOR")
                }
                color = WhiteboardColor.parseOrDefault(arguments[index + 1])
                index += 2
            case "--active-screen":
                activeScreen = true
                index += 1
            default:
                throw CommandLineParseError.unknownArgument(arguments[index])
            }
        }
        return .whiteboard(color: color, activeScreen: activeScreen)
    }

    private static func outputCommand(_ value: String) -> CommandLineCommand {
        switch value {
        case "clipboard": return .clipboard
        case "quick-save": return .quickSave
        default: return .save(path: value)
        }
    }

    private static func coordinate(_ raw: String) throws -> Double {
        guard let value = Double(raw), value.isFinite else {
            throw CommandLineParseError.invalidNumber(raw)
        }
        return value
    }
}
