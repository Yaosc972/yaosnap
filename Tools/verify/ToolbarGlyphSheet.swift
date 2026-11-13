import AppKit
import YaosnapCore

/// 工具条图标的视觉稿：把所有自绘图标按工具条的实际尺寸渲染成一张对比图，
/// 供人眼检查笔画粗细、光学尺寸、可辨识度。不做断言，只出图。
@MainActor
final class GlyphSheet {
    private let cell = NSSize(width: 56, height: 74)

    private let toolItems: [(ToolbarGlyph, String)] = [
        (.select, "select"), (.rect, "rect"), (.roundedRect, "round"), (.ellipse, "circle"),
        (.line, "line"), (.arrow, "arrow"), (.polyline, "polyline"), (.brush, "brush"),
        (.marker, "marker"), (.mosaic, "mosaic"), (.mosaicRect, "mosaiRect"), (.blur, "blur"),
        (.magnify, "magnify"), (.text, "text"), (.serial, "serial"), (.eraser, "eraser"),
        (.undo, "undo"), (.redo, "redo"), (.copy, "copy"), (.extractText, "ocr"),
        (.translate, "translate"), (.scroll, "scroll"), (.barcode, "qr"), (.save, "save"),
        (.pin, "pin"), (.share, "share"), (.close, "close"),
    ]

    func render() -> NSImage {
        let columns = 7
        let rows = (toolItems.count + columns - 1) / columns
        // 下面多两行放状态图标与真实工具条。
        let size = NSSize(
            width: CGFloat(columns) * cell.width + 40,
            height: CGFloat(rows) * cell.height + 260
        )
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(white: 0.12, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()

        for (index, item) in toolItems.enumerated() {
            let column = index % columns
            let row = index / columns
            let origin = CGPoint(
                x: 20 + CGFloat(column) * cell.width,
                y: size.height - CGFloat(row + 1) * cell.height - 20
            )
            draw(glyph: item.0, label: item.1, at: origin)
        }

        // 状态图标：笔宽 / 线型 / 背景 / 箭头。
        var stateOrigin = CGPoint(x: 20, y: size.height - CGFloat(rows) * cell.height - 100)
        let states: [(NSImage, String)] = [
            (ToolbarGlyph.penWidth(.p1), "pen1"),
            (ToolbarGlyph.penWidth(.p3), "pen3"),
            (ToolbarGlyph.penWidth(.p5), "pen5"),
            (ToolbarGlyph.lineStyle(.solid), "solid"),
            (ToolbarGlyph.lineStyle(.dashed), "dashed"),
            (ToolbarGlyph.lineStyle(.dotted), "dotted"),
            (ToolbarGlyph.arrowHeads(.end), "end"),
            (ToolbarGlyph.arrowHeads(.both), "both"),
            (ToolbarGlyph.arrowHeads(.start), "start"),
            (ToolbarGlyph.background(.none, tint: .white), "bg-"),
            (ToolbarGlyph.background(.white, tint: .white), "bg-w"),
            (ToolbarGlyph.background(.black, tint: .white), "bg-b"),
            (ToolbarGlyph.background(.tint, tint: .systemRed), "bg-t"),
        ]
        for (index, item) in states.enumerated() {
            let origin = CGPoint(
                x: stateOrigin.x + CGFloat(index % 7) * cell.width,
                y: stateOrigin.y - CGFloat(index / 7) * cell.height
            )
            draw(image: item.0, label: item.1, at: origin)
        }

        // 真实工具条：与产品里同一份 AnnotateToolbar，缩放到屏幕 1x 宽度。
        let bar = AnnotateToolbar(
            initialKind: .rect,
            initialStyle: ShapeCatalog.entry(for: .rect)?.defaultStyle
                ?? Style(color: RGBAColor.palette[0], pen: .p3)
        )
        let barSize = bar.frame.size
        let scale = min(1, (size.width - 40) / max(1, barSize.width))
        let barRect = NSRect(
            x: 20,
            y: 24,
            width: barSize.width * scale,
            height: barSize.height * scale
        )
        if let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
            bar.cacheDisplay(in: bar.bounds, to: rep)
            rep.draw(in: barRect)
        }
        let caption = "toolbar \(Int(barSize.width))x\(Int(barSize.height)) pt" as NSString
        caption.draw(
            at: CGPoint(x: 20, y: 6),
            withAttributes: [
                .foregroundColor: NSColor(white: 1, alpha: 0.55),
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            ]
        )

        image.unlockFocus()
        return image
    }

    private func draw(glyph: ToolbarGlyph, label: String, at origin: CGPoint) {
        draw(image: ToolbarGlyph.image(glyph), label: label, at: origin)
    }

    private func draw(image glyph: NSImage, label: String, at origin: CGPoint) {
        // 30×30 的按钮底，和工具条上的实际尺寸一致。
        let buttonRect = NSRect(
            x: origin.x + (cell.width - 30) / 2,
            y: origin.y + 26,
            width: 30,
            height: 30
        )
        NSColor(white: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: buttonRect, xRadius: 6, yRadius: 6).fill()

        let glyphSize = glyph.size
        let glyphRect = NSRect(
            x: buttonRect.midX - glyphSize.width / 2,
            y: buttonRect.midY - glyphSize.height / 2,
            width: glyphSize.width,
            height: glyphSize.height
        )
        // 自绘图标本来就是白色笔画，直接画即可；isTemplate 只影响 NSButton 的着色。
        glyph.draw(in: glyphRect)

        let text = label as NSString
        text.draw(
            at: CGPoint(x: origin.x, y: origin.y + 8),
            withAttributes: [
                .foregroundColor: NSColor(white: 1, alpha: 0.7),
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            ]
        )
    }

    /// 单独导出一张 1:1 的工具条图，便于按像素检查间距与对齐。
    func writeToolbar(to path: String) {
        let bar = AnnotateToolbar(
            initialKind: .rect,
            initialStyle: ShapeCatalog.entry(for: .rect)?.defaultStyle
                ?? Style(color: RGBAColor.palette[0], pen: .p3)
        )
        bar.updateTranslationTarget(.auto)
        let size = bar.frame.size
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(white: 0.35, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        if let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
            bar.cacheDisplay(in: bar.bounds, to: rep)
            rep.draw(in: NSRect(origin: .zero, size: size))
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("TOOLBAR \(path) \(Int(size.width))x\(Int(size.height))")
    }

    /// 贴图标注底栏：同一套图标，单独出图核对。
    func writePinBar(to path: String) {
        let bar = PinAnnotateBar()
        bar.updateState(tool: .rect, color: RGBAColor.palette[0], pen: .p3, canUndo: true)
        bar.layoutSubtreeIfNeeded()
        let size = bar.intrinsicContentSize
        bar.frame = NSRect(origin: .zero, size: size)
        bar.layoutSubtreeIfNeeded()
        let image = NSImage(size: size)
        image.lockFocus()
        if let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
            bar.cacheDisplay(in: bar.bounds, to: rep)
            rep.draw(in: NSRect(origin: .zero, size: size))
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("PINBAR \(path) \(Int(size.width))x\(Int(size.height))")
    }

    func write(to path: String) {
        let image = render()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("SHEET \(path)")
    }
}

@main
struct ToolbarGlyphSheetMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let sheet = GlyphSheet()
            sheet.write(to: "/tmp/yaosnap-verify/evidence/toolbar-glyphs.png")
            sheet.writeToolbar(to: "/tmp/yaosnap-verify/evidence/toolbar.png")
            sheet.writePinBar(to: "/tmp/yaosnap-verify/evidence/pin-bar.png")
        }
    }
}