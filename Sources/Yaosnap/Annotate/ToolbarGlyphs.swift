import AppKit
import YaosnapCore

/// 工具条图标。全部自绘，不用 SF Symbols。
///
/// 为什么自己画：
/// - `textformat` 在中文系统里会被系统本地化成「格式」两个汉字，图标行里突然出现文字块；
/// - `rectangle.roundedtop` 只圆上面两角，与「圆角矩形」对不上；
/// - `cloud.fog` / `squareshape.split.2x2` 与模糊、马赛克语义对不上；
/// - 系统符号在不同 macOS 版本上笔画粗细、光学尺寸都不一致，混在一起显脏。
///
/// 统一规格：18×18 画布、1.5pt 圆头描边、内容留 2.5pt 边距，
/// 除颜色/背景这类必须带色的按钮外都是 template 图，跟随 contentTintColor 着色。
enum ToolbarGlyph: CaseIterable {
    case select, rect, roundedRect, ellipse, line, arrow, polyline, brush, marker
    case mosaic, mosaicRect, blur, magnify, text, serial, eraser
    case undo, redo, copy, extractText, translate, scroll, barcode, save, pin, share, check, close

    /// 背景循环按钮的四档。这里只画状态，语义留在工具条里。
    enum BackgroundSwatch { case none, white, black, tint }

    static let side: CGFloat = 18

    /// 缓存键。枚举本身可 CaseIterable，用描述串足够稳定。
    var cacheKey: String {
        String(describing: self)
    }

    private static var imageCache: [String: NSImage] = [:]
    private static var stateCache: [String: NSImage] = [:]

    /// 启动后预热：把图标先画出来，用户第一次按热键不必等。
    static func preload() {
        for glyph in ToolbarGlyph.allCases { _ = image(glyph) }
        for pen in PenSize.allCases { _ = penWidth(pen) }
        for style in LineStyle.allCases { _ = lineStyle(style) }
        for heads in ArrowHeads.allCases { _ = arrowHeads(heads) }
        for swatch in [BackgroundSwatch.none, .white, .black, .tint] {
            _ = background(swatch, tint: .systemRed)
        }
        _ = colorDot(.systemRed)
    }

    /// 色块圆点：颜色按钮与贴图底栏共用。白圈让它在图标行里读作「色块」而不是普通圆点。
    static func colorDot(_ color: NSColor, ringed: Bool = true) -> NSImage {
        let diameter: CGFloat = 12
        let inset: CGFloat = 3
        let size = NSSize(width: diameter + inset * 2, height: diameter + inset * 2)
        let image = NSImage(size: size)
        image.lockFocus()
        let circle = NSBezierPath(ovalIn: NSRect(
            x: inset, y: inset, width: diameter, height: diameter
        ))
        color.setFill()
        circle.fill()
        if ringed {
            NSColor(white: 1, alpha: 0.9).setStroke()
            circle.lineWidth = 1.6
            circle.stroke()
        }
        image.unlockFocus()
        return image
    }

    static func image(_ glyph: ToolbarGlyph) -> NSImage {
        if let cached = imageCache[glyph.cacheKey] { return cached }
        let image = build(glyph)
        imageCache[glyph.cacheKey] = image
        return image
    }

