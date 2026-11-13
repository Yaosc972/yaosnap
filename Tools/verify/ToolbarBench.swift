import AppKit
import YaosnapCore

@main
struct Bench {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)

            let all: [ToolbarGlyph] = [.select, .rect, .roundedRect, .ellipse, .line, .arrow,
                .polyline, .brush, .marker, .mosaic, .mosaicRect, .blur, .magnify, .text,
                .serial, .eraser, .undo, .redo, .copy, .extractText, .translate, .scroll,
                .barcode, .save, .pin, .share, .check, .close]
            var t0 = CFAbsoluteTimeGetCurrent()
            for glyph in all { _ = ToolbarGlyph.image(glyph) }
            print(String(format: "33 glyphs cold: %.1f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
            t0 = CFAbsoluteTimeGetCurrent()
            for glyph in all { _ = ToolbarGlyph.image(glyph) }
            print(String(format: "33 glyphs warm: %.1f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))

            t0 = CFAbsoluteTimeGetCurrent()
            let bar = AnnotateToolbar(
                initialKind: .rect,
                initialStyle: ShapeCatalog.entry(for: .rect)?.defaultStyle
                    ?? Style(color: RGBAColor.palette[0], pen: .p3)
            )
            print(String(format: "toolbar init: %.1f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
            _ = bar.frame.size

            // 首次上屏：把整条工具条画进位图
            t0 = CFAbsoluteTimeGetCurrent()
            if let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
                bar.cacheDisplay(in: bar.bounds, to: rep)
            }
            print(String(format: "first display: %.1f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        }
    }
}
