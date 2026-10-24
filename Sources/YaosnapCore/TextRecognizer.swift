import CoreGraphics
import Vision

/// 截图文字识别。只做识别，不碰界面与剪贴板。
public enum TextRecognizer {
    /// 按阅读顺序返回文字，行之间换行。识别失败或图中没有文字时返回空串。
    public static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // 简体中文优先，英文同时保留；混合排版由 Vision 在候选里挑。
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        guard let observations = request.results else { return "" }
        return readingOrder(observations)
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// Vision 按检测顺序返回，不保证跨行阅读顺序。
    /// 先按视觉行聚簇，行内从左到右，行间从上到下。
    static func readingOrder(
        _ observations: [VNRecognizedTextObservation]
    ) -> [VNRecognizedTextObservation] {
        let topDown = observations.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        var lines: [[VNRecognizedTextObservation]] = []
        for observation in topDown {
            if let index = lines.firstIndex(where: {
                sameLine($0[0].boundingBox, observation.boundingBox)
            }) {
                lines[index].append(observation)
            } else {
                lines.append([observation])
            }
        }
        return lines.flatMap { line in
            line.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        }
    }

    /// boundingBox 原点在左下，y 越大越靠上。垂直重叠过半视为同一行。
    private static func sameLine(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let overlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        return overlap > min(lhs.height, rhs.height) * 0.5
    }
}