    private static func build(_ glyph: ToolbarGlyph) -> NSImage {
        switch glyph {
        case .select:
            return make { p in
                p.fill(p.polygon([
                    CGPoint(x: 5.0, y: 15.6), CGPoint(x: 5.0, y: 3.4),
                    CGPoint(x: 7.9, y: 6.3), CGPoint(x: 9.9, y: 2.2),
                    CGPoint(x: 11.7, y: 3.1), CGPoint(x: 9.7, y: 7.2),
                    CGPoint(x: 13.4, y: 7.2),
                ]))
            }
        case .rect:
            return make { p in p.box(CGRect(x: 2.6, y: 4.4, width: 12.8, height: 9.2), radius: 1.6) }
        case .roundedRect:
            return make { p in p.box(CGRect(x: 2.6, y: 3.8, width: 12.8, height: 10.4), radius: 3.4) }
        case .ellipse:
            return make { p in p.ellipse(CGRect(x: 2.8, y: 3.8, width: 12.4, height: 10.4)) }
        case .line:
            return make { p in p.line([CGPoint(x: 3.8, y: 4.2), CGPoint(x: 14.2, y: 13.8)]) }
        case .arrow:
            return make { p in
                let tip = CGPoint(x: 14.2, y: 13.8)
                p.line([CGPoint(x: 3.8, y: 4.2), tip])
                p.line([CGPoint(x: 9.7, y: 12.9), tip, CGPoint(x: 13.3, y: 9.3)])
            }
        case .polyline:
            return make { p in
                p.line([
                    CGPoint(x: 3.4, y: 11.4), CGPoint(x: 6.9, y: 5.4),
                    CGPoint(x: 10.4, y: 11.0), CGPoint(x: 14.6, y: 6.4),
                ])
            }
        case .brush:
            // 起笔粗、收笔细的楔形笔触，和「记号笔」的等宽带明显区分。
            // 一道两头收尖、中间饱满的笔触：直线楔形会被读成刀刃，弯一点才像「画笔」。
            return make { p in
                let tail = CGPoint(x: 3.2, y: 14.2)
                let head = CGPoint(x: 14.0, y: 4.8)
                let stroke = NSBezierPath()
                stroke.move(to: tail)
                stroke.curve(
                    to: head,
                    controlPoint1: CGPoint(x: 9.8, y: 13.4),
                    controlPoint2: CGPoint(x: 13.6, y: 8.6)
                )
                stroke.curve(
                    to: tail,
                    controlPoint1: CGPoint(x: 11.4, y: 6.0),
                    controlPoint2: CGPoint(x: 5.2, y: 10.0)
                )
                stroke.close()
                p.fill(stroke)
            }
        case .marker:
            return make { p in
                let stroke = [CGPoint(x: 3.4, y: 9.0), CGPoint(x: 14.6, y: 9.0)]
                // 横向的一道：淡宽带是划痕，中间实心窄带是笔锋，与斜向的「画笔」区分开。
                p.strokeBand(stroke, width: 7.0, alpha: 0.26)
                p.strokeBand(stroke, width: 2.6)
            }
        case .mosaic:
            return make { p in
                let cell: CGFloat = 3.4
                let gap: CGFloat = 0.6
                let origin: CGFloat = 3.3
                for row in 0..<3 {
                    for column in 0..<3 {
                        guard (row + column) % 2 == 0 else { continue }
                        p.fillBox(
                            CGRect(
                                x: origin + CGFloat(column) * (cell + gap),
                                y: origin + CGFloat(row) * (cell + gap),
                                width: cell,
                                height: cell
                            ),
                            radius: 0.6
                        )
                    }
                }
            }
        case .mosaicRect:
            return make { p in
                p.box(
                    CGRect(x: 2.6, y: 4.4, width: 12.8, height: 9.2),
                    radius: 1.6, width: 1.3, alpha: 0.6
                )
                let cell: CGFloat = 3.0
                let gap: CGFloat = 0.5
                let width = 3 * cell + 2 * gap
                let height = 2 * cell + gap
                let x0 = (side - width) / 2
                let y0 = (side - height) / 2
                for (row, column) in [(0, 0), (0, 1), (0, 2), (1, 0), (1, 2)] {
                    p.fillBox(
                        CGRect(
                            x: x0 + CGFloat(column) * (cell + gap),
                            y: y0 + CGFloat(row) * (cell + gap),
                            width: cell,
                            height: cell
                        ),
                        radius: 0.5
                    )
                }
            }
        case .blur:
            // 逐渐变淡、变短的横条：既是「模糊」也是「渐变遮罩」的共识画法。
            return make { p in
                p.gradientBox(CGRect(x: 2.8, y: 4.6, width: 12.4, height: 8.8), radius: 1.8)
            }
        case .magnify:
            return make { p in
                p.circle(CGPoint(x: 7.6, y: 10.6), radius: 4.3)
                p.line([CGPoint(x: 10.8, y: 7.4), CGPoint(x: 14.4, y: 3.8)], width: 1.8)
                p.line([CGPoint(x: 5.8, y: 10.6), CGPoint(x: 9.4, y: 10.6)], width: 1.3)
                p.line([CGPoint(x: 7.6, y: 8.8), CGPoint(x: 7.6, y: 12.4)], width: 1.3)
            }
        case .text:
            return make { p in
                p.line([CGPoint(x: 4.6, y: 4.2), CGPoint(x: 9.0, y: 13.8), CGPoint(x: 13.4, y: 4.2)], width: 1.5)
                p.line([CGPoint(x: 6.5, y: 7.6), CGPoint(x: 11.5, y: 7.6)], width: 1.4)
            }
        case .serial:
            return make { p in
                p.circle(CGPoint(x: 9.0, y: 9.0), radius: 5.4, width: 1.5)
                p.line([CGPoint(x: 7.8, y: 11.2), CGPoint(x: 9.2, y: 12.0), CGPoint(x: 9.2, y: 6.0)], width: 1.4)
            }
        case .eraser:
            return make { p in
                // 橡皮是一块斜放的圆角块，中间一道分隔线表示「用掉的那头」。
                let block = NSBezierPath(
                    roundedRect: CGRect(x: -6.4, y: -3.4, width: 12.8, height: 6.8),
                    xRadius: 2.2, yRadius: 2.2
                )
                var spin = AffineTransform(translationByX: 9.0, byY: 9.0)
                spin.rotate(byDegrees: 45)
                block.transform(using: spin)
                p.stroke(block, width: 1.5, alpha: 1, dash: [])
                p.line([CGPoint(x: 5.6, y: 6.0), CGPoint(x: 12.0, y: 12.0)], width: 1.3, alpha: 0.75)
            }
        case .undo:
            return make { p in
                p.arc(center: CGPoint(x: 10.2, y: 8.4), radius: 4.6, from: 180, to: 0)
                p.line([CGPoint(x: 5.6, y: 8.4), CGPoint(x: 5.6, y: 4.0)], width: 1.5)
                p.line([CGPoint(x: 3.4, y: 6.0), CGPoint(x: 5.6, y: 4.0), CGPoint(x: 7.8, y: 6.0)], width: 1.5)
            }
        case .redo:
            return make { p in
                p.arc(center: CGPoint(x: 7.8, y: 8.4), radius: 4.6, from: 0, to: 180)
                p.line([CGPoint(x: 12.4, y: 8.4), CGPoint(x: 12.4, y: 4.0)], width: 1.5)
                p.line([CGPoint(x: 10.2, y: 6.0), CGPoint(x: 12.4, y: 4.0), CGPoint(x: 14.6, y: 6.0)], width: 1.5)
            }
        case .copy:
            return make { p in
                p.box(CGRect(x: 3.0, y: 8.2, width: 7.4, height: 6.8), radius: 1.6, alpha: 0.5)
                p.box(CGRect(x: 7.6, y: 3.0, width: 7.4, height: 6.8), radius: 1.6)
            }
        case .extractText:
            return make { p in
                let near: CGFloat = 3.0
                let far: CGFloat = 15.0
                let arm: CGFloat = 3.2
                p.line([CGPoint(x: near, y: far - arm), CGPoint(x: near, y: far), CGPoint(x: near + arm, y: far)], width: 1.4)
                p.line([CGPoint(x: far - arm, y: far), CGPoint(x: far, y: far), CGPoint(x: far, y: far - arm)], width: 1.4)
                p.line([CGPoint(x: near, y: near + arm), CGPoint(x: near, y: near), CGPoint(x: near + arm, y: near)], width: 1.4)
                p.line([CGPoint(x: far - arm, y: near), CGPoint(x: far, y: near), CGPoint(x: far, y: near + arm)], width: 1.4)
                p.line([CGPoint(x: 6.2, y: 11.0), CGPoint(x: 11.8, y: 11.0)], width: 1.4, alpha: 0.9)
                p.line([CGPoint(x: 6.2, y: 8.8), CGPoint(x: 11.8, y: 8.8)], width: 1.4, alpha: 0.65)
                p.line([CGPoint(x: 6.2, y: 6.6), CGPoint(x: 9.8, y: 6.6)], width: 1.4, alpha: 0.4)
            }
        case .translate:
            return make { p in
                p.circle(CGPoint(x: 9.0, y: 9.0), radius: 5.6, width: 1.4)
                p.ellipse(CGRect(x: 6.4, y: 3.4, width: 5.2, height: 11.2), width: 1.4, alpha: 0.75)
                p.line([CGPoint(x: 3.5, y: 9.0), CGPoint(x: 14.5, y: 9.0)], width: 1.4, alpha: 0.75)
            }
        case .scroll:
            return make { p in
                p.box(CGRect(x: 4.4, y: 2.6, width: 9.2, height: 12.8), radius: 1.6, alpha: 0.4)
                p.line([CGPoint(x: 6.8, y: 10.2), CGPoint(x: 9.0, y: 8.0), CGPoint(x: 11.2, y: 10.2)], width: 1.5)
                p.line([CGPoint(x: 6.8, y: 6.4), CGPoint(x: 9.0, y: 4.2), CGPoint(x: 11.2, y: 6.4)], width: 1.5)
            }
        case .barcode:
            return make { p in
                func finder(_ rect: CGRect) {
                    p.box(rect, radius: 0.8, width: 1.4)
                    p.fillBox(rect.insetBy(dx: 1.3, dy: 1.3), radius: 0.4)
                }
                finder(CGRect(x: 2.8, y: 10.8, width: 4.4, height: 4.4))
                finder(CGRect(x: 10.8, y: 10.8, width: 4.4, height: 4.4))
                finder(CGRect(x: 2.8, y: 2.8, width: 4.4, height: 4.4))
                p.fillBox(CGRect(x: 11.4, y: 3.4, width: 3.2, height: 3.2), radius: 0.5)
            }
        case .save:
            return make { p in
                p.line([CGPoint(x: 3.4, y: 8.4), CGPoint(x: 3.4, y: 3.4), CGPoint(x: 14.6, y: 3.4), CGPoint(x: 14.6, y: 8.4)], width: 1.4)
                p.line([CGPoint(x: 9.0, y: 14.4), CGPoint(x: 9.0, y: 7.0)], width: 1.5)
                p.line([CGPoint(x: 6.9, y: 9.1), CGPoint(x: 9.0, y: 7.0), CGPoint(x: 11.1, y: 9.1)], width: 1.5)
            }
        case .pin:
            return make { p in
                p.fillEllipse(CGRect(x: 4.4, y: 9.4, width: 5.0, height: 5.0))
                p.strokeBand([CGPoint(x: 7.6, y: 10.6), CGPoint(x: 10.2, y: 8.0)], width: 4.2)
                p.line([CGPoint(x: 10.2, y: 8.0), CGPoint(x: 14.2, y: 4.0)], width: 1.5)
            }
        case .share:
            return make { p in
                p.line([CGPoint(x: 3.4, y: 8.0), CGPoint(x: 3.4, y: 3.4), CGPoint(x: 14.6, y: 3.4), CGPoint(x: 14.6, y: 8.0)], width: 1.4)
                p.line([CGPoint(x: 9.0, y: 7.4), CGPoint(x: 9.0, y: 14.6)], width: 1.5)
                p.line([CGPoint(x: 6.9, y: 12.5), CGPoint(x: 9.0, y: 14.6), CGPoint(x: 11.1, y: 12.5)], width: 1.5)
            }
        case .check:
            return make { p in
                p.line([
                    CGPoint(x: 3.6, y: 9.4), CGPoint(x: 7.4, y: 5.4), CGPoint(x: 14.4, y: 13.0),
                ], width: 1.8)
            }
        case .close:
            return make { p in
                p.line([CGPoint(x: 4.6, y: 13.4), CGPoint(x: 13.4, y: 4.6)], width: 1.6)
                p.line([CGPoint(x: 4.6, y: 4.6), CGPoint(x: 13.4, y: 13.4)], width: 1.6)
            }
        }
    }

