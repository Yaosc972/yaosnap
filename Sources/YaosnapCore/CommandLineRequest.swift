import Foundation

/// 命令行请求的领域形状。每个 case 自带所需参数，避免用字符串字典传递未校验的查询项。
public enum CommandLineCommand: Equatable, Sendable {
    case snip
    case delayedSnip(seconds: Int)
    case clipboard
    case save(path: String)
    case quickSave
    case pin(x: Double, y: Double)
    case pickColor
    case barcodeScan
    case showImages
    case hideImages
    case whiteboard(background: WhiteboardBackground?, activeScreen: Bool)
}

public enum CommandLineRequestError: Error, Equatable, Sendable {
    case invalidURL
    case unsupportedCommand(String)
    case missingParameter(String)
    case invalidParameter(String)
}

/// CLI 与 app 之间的 URL 契约：`yaosnap://<command>?<query>`。
public struct CommandLineRequest: Equatable, Sendable {
    public static let scheme = "yaosnap"

    public let command: CommandLineCommand

    public init(command: CommandLineCommand) {
        self.command = command
    }

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme,
              let host = components.host?.lowercased()
        else {
            throw CommandLineRequestError.invalidURL
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        func requiredValue(_ name: String) throws -> String {
            guard let value = value(name), !value.isEmpty else {
                throw CommandLineRequestError.missingParameter(name)
            }
            return value
        }
        func requiredNumber(_ name: String) throws -> Double {
            let raw = try requiredValue(name)
            guard let number = Double(raw), number.isFinite else {
                throw CommandLineRequestError.invalidParameter(name)
            }
            return number
        }

        switch host {
        case "snip":
            if let raw = value("delay") {
                guard let seconds = DelayCapture.seconds(from: raw) else {
                    throw CommandLineRequestError.invalidParameter("delay")
                }
                command = .delayedSnip(seconds: seconds)
            } else {
                command = .snip
            }
        case "clipboard":
            command = .clipboard
        case "save":
            command = .save(path: try requiredValue("path"))
        case "quick-save":
            command = .quickSave
        case "pin":
            command = .pin(x: try requiredNumber("x"), y: try requiredNumber("y"))
        case "pick-color":
            command = .pickColor
        case "barcode-scan":
            command = .barcodeScan
        case "show-images":
            command = .showImages
        case "hide-images":
            command = .hideImages
        case "whiteboard":
            var background: WhiteboardBackground?
            if let raw = value("color"), !raw.isEmpty {
                background = WhiteboardBackground.parseOrDefault(raw)
            }
            var activeScreen = false
            if let raw = value("active_screen"), !raw.isEmpty {
                switch raw.lowercased() {
                case "1", "true": activeScreen = true
                case "0", "false": activeScreen = false
                default: throw CommandLineRequestError.invalidParameter("active_screen")
                }
            }
            command = .whiteboard(background: background, activeScreen: activeScreen)
        default:
            throw CommandLineRequestError.unsupportedCommand(host)
        }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch command {
        case .snip:
            components.host = "snip"
        case .delayedSnip(let seconds):
            components.host = "snip"
            components.queryItems = [URLQueryItem(name: "delay", value: String(seconds))]
        case .clipboard:
            components.host = "clipboard"
        case .save(let path):
            components.host = "save"
            components.queryItems = [URLQueryItem(name: "path", value: path)]
        case .quickSave:
            components.host = "quick-save"
        case .pin(let x, let y):
            components.host = "pin"
            components.queryItems = [
                URLQueryItem(name: "x", value: Self.queryNumber(x)),
                URLQueryItem(name: "y", value: Self.queryNumber(y)),
            ]
        case .pickColor:
            components.host = "pick-color"
        case .barcodeScan:
            components.host = "barcode-scan"
        case .showImages:
            components.host = "show-images"
        case .hideImages:
            components.host = "hide-images"
        case .whiteboard(let background, let activeScreen):
            components.host = "whiteboard"
            var items: [URLQueryItem] = []
            if let background {
                let value: String
                switch background {
                case .solid(let color): value = color.hexString
                case .transparent: value = "transparent"
                }
                items.append(URLQueryItem(name: "color", value: value))
            }
            if activeScreen {
                items.append(URLQueryItem(name: "active_screen", value: "1"))
            }
            if !items.isEmpty { components.queryItems = items }
        }
        // scheme 与 host 都来自本文件的常量，URLComponents 不会拒绝这组输入。
        return components.url!
    }

    /// 整数值不带 `.0`，让 `--pos 12 34` 生成 `x=12&y=34` 而不是 `x=12.0`。
    private static func queryNumber(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }
}
