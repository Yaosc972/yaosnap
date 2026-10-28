import Foundation
import NaturalLanguage
import Translation

/// 系统自带翻译。本 SDK 的直连会话 init 在 macOS 26 起可用，低版本走 .unavailable。
public struct SystemTranslationProvider: TranslationProvider {
    public init() {}

    public func translate(_ text: String, to targetLanguage: String) async throws -> String {
        guard #available(macOS 26.0, *) else {
            throw TranslationError.unavailable("系统翻译需要 macOS 26 及以上")
        }
        return try await translateWithDetectedSource(text, target: Locale.Language(identifier: targetLanguage))
    }

    @available(macOS 26.0, *)
    private func translateWithDetectedSource(_ text: String, target: Locale.Language) async throws -> String {
        // 直连 init 要求显式源语言，选区文字用 NLLanguageRecognizer 现场识别。
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let detected = recognizer.dominantLanguage else {
            throw TranslationError.unavailable("无法识别选区文字的源语言")
        }
        let session = TranslationSession(
            installedSource: Locale.Language(identifier: detected.rawValue),
            target: target
        )
        do {
            try await session.prepareTranslation()
            let response = try await session.translate(text)
            return response.targetText
        } catch Translation.TranslationError.notInstalled {
            // 实测：语言包未装时框架只给「Unable to Translate」，需换成可操作的提示。
            throw TranslationError.unavailable("翻译语言包未安装，请先在系统中下载语言包后重试")
        } catch let error as Translation.TranslationError {
            throw TranslationError.unavailable(error.failureReason ?? error.errorDescription ?? "系统翻译不可用")
        }
    }
}