    /// 笔宽：三根由细到粗的横线，当前档位那一根点纯白，其余压暗。
    static func penWidth(_ pen: PenSize) -> NSImage {
        if let cached = stateCache["pen-\(pen.rawValue)"] { return cached }
        let image = buildPenWidth(pen)
        stateCache["pen-\(pen.rawValue)"] = image
        return image
    }

    private static func buildPenWidth(_ pen: PenSize) -> NSImage {
        let widths: [CGFloat] = [1.4, 2.6, 4.0]
        let index: Int
        switch pen {
        case .p1, .p2: index = 0
        case .p3, .p4: index = 1
        case .p5: index = 2
        }
        return make { p in
            for (bar, lineWidth) in widths.enumerated() {
                let y = 12.6 - CGFloat(bar) * 3.6
                p.line(
                    [CGPoint(x: 3.6, y: y), CGPoint(x: 14.4, y: y)],
                    width: lineWidth,
                    alpha: bar == index ? 1 : 0.45
                )
            }
        }
    }

    /// 线型：一段 S 形曲线样本，用与渲染一致的 dash 参数示意。
    /// 横线会和「笔宽」的三根横线撞车，曲线和「直线」工具也不会混淆。
    static func lineStyle(_ style: LineStyle) -> NSImage {
        if let cached = stateCache["line-\(style.rawValue)"] { return cached }
        let image = buildLineStyle(style)
        stateCache["line-\(style.rawValue)"] = image
        return image
    }

