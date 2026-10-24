import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import YaosnapCore

struct BarcodeScannerTests {
    private func makeQRCode(_ payload: String) -> CGImage {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        // 生成图只有几十像素，放大到 Vision 稳定的检测尺寸。
        let scaled = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return CIContext().createCGImage(scaled, from: scaled.extent)!
    }

    private func makeBlankImage() -> CGImage {
        let ctx = CGContext(
            data: nil, width: 320, height: 320,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 320))
        return ctx.makeImage()!
    }

    @Test func readsQRCodePayload() {
        let payload = "yaosnap-qr-2026"
        #expect(BarcodeScanner.scanFirstPayload(in: makeQRCode(payload)) == payload)
    }

    @Test func blankImageReturnsNil() {
        #expect(BarcodeScanner.scanFirstPayload(in: makeBlankImage()) == nil)
    }
}
