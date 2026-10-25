import CoreGraphics
import CoreImage
import Vision

/// 截图二维码 / 条形码识别。只做识别，不碰剪贴板。
public enum BarcodeScanner {
    /// 返回第一条带内容的识别结果。图中没有可识别码时返回 nil。
    public static func scanFirstPayload(in image: CGImage) -> String? {
        visionPayload(in: image) ?? coreImagePayload(in: image)
    }

    private static func visionPayload(in image: CGImage) -> String? {
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

    /// Vision 的条码模型要在 ANE 上编译，系统 ANE 故障时整条请求直接抛错，
    /// 二维码也就一起失效。CIDetector 走 CPU/GPU，作为二维码兜底。
    /// 它不识别一维条形码，条形码仍只由 Vision 负责。
    private static func coreImagePayload(in image: CGImage) -> String? {
        guard let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ) else {
            return nil
        }
        for feature in detector.features(in: CIImage(cgImage: image)) {
            if let qr = feature as? CIQRCodeFeature,
               let payload = qr.messageString, !payload.isEmpty {
                return payload
            }
        }
        return nil
    }
}
