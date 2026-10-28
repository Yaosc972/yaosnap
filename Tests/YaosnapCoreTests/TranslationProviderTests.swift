import Foundation
import Testing
@testable import YaosnapCore

struct TranslationProviderTests {
    // MARK: - TranslationBackend

    @Test func backendCodableRoundTrip() throws {
        for backend in TranslationBackend.allCases {
            let data = try JSONEncoder().encode(backend)
            let decoded = try JSONDecoder().decode(TranslationBackend.self, from: data)
            #expect(decoded == backend)
        }
    }

    @Test func backendDecodesRawValues() throws {
        #expect(try JSONDecoder().decode(TranslationBackend.self, from: Data("\"system\"".utf8)) == .system)
        #expect(try JSONDecoder().decode(TranslationBackend.self, from: Data("\"deepSeek\"".utf8)) == .deepSeek)
    }

    // MARK: - DeepSeek 请求构造

    @Test func makeRequestBuildsEndpointHeadersAndTimeout() throws {
        let endpoint = URL(string: "https://api.example.com/v1/chat/completions")!
        let request = try DeepSeekTranslationProvider.makeRequest(
            text: "hello", model: "deepseek-chat", apiKey: "sk-test",
            targetLanguage: "zh", endpoint: endpoint
        )
        #expect(request.httpMethod == "POST")
        #expect(request.url == endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == 20)
    }

    @Test func requestBodyFollowsOpenAICompatShape() throws {
        let body = DeepSeekTranslationProvider.requestBody(
            text: "good morning", model: "deepseek-reasoner", targetLanguage: "en"
        )
        #expect(body.model == "deepseek-reasoner")
        #expect(body.stream == false)
        #expect(body.messages.count == 2)
        #expect(body.messages[0].role == "system")
        #expect(body.messages[0].content.contains("en"))
        #expect(body.messages[0].content.contains("no explanations"))
        #expect(body.messages[1].role == "user")
        #expect(body.messages[1].content == "good morning")
    }

    @Test func requestEncodingProducesJsonBody() throws {
        let request = try DeepSeekTranslationProvider.makeRequest(
            text: "你好", model: "deepseek-chat", apiKey: "k", targetLanguage: "ja",
            endpoint: URL(string: DeepSeekTranslationProvider.defaultEndpoint)!
        )
        let json = try #require(
            JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        )
        #expect(json["model"] as? String == "deepseek-chat")
        #expect(json["stream"] as? Bool == false)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "你好")
    }

    // MARK: - DeepSeek 响应解析

    @Test func parseResponseReturnsFirstChoiceContent() throws {
        let payload = """
        {"choices":[{"index":0,"message":{"role":"assistant","content":"早上好"}}]}
        """
        let content = try DeepSeekTranslationProvider.parseResponse(Data(payload.utf8))
        #expect(content == "早上好")
    }

    @Test func parseResponseRejectsMissingFields() {
        for payload in ["{}", "{\"choices\":[]}", "{\"choices\":[{\"message\":{}}]}"] {
            #expect(throws: TranslationError.badResponse(payload)) {
                try DeepSeekTranslationProvider.parseResponse(Data(payload.utf8))
            }
        }
    }

    @Test func parseResponseRejectsNonJSON() {
        #expect(throws: TranslationError.badResponse("not json")) {
            try DeepSeekTranslationProvider.parseResponse(Data("not json".utf8))
        }
    }

    @Test func emptyCredentialThrowsMissingCredential() async {
        let provider = DeepSeekTranslationProvider(model: "deepseek-chat", loadCredential: { nil })
        await #expect(throws: TranslationError.missingCredential) {
            try await provider.translate("hello", to: "zh")
        }
    }

    // MARK: - 错误文案

    @Test func errorsCarryUsableDescriptions() {
        #expect(TranslationError.missingCredential.errorDescription?.contains("设置") == true)
        #expect(TranslationError.unavailable("语言包未安装").errorDescription == "语言包未安装")
        #expect(TranslationError.network("断网").errorDescription?.contains("断网") == true)
        #expect(TranslationError.badResponse("x").errorDescription?.contains("x") == true)
    }

    // MARK: - 翻译方向

    @Test func autoTargetFlipsBySourceLanguage() {
        #expect(TranslationTargetResolver.resolve(.auto, text: "这是一段中文说明") == "en")
        #expect(TranslationTargetResolver.resolve(.auto, text: "hello world") == "zh")
        #expect(TranslationTargetResolver.resolve(.auto, text: "12345") == "zh")
    }

    @Test func explicitTargetWinsOverDetection() {
        #expect(TranslationTargetResolver.resolve(.en, text: "这是一段中文说明") == "en")
        #expect(TranslationTargetResolver.resolve(.ja, text: "hello") == "ja")
    }

    @Test func targetCyclesThroughAllCases() {
        #expect(TranslationTarget.auto.next == .zh)
        #expect(TranslationTarget.zh.next == .en)
        #expect(TranslationTarget.ko.next == .auto)
    }
}
