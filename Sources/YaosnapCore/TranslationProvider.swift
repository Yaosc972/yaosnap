import Foundation

/// 截图翻译的后端选择。rawValue 用作持久化与日志标识。
public enum TranslationBackend: String, Codable, CaseIterable, Sendable {
    case system
    case deepSeek

    public var title: String {
        switch self {
        case .system: return "系统本地翻译"
        case .deepSeek: return "DeepSeek"
        }
    }
}

public enum TranslationError: LocalizedError, Equatable {
    /// 系统版本不支持、语言包未安装、源语言无法识别等本机能力问题。
    case unavailable(String)
    case missingCredential
    case badResponse(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail): return detail
        case .missingCredential: return "未配置 DeepSeek API Key，请在设置页填写"
        case .badResponse(let detail): return "翻译服务返回异常：\(detail)"
        case .network(let detail): return "网络请求失败：\(detail)"
        }
    }
}

public protocol TranslationProvider {
    func translate(_ text: String, to targetLanguage: String) async throws -> String
}

/// DeepSeek Chat Completions 翻译。API Key 经注入的闭包读取，默认走 Keychain。
public struct DeepSeekTranslationProvider: TranslationProvider {
    static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    private static let timeout: TimeInterval = 20

    public struct CompletionRequest: Encodable, Equatable {
        public struct Message: Encodable, Equatable {
            public let role: String
            public let content: String

            public init(role: String, content: String) {
                self.role = role
                self.content = content
            }
        }

        public let model: String
        public let messages: [Message]
        public let stream: Bool
    }

    private struct CompletionResponse: Decodable {
        struct Choice: Decodable {
            let message: Message
        }
        struct Message: Decodable {
            let content: String?
        }
        let choices: [Choice]?
    }

    private let model: String
    private let loadCredential: () -> String?

    public init(
        model: String,
        loadCredential: @escaping () -> String? = { TranslationCredentialStore().load() }
    ) {
        self.model = model
        self.loadCredential = loadCredential
    }

    public func translate(_ text: String, to targetLanguage: String) async throws -> String {
        guard let apiKey = loadCredential(), !apiKey.isEmpty else {
            throw TranslationError.missingCredential
        }
        let request = try Self.makeRequest(
            text: text, model: model, apiKey: apiKey, targetLanguage: targetLanguage
        )
        let session = URLSession(configuration: .ephemeral)
        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw TranslationError.network((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
        return try Self.parseResponse(data)
    }

    static func requestBody(text: String, model: String, targetLanguage: String) -> CompletionRequest {
        CompletionRequest(
            model: model,
            messages: [
                .init(
                    role: "system",
                    content: "Translate the user's text into \(targetLanguage). Output only the translation, no explanations."
                ),
                .init(role: "user", content: text),
            ],
            stream: false
        )
    }

    static func makeRequest(
        text: String,
        model: String,
        apiKey: String,
        targetLanguage: String
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody(text: text, model: model, targetLanguage: targetLanguage))
        return request
    }

    static func parseResponse(_ data: Data) throws -> String {
        guard let response = try? JSONDecoder().decode(CompletionResponse.self, from: data),
              let content = response.choices?.first?.message.content,
              !content.isEmpty
        else {
            let raw = String(data: data, encoding: .utf8) ?? "响应不是 UTF-8 文本"
            throw TranslationError.badResponse(raw)
        }
        return content
    }
}
