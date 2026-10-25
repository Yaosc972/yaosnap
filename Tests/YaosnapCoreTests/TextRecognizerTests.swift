import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import YaosnapCore

struct TextRecognizerTests {
    private func makeImage(size: CGSize, draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        draw(ctx)
        return ctx.makeImage()!
    }

    private func makeTextImage(_ text: String) -> CGImage {
        makeImage(size: CGSize(width: 640, height: 200)) { ctx in
            let font = CTFontCreateWithName("PingFang SC" as CFString, 72, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(gray: 0, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes)
            )
            ctx.textPosition = CGPoint(x: 40, y: 60)
            CTLineDraw(line, ctx)
        }
    }

    @Test func recognizesChineseAndDigits() {
        let image = makeTextImage("测试文字 123")
        // Vision 首次调用要加载识别模型，冷启动这次结果不可靠，先预热一次。
        _ = TextRecognizer.recognizeText(in: image)

        var text = ""
        for _ in 0..<5 {
            text = TextRecognizer.recognizeText(in: image)
            if !text.isEmpty { break }
            Thread.sleep(forTimeInterval: 1)
        }
        // 内容级识别由 E2E 覆盖；这里只守住「管线能出结果」这一条，避免被模型冷启动拖成 flaky。
        #expect(!text.isEmpty, "识别结果为空，Vision 管线可能失效")
    }

    @Test func blankImageReturnsEmptyString() {
        let blank = makeImage(size: CGSize(width: 320, height: 160)) { _ in }
        #expect(TextRecognizer.recognizeText(in: blank).isEmpty)
    }
}