    private static func buildLineStyle(_ style: LineStyle) -> NSImage {
        make { p in
            let width: CGFloat = 1.8
            let dash = style.dashPattern(lineWidth: width) ?? []
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 3.2, y: 6.4))
            path.curve(
                to: CGPoint(x: 14.8, y: 11.6),
                controlPoint1: CGPoint(x: 7.4, y: 13.6),
                controlPoint2: CGPoint(x: 10.6, y: 4.4)
            )
            p.stroke(path, width: width, alpha: 1, dash: dash)
        }
    }

    /// 背景：圆角方块表示填充档位。四档里只有「无」能当 template 用。
    static func background(_ swatch: BackgroundSwatch, tint: NSColor) -> NSImage {
        let rect = CGRect(x: 3.2, y: 3.2, width: 11.6, height: 11.6)
        let hasFill = swatch != .none
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        do {
            let path = NSBezierPath(roundedRect: rect, xRadius: 2.8, yRadius: 2.8)
            if hasFill {
                let fill: NSColor
                switch swatch {
                case .none: fill = .clear
                case .white: fill = NSColor(white: 1, alpha: 0.95)
                case .black: fill = NSColor(white: 0.05, alpha: 1)
                case .tint: fill = tint.withAlphaComponent(0.55)
                }
                fill.setFill()
                path.fill()
            }
            (hasFill ? NSColor(white: 1, alpha: 0.9) : NSColor(white: 1, alpha: 0.7)).setStroke()
            path.lineWidth = 1.4
            path.stroke()
        }
        image.unlockFocus()
        image.isTemplate = !hasFill
        return image
    }

    /// 箭头两端带头方式。
    static func arrowHeads(_ heads: ArrowHeads) -> NSImage {
        if let cached = stateCache["heads-\(heads.rawValue)"] { return cached }
        let image = buildArrowHeads(heads)
        stateCache["heads-\(heads.rawValue)"] = image
        return image
    }

    private static func buildArrowHeads(_ heads: ArrowHeads) -> NSImage {
        make { p in
            let left = CGPoint(x: 3.4, y: 9.0)
            let right = CGPoint(x: 14.6, y: 9.0)
            p.line([left, right], width: 1.5)
            if heads.hasEnd {
                p.line([CGPoint(x: 11.9, y: 11.2), right, CGPoint(x: 11.9, y: 6.8)], width: 1.4)
            }
            if heads.hasStart {
                p.line([CGPoint(x: 6.1, y: 11.2), left, CGPoint(x: 6.1, y: 6.8)], width: 1.4)
            }
        }
    }
}

