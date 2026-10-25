import AppKit
import Foundation
import ImageIO
import Testing
@testable import YaosnapCore

// 写系统粘贴板的用例与其他套件共用剪贴板，本套件内串行执行。
@Suite(.serialized)
struct CopyAsFileTests {
    private func makeImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    @Test func legacySettingsWithoutTriggerDefaultToShortcut() throws {
        let legacy: [String: Any] = [
            "snipHotkey": ["keyCode": 7, "modifiers": 0x1200],
            "pinHotkey": ["keyCode": 99, "modifiers": 0x0200],
            "togglePinsHotkey": ["keyCode": 45, "modifiers": 0x0900],
            "passthroughHotkey": ["keyCode": 17, "modifiers": 0x1200],
            "restoreCapacity": 2,
            "autoSelectOnCreation": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)

        #expect(decoded.copyAsFileTrigger == .shortcut)
    }

    @Test func triggerRoundTripsThroughJSON() throws {
        for trigger in CopyAsFileTrigger.allCases {
            let data = try JSONEncoder().encode(trigger)
            let decoded = try JSONDecoder().decode(CopyAsFileTrigger.self, from: data)
            #expect(decoded == trigger)
        }
    }

    @Test func triggerDecidesFileFromOptionKey() {
        #expect(!CopyAsFileTrigger.off.copiesAsFile(optionHeld: false))
        #expect(!CopyAsFileTrigger.off.copiesAsFile(optionHeld: true))
        #expect(!CopyAsFileTrigger.shortcut.copiesAsFile(optionHeld: false))
        #expect(CopyAsFileTrigger.shortcut.copiesAsFile(optionHeld: true))
        #expect(CopyAsFileTrigger.always.copiesAsFile(optionHeld: false))
        #expect(CopyAsFileTrigger.always.copiesAsFile(optionHeld: true))
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
