import CoreGraphics
import Vision

/// 截图二维码 / 条形码识别。只做识别，不碰剪贴板。
public enum BarcodeScanner {
    /// 返回第一条带内容的识别结果。图中没有可识别码时返回 nil。
    public static func scanFirstPayload(in image: CGImage) -> String? {
        let request = VNDetectBarcodesRequest()
        // symbologies 留空表示默认全部支持码制，二维码与条形码一起识别。
        // supportedSymbologies 在 macOS 12 起废弃，不显式赋值。

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        for observation in request.results ?? [] {
            if let payload = observation.payloadStringValue, !payload.isEmpty {
                return payload
            }
        }
        return nil
    }
}
