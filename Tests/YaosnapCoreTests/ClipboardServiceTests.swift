import AppKit
import ImageIO
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

    @Test func copyFileWritesPNGAndPutsFileURLOnPasteboard() throws {
        let image = makeImage(width: 24, height: 12)
        #expect(ClipboardService.copyFile(image, scale: 2))

        let pasteboard = NSPasteboard.general
        #expect(pasteboard.types?.contains(.fileURL) == true)

        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL]
        let nsURL = try #require(objects?.first)
        let url = nsURL as URL
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(url.isFileURL)
        #expect(url.pathExtension == "png")

        let data = try Data(contentsOf: url)
        #expect(data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 24)
        #expect(decoded.height == 12)
    }
}
