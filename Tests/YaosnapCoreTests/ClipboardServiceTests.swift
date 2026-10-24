import AppKit
import Testing
@testable import YaosnapCore

// 多个用例共写系统粘贴板，串行执行避免互相清空。
@Suite(.serialized)
struct ClipboardServiceTests {
    private func makeImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    @Test func copyThenReadBackImage() {
        let image = makeImage(width: 20, height: 20)

        let before = NSPasteboard.general.changeCount
        #expect(ClipboardService.copyToPasteboard(image, scale: 1))
        #expect(NSPasteboard.general.changeCount > before)
        #expect(NSImage(pasteboard: NSPasteboard.general) != nil)
    }

    @Test func pointSizeDividesRetinaPixels() {
        let image = makeImage(width: 40, height: 20)
        #expect(
            ClipboardService.pointSize(for: image, scale: 2)
                == NSSize(width: 20, height: 10)
        )
    }

    @Test func pointSizeTreatsNonPositiveScaleAsOne() {
        let image = makeImage(width: 40, height: 20)
        #expect(
            ClipboardService.pointSize(for: image, scale: 0)
                == NSSize(width: 40, height: 20)
        )
    }

    @Test func pastedImageCarriesPointSize() {
        let image = makeImage(width: 40, height: 20)
        #expect(ClipboardService.copyToPasteboard(image, scale: 2))
        let pasted = NSImage(pasteboard: NSPasteboard.general)
        #expect(pasted?.size == NSSize(width: 20, height: 10))
    }
}
