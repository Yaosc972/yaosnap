import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import YaosnapCore

struct PasteboardReaderTests {
    private func makeImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func temporaryFile(name: String, data: Data) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yaosnap-pin-\(UUID().uuidString)-\(name)")
        try? data.write(to: url)
        return url
    }

    // MARK: - 颜色解析

    @Test func parsesHexColor() throws {
        let color = try #require(PasteboardReader.parseColor("#FF8800"))
        #expect(abs(color.red - 1) < 0.001)
        #expect(abs(color.green - 136.0 / 255) < 0.001)
        #expect(color.blue == 0)
    }

    @Test func parsesRGB255() throws {
        let color = try #require(PasteboardReader.parseColor("255, 136, 0"))
        #expect(abs(color.red - 1) < 0.001)
        #expect(abs(color.green - 136.0 / 255) < 0.001)
        #expect(color.blue == 0)
    }

    @Test func parsesUnitRangeColor() throws {
        let color = try #require(PasteboardReader.parseColor("1, 0.533, 0"))
        #expect(abs(color.red - 1) < 0.001)
        #expect(abs(color.green - 0.533) < 0.001)
        #expect(color.blue == 0)
    }

    @Test func rejectsInvalidColor() {
        #expect(PasteboardReader.parseColor("256, 0, 0") == nil)
        #expect(PasteboardReader.parseColor("#GG0000") == nil)
        #expect(PasteboardReader.parseColor("#FF880") == nil)
        #expect(PasteboardReader.parseColor("hello") == nil)
        #expect(PasteboardReader.parseColor("1, 0.5") == nil)
    }

    // MARK: - 文件路径分支

    @Test func imageFileResolvesToImageContent() throws {
        let cgImage = makeImage(width: 12, height: 8)
        let data = try #require(ImageOutput.pngData(from: cgImage))
        let url = temporaryFile(name: "image.png", data: data)
        defer { try? FileManager.default.removeItem(at: url) }

        let content = try #require(PasteboardReader.resolve(text: nil, fileURL: url))
        #expect(content.kind == .filePath)
        guard case .image(let pasteImage) = content.visual else {
            Issue.record("图片文件应解析成图像")
            return
        }
        #expect(pasteImage.pointSize == CGSize(width: 12, height: 8))
    }

    @Test func textFileResolvesToPathText() throws {
        let url = temporaryFile(name: "note.txt", data: Data("hello".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        let content = try #require(PasteboardReader.resolve(text: nil, fileURL: url))
        #expect(content.kind == .filePath)
        guard case .text(let text) = content.visual else {
            Issue.record("普通文件应把路径当文本")
            return
        }
        #expect(text == url.path)
    }

    @Test func textPathToImageFileLoadsImage() throws {
        let cgImage = makeImage(width: 9, height: 7)
        let data = try #require(ImageOutput.pngData(from: cgImage))
        let url = temporaryFile(name: "path-image.png", data: data)
        defer { try? FileManager.default.removeItem(at: url) }

        let content = try #require(PasteboardReader.resolve(text: url.path))
        #expect(content.kind == .filePath)
        guard case .image(let pasteImage) = content.visual else {
            Issue.record("文本形式的图片路径应解析成图像")
            return
        }
        #expect(pasteImage.image.width == 9)
        #expect(pasteImage.image.height == 7)
    }

    @Test func plainTextStaysText() throws {
        let content = try #require(PasteboardReader.resolve(text: "第一行\n第二行"))
        #expect(content.kind == .text)
        guard case .text(let text) = content.visual else {
            Issue.record("普通文本应保持文本")
            return
        }
        #expect(text == "第一行\n第二行")
    }

    // MARK: - 渲染

    @Test func plainTextRendersNonEmptyImage() throws {
        let content = try #require(PasteboardReader.resolve(text: "贴图测试\nsecond line"))
        let rendered = try #require(PasteboardReader.render(content))

        #expect(rendered.image.width > 64)
        #expect(rendered.image.height > 64)
        #expect(rendered.pointSize.width >= PasteboardReader.textPadding * 2 + 40)
        #expect(rendered.pointSize.width <= PasteboardReader.textMaxWidth + PasteboardReader.textPadding * 2)
        #expect(rendered.pointSize.height > PasteboardReader.textPadding * 2)
        #expect(rendered.image.width == Int(rendered.pointSize.width * PasteboardReader.renderScale))
    }

    @Test func colorRendersSolidBlock() throws {
        let content = try #require(PasteboardReader.resolve(text: "#FF8800"))
        let rendered = try #require(PasteboardReader.render(content))

        #expect(rendered.pointSize == PasteboardReader.colorBlockSize)
        #expect(rendered.image.width == Int(PasteboardReader.colorBlockSize.width * PasteboardReader.renderScale))
        #expect(rendered.image.height == Int(PasteboardReader.colorBlockSize.height * PasteboardReader.renderScale))
    }

    @Test func imageContentPassesThrough() throws {
        let cgImage = makeImage(width: 30, height: 20)
        let content = PasteboardContent(
            kind: .image,
            visual: .image(PasteImage(image: cgImage, pointSize: CGSize(width: 30, height: 20)))
        )
        let rendered = try #require(PasteboardReader.render(content))
        #expect(rendered.image === cgImage)
        #expect(rendered.pointSize == CGSize(width: 30, height: 20))
    }
}
