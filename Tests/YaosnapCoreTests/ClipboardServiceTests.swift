import AppKit
import Testing
@testable import YaosnapCore

struct ClipboardServiceTests {
    @Test func copyThenReadBackImage() {
        let ctx = CGContext(
            data: nil, width: 20, height: 20,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let image = ctx.makeImage()!

        let before = NSPasteboard.general.changeCount
        #expect(ClipboardService.copyToPasteboard(image))
        #expect(NSPasteboard.general.changeCount > before)
        #expect(NSImage(pasteboard: NSPasteboard.general) != nil)
    }
}