// MARK: - 画法

private extension ToolbarGlyph {
    struct Painter {
        func polygon(_ points: [CGPoint]) -> NSBezierPath {
            let path = NSBezierPath()
            for (index, point) in points.enumerated() {
                if index == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.close()
            return path
        }

        func fill(_ path: NSBezierPath, alpha: CGFloat = 1) {
            NSColor(white: 1, alpha: alpha).setFill()
            path.fill()
        }

        func fillBox(_ rect: CGRect, radius: CGFloat, alpha: CGFloat = 1) {
            fill(NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius), alpha: alpha)
        }

        func fillEllipse(_ rect: CGRect, alpha: CGFloat = 1) {
            fill(NSBezierPath(ovalIn: rect), alpha: alpha)
        }

        func line(
            _ points: [CGPoint],
            width: CGFloat = 1.5,
            alpha: CGFloat = 1,
            closed: Bool = false,
            dash: [CGFloat] = []
        ) {
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: first)
            for point in points.dropFirst() { path.line(to: point) }
            if closed { path.close() }
            stroke(path, width: width, alpha: alpha, dash: dash)
        }

        /// 等宽带，两端平头。记号笔这种「一整条」的笔画用它，圆头会把两端画圆显得软。
        func strokeBand(_ points: [CGPoint], width: CGFloat, alpha: CGFloat = 1) {
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: first)
            for point in points.dropFirst() { path.line(to: point) }
            path.lineWidth = width
            path.lineCapStyle = .butt
            path.lineJoinStyle = .round
            NSColor(white: 1, alpha: alpha).setStroke()
            path.stroke()
        }

        func stroke(_ path: NSBezierPath, width: CGFloat, alpha: CGFloat, dash: [CGFloat]) {
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            if !dash.isEmpty {
                path.setLineDash(dash, count: dash.count, phase: 0)
            }
            NSColor(white: 1, alpha: alpha).setStroke()
            path.stroke()
        }

        func box(
            _ rect: CGRect,
            radius: CGFloat,
            width: CGFloat = 1.5,
            alpha: CGFloat = 1,
            dash: [CGFloat] = []
        ) {
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            stroke(path, width: width, alpha: alpha, dash: dash)
        }

        func circle(_ center: CGPoint, radius: CGFloat, width: CGFloat = 1.5, alpha: CGFloat = 1) {
            let rect = CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            )
            stroke(NSBezierPath(ovalIn: rect), width: width, alpha: alpha, dash: [])
        }

        func ellipse(_ rect: CGRect, width: CGFloat = 1.5, alpha: CGFloat = 1) {
            stroke(NSBezierPath(ovalIn: rect), width: width, alpha: alpha, dash: [])
        }

        /// 由实到虚的渐隐方块：模糊/羽化区域的直观画法。
        func gradientBox(_ rect: CGRect, radius: CGFloat) {
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSGradient(colors: [
                NSColor(white: 1, alpha: 0.92),
                NSColor(white: 1, alpha: 0.30),
                NSColor(white: 1, alpha: 0.04),
            ])?.draw(in: path, angle: -35)
            stroke(path, width: 1.2, alpha: 0.5, dash: [])
        }

        /// 角度按 AppKit 约定：0° 在右，逆时针为正。
        func arc(center: CGPoint, radius: CGFloat, from: CGFloat, to: CGFloat, width: CGFloat = 1.5) {
            let path = NSBezierPath()
            path.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: from,
                endAngle: to,
                clockwise: true
            )
            stroke(path, width: width, alpha: 1, dash: [])
        }
    }

    /// 直接画进位图。三个理由都不用 NSImage.lockFocus / drawingHandler：
    /// - drawingHandler 把绘制推迟到首次上屏，33 个图标一起推迟，第一次呼出截图肉眼可见地慢；
    /// - lockFocus 走 CGLayer，创建与首次绘制都明显更贵；
    /// - 位图表示可以缓存下来反复用，工具条每次重建不必重画。
    static func make(_ build: @escaping (Painter) -> Void) -> NSImage {
        let scale: CGFloat = 2
        let pixels = Int(side * scale)
        let image = NSImage(size: NSSize(width: side, height: side))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return image }
        // 位图是 2x 像素、18pt 逻辑尺寸：NSGraphicsContext 已经按 rep.size 建好
        // 点→像素的变换，这里再手动 scale 一次会变成 4x，图形只剩左上角一块。
        rep.size = NSSize(width: side, height: side)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        build(Painter())
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }


}

/// 工具条上的形状族。族与族之间加分隔线，15 个图标才不会连成一片。
enum ToolFamily: Int {
    case shape
    case line
    case freehand
    case redact
    case utility
}

extension ShapeKind {
    var family: ToolFamily {
        switch self {
        case .rect, .roundedRect, .ellipse: return .shape
        case .line, .arrow, .polyline: return .line
        case .brush, .marker: return .freehand
        case .mosaic, .mosaicRect, .blur: return .redact
        case .magnify, .text, .serial, .eraser: return .utility
        }
    }
}

extension ToolbarGlyph {
    /// 形状工具一一对应。
    static func shape(_ kind: ShapeKind) -> ToolbarGlyph {
        switch kind {
        case .rect: return .rect
        case .roundedRect: return .roundedRect
        case .ellipse: return .ellipse
        case .line: return .line
        case .arrow: return .arrow
        case .polyline: return .polyline
        case .brush: return .brush
        case .marker: return .marker
        case .mosaic: return .mosaic
        case .mosaicRect: return .mosaicRect
        case .blur: return .blur
        case .magnify: return .magnify
        case .text: return .text
        case .serial: return .serial
        case .eraser: return .eraser
        }
    }
}