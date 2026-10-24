import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import YaosnapCore

/// P2 标注第一批验收 harness。驱动真实 SnipController / OverlayView，
/// 验证画矩形 → 复制 → 剪贴板与参考渲染一致、方向正确、状态机行为正确。
@MainActor
final class AnnotateObserverWiring {
    let controller = SnipController()

    init() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(escape(_:)), name: .snipEscapePressed, object: nil)
        center.addObserver(self, selector: #selector(committed(_:)), name: .snipCommitted, object: nil)
        center.addObserver(self, selector: #selector(copyRequested(_:)), name: .snipCopyRequested, object: nil)
        center.addObserver(self, selector: #selector(saveRequested(_:)), name: .snipSaveRequested, object: nil)
    }

    @objc private func escape(_ notification: Notification) { controller.cancel() }
    @objc private func committed(_ notification: Notification) { controller.commitSelection(notification) }
    @objc private func copyRequested(_ notification: Notification) { controller.copyPendingImage(notification) }
    @objc private func saveRequested(_ notification: Notification) { controller.savePendingImage(notification) }
}

@MainActor
final class AnnotateHarness {
    private let wiring = AnnotateObserverWiring()
    private var controller: SnipController { wiring.controller }
    private let evidenceDir: URL
    private var passes = 0
    private var failures = 0

    init(evidenceDir: URL) {
        self.evidenceDir = evidenceDir
    }

    // MARK: - 基础设施

    private func pass(_ id: String, _ detail: String) {
        passes += 1
        print("PASS \(id) \(detail)")
    }

    private func fail(_ id: String, _ detail: String) {
        failures += 1
        print("FAIL \(id) \(detail)")
    }

    private func info(_ id: String, _ detail: String) {
        print("INFO \(id) \(detail)")
    }

    private func pump(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private var visibleOverlayWindows: [SnipOverlayWindow] {
        NSApp.windows.compactMap { $0 as? SnipOverlayWindow }.filter(\.isVisible)
    }

    private func beginSession(_ id: String) -> (SnipOverlayWindow, OverlayView)? {
        controller.start()
        pump(0.4)
        guard let window = visibleOverlayWindows.first,
              let view = window.contentView as? OverlayView else {
            fail(id, "start 后没有可见覆盖窗口")
            return nil
        }
        return (window, view)
    }

    private func endSession() {
        controller.cancel()
        NSPasteboard.general.clearContents()
        pump(0.15)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        in window: NSWindow,
        clickCount: Int = 1
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: type == .leftMouseUp ? 0 : 1
        )
    }

    /// 发送一次完整按压序列。
    private func press(_ view: OverlayView, window: NSWindow, path: [CGPoint]) {
        guard let first = path.first else { return }
        if let down = mouseEvent(.leftMouseDown, at: first, in: window) {
            view.mouseDown(with: down)
        }
        for point in path.dropFirst() {
            if let dragged = mouseEvent(.leftMouseDragged, at: point, in: window) {
                view.mouseDragged(with: dragged)
            }
        }
        let last = path.last ?? first
        if let up = mouseEvent(.leftMouseUp, at: last, in: window) {
            view.mouseUp(with: up)
        }
        pump(0.15)
    }

    private func drag(_ view: OverlayView, window: NSWindow, from: CGPoint, to: CGPoint) {
        press(view, window: window, path: [from, to])
        pump(0.2)
    }

    private func keyDown(
        _ keyCode: UInt16,
        characters: String,
        in window: NSWindow,
        view: OverlayView,
        modifierFlags: NSEvent.ModifierFlags = []
    ) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fail("KEY", "无法构造键盘事件 keyCode=\(keyCode)")
            return
        }
        view.keyDown(with: event)
        pump(0.25)
    }

    /// 直接驱动文字编辑器。编辑期间它是 first responder，按键不会经过 OverlayView.keyDown。
    private func sendKey(
        _ keyCode: UInt16,
        characters: String,
        to editor: NSTextView,
        in window: NSWindow,
        modifierFlags: NSEvent.ModifierFlags = []
    ) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fail("TEXT-KEY", "无法构造键盘事件 keyCode=\(keyCode)")
            return
        }
        editor.keyDown(with: event)
        pump(0.2)
    }

    /// 工具条按钮点击入口。找不到按钮直接判失败。
    @discardableResult
    private func tapTool(_ view: OverlayView, _ kind: ShapeKind, id: String) -> Bool {
        guard let bar = view.subviews.compactMap({ $0 as? AnnotateToolbar }).first,
              let button = bar.toolButtons[kind] else {
            fail(id, "工具条上找不到 \(kind.rawValue) 按钮")
            return false
        }
        button.performClick(nil)
        pump(0.1)
        return true
    }

    /// 打开颜色弹层并点选第 index 个色块。
    private func pickColor(_ view: OverlayView, _ index: Int, id: String) -> Bool {
        guard let bar = view.subviews.compactMap({ $0 as? AnnotateToolbar }).first else {
            fail(id, "找不到工具条")
            return false
        }
        bar.colorButton.performClick(nil)
        pump(0.2)
        guard let palette = bar.colorPopover?.contentViewController?.view as? ColorPaletteView,
              index < palette.swatches.count else {
            fail(id, "颜色弹层未弹出或色块不足")
            return false
        }
        palette.swatches[index].performClick(nil)
        pump(0.2)
        return true
    }

    /// 打开笔尖弹层并点选第 index 档（0 起）。
    private func pickPen(_ view: OverlayView, _ index: Int, id: String) -> Bool {
        guard let bar = view.subviews.compactMap({ $0 as? AnnotateToolbar }).first else {
            fail(id, "找不到工具条")
            return false
        }
        bar.penButton.performClick(nil)
        pump(0.2)
        guard let sizes = bar.penPopover?.contentViewController?.view as? PenSizeView,
              index < sizes.swatches.count else {
            fail(id, "笔尖弹层未弹出")
            return false
        }
        sizes.swatches[index].performClick(nil)
        pump(0.2)
        return true
    }

    private func pasteboardImage() -> CGImage? {
        guard let tiff = NSPasteboard.general.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.cgImage
    }

    private func srgbBytes(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = context.data else { return nil }
        return Array(UnsafeBufferPointer(
            start: base.assumingMemoryBound(to: UInt8.self),
            count: width * height * 4
        ))
    }

    private func pixelColor(_ bytes: [UInt8], x: Int, y: Int, width: Int) -> (r: Int, g: Int, b: Int) {
        let offset = (y * width + x) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    private func capture(_ name: String) {
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else { return }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) {
            try? (data as Data).write(to: evidenceDir.appendingPathComponent(name))
        }
    }

    // MARK: - 用例

    /// 画矩形 → Enter 复制，剪贴板与参考渲染逐像素一致，方向与颜色独立验证。
    private func runDrawAndCopy() {
        guard let (window, view) = beginSession("ANNOTATE") else { return }
        let selectionOrigin = CGPoint(x: 200, y: 200)
        let selectionEnd = CGPoint(x: 600, y: 500)
        drag(view, window: window, from: selectionOrigin, to: selectionEnd)
        let selection = view.selectionRect
        guard !selection.isEmpty, verifyIntegral(selection) else {
            fail("ANNOTATE-SELECT", "selectionRect=\(selection) 不是整点非空矩形")
            endSession()
            return
        }
        pass("ANNOTATE-SELECT", "选区已确定并取整 \(selection)")

        // 选区内画矩形：画布目标 (50,180)-(250,250)
        let canvasStart = CGPoint(x: 50, y: 180)
        let canvasEnd = CGPoint(x: 250, y: 250)
        let viewStart = CGPoint(x: selection.minX + canvasStart.x, y: selection.minY + canvasStart.y)
        let viewMid = CGPoint(x: selection.minX + 150, y: selection.minY + 220)
        let viewEnd = CGPoint(x: selection.minX + canvasEnd.x, y: selection.minY + canvasEnd.y)
        press(view, window: window, path: [viewStart, viewMid, viewEnd])

        guard view.annotations.count == 1,
              case .rect(let rect) = view.annotations[0].shape,
              rect == CGRect(x: 50, y: 180, width: 200, height: 70) else {
            fail("ANNOTATE-DRAW", "annotations=\(view.annotations) 期望 1 条矩形 (50,180 200x70)")
            capture("p2-annotate-draw-fail.png")
            endSession()
            return
        }
        pass("ANNOTATE-DRAW", "画布坐标矩形 \(rect) 已入列")

        let annotations = view.annotations
        let scale = view.shot.scale
        let imageRect = RectMath.imageRect(
            fromViewRect: selection, viewHeight: view.bounds.height, scale: scale
        )
        capture("p2-annotate-preview.png")

        NSPasteboard.general.clearContents()
        keyDown(36, characters: "\r", in: window, view: view)

        guard let actual = pasteboardImage() else {
            fail("ANNOTATE-COPY", "剪贴板没有图像")
            endSession()
            return
        }
        let expectedPxW = Int(imageRect.width)
        let expectedPxH = Int(imageRect.height)
        guard actual.width == expectedPxW, actual.height == expectedPxH else {
            fail("ANNOTATE-COPY", "剪贴板 \(actual.width)x\(actual.height) 期望 \(expectedPxW)x\(expectedPxH)")
            endSession()
            return
        }

        // 参考渲染：同一选区 + 同一标注数据
        guard let reference = AnnotationExport.flatten(
            base: view.shot.image,
            cropRectPx: imageRect,
            annotations: annotations,
            scale: scale
        ), let actualBytes = srgbBytes(actual, width: expectedPxW, height: expectedPxH),
            let referenceBytes = srgbBytes(reference, width: expectedPxW, height: expectedPxH) else {
            fail("ANNOTATE-COPY", "参考渲染或像素读取失败")
            endSession()
            return
        }
        if actualBytes == referenceBytes {
            pass("ANNOTATE-COPY", "剪贴板与参考渲染逐字节一致 \(expectedPxW)x\(expectedPxH)")
        } else {
            var mismatched = 0
            for index in 0..<actualBytes.count where actualBytes[index] != referenceBytes[index] {
                mismatched += 1
            }
            fail("ANNOTATE-COPY", "与参考渲染不一致，差异字节 \(mismatched)")
        }

        // 独立验证：不依赖 flatten 的正确性
        let pxScale = Int(scale)
        // 矩形 (50,180,200,70) 空心描边、线宽 5pt：左边缘 x 50..55，取 52 落在边框上
        let border = pixelColor(actualBytes, x: 52 * pxScale, y: expectedPxH - 1 - 215 * pxScale, width: expectedPxW)
        let annotationColor = annotations[0].style.color
        let target = (r: Int(annotationColor.r * 255), g: Int(annotationColor.g * 255), b: Int(annotationColor.b * 255))
        if abs(border.r - target.r) < 30, abs(border.g - target.g) < 30, abs(border.b - target.b) < 30 {
            pass("ANNOTATE-COLOR", "矩形边框像素 \(border) ≈ 标注色 \(target)")
        } else {
            fail("ANNOTATE-COLOR", "矩形边框像素 \(border) 偏离标注色 \(target)")
        }
        // 空心：矩形内部保留底图，不与冻结帧裁剪产生差异
        let inner = pixelColor(actualBytes, x: 150 * pxScale, y: expectedPxH - 1 - 215 * pxScale, width: expectedPxW)
        let innerFrozen = pixelColor(
            srgbBytes(view.shot.image, width: view.shot.image.width, height: view.shot.image.height) ?? [],
            x: Int(imageRect.minX) + 150 * pxScale,
            y: Int(imageRect.minY) + (expectedPxH - 1 - 215 * pxScale),
            width: view.shot.image.width
        )
        if abs(inner.r - innerFrozen.r) <= 8, abs(inner.g - innerFrozen.g) <= 8, abs(inner.b - innerFrozen.b) <= 8 {
            pass("ANNOTATE-HOLLOW", "矩形内部为底图 \(inner)，标注未填充")
        } else {
            fail("ANNOTATE-HOLLOW", "矩形内部被填充 inner=\(inner) frozen=\(innerFrozen)")
        }
        // 画布 (150,247) 在矩形上边框（y 245..250）→ 应落在图像上半（y 翻转会落到下半）
        let topProbe = pixelColor(actualBytes, x: 150 * pxScale, y: expectedPxH - 1 - 247 * pxScale, width: expectedPxW)
        if topProbe.r > 200, expectedPxH - 1 - 247 * pxScale < expectedPxH / 2 {
            pass("ANNOTATE-ORIENTATION", "画布上部的矩形落在图像上半部 \(topProbe)")
        } else {
            fail("ANNOTATE-ORIENTATION", "矩形方向错误 topProbe=\(topProbe)")
        }
        // 矩形外 10 个采样点必须与冻结帧裁剪一致
        var outsideMismatch = 0
        for sample in 0..<10 {
            let canvasX = 300 + sample * 9        // 画布 (300..381, 20..) 矩形右侧
            let canvasY = 20 + sample * 5
            let px = canvasX * pxScale
            let py = expectedPxH - 1 - canvasY * pxScale
            let actualPixel = pixelColor(actualBytes, x: px, y: py, width: expectedPxW)
            // 剪贴板与冻结帧都按顶部行号，帧行 = cropRect 顶行 + py
            let frozen = pixelColor(
                srgbBytes(view.shot.image, width: view.shot.image.width, height: view.shot.image.height) ?? [],
                x: Int(imageRect.minX) + px,
                y: Int(imageRect.minY) + py,
                width: view.shot.image.width
            )
            if abs(actualPixel.r - frozen.r) > 8 || abs(actualPixel.g - frozen.g) > 8 || abs(actualPixel.b - frozen.b) > 8 {
                outsideMismatch += 1
            }
        }
        if outsideMismatch == 0 {
            pass("ANNOTATE-BASE", "矩形外采样点与冻结帧裁剪一致")
        } else {
            fail("ANNOTATE-BASE", "\(outsideMismatch)/10 个底图采样点不一致")
        }

        if visibleOverlayWindows.isEmpty {
            pass("ANNOTATE-CLOSE", "复制后覆盖层消失")
        } else {
            fail("ANNOTATE-CLOSE", "复制后仍有 \(visibleOverlayWindows.count) 个覆盖窗口")
        }
        endSession()
    }

    /// ready 选区内单击不产生形状；微小拖动被丢弃。
    private func runClickAndTinyStroke() {
        guard let (window, view) = beginSession("ANNOTATE-CLICK") else { return }
        drag(view, window: window, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 600, y: 500))

        // 单击选区内，不拖动
        press(view, window: window, path: [CGPoint(x: 300, y: 300)])
        guard view.annotations.isEmpty else {
            fail("ANNOTATE-CLICK", "单击后产生 \(view.annotations.count) 条标注")
            endSession()
            return
        }
        pass("ANNOTATE-CLICK", "ready 下单击未产生形状")

        // 位移 3x1：进入 drawing 但高度不足被丢弃
        press(view, window: window, path: [
            CGPoint(x: 300, y: 300),
            CGPoint(x: 303, y: 301),
        ])
        guard view.annotations.isEmpty else {
            fail("ANNOTATE-DISCARD", "3x1 拖动后残留 \(view.annotations.count) 条标注")
            endSession()
            return
        }
        pass("ANNOTATE-DISCARD", "不足 2pt 边长的拖动被丢弃")

        // 正常笔画仍可用（状态机回到 ready）
        press(view, window: window, path: [
            CGPoint(x: 250, y: 250),
            CGPoint(x: 400, y: 350),
        ])
        if view.annotations.count == 1 {
            pass("ANNOTATE-RECOVER", "丢弃后继续画矩形正常")
        } else {
            fail("ANNOTATE-RECOVER", "丢弃后画矩形失败 annotations=\(view.annotations)")
        }
        endSession()
    }

    /// 选区外按下清空标注并重画选区。
    private func runReselectClears() {
        guard let (window, view) = beginSession("ANNOTATE-RESELECT") else { return }
        drag(view, window: window, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 600, y: 500))
        press(view, window: window, path: [
            CGPoint(x: 250, y: 250),
            CGPoint(x: 400, y: 350),
        ])
        guard view.annotations.count == 1 else {
            fail("ANNOTATE-RESELECT", "前置画矩形失败")
            endSession()
            return
        }
        // 选区外按下重画
        drag(view, window: window, from: CGPoint(x: 700, y: 100), to: CGPoint(x: 900, y: 300))
        if view.annotations.isEmpty {
            pass("ANNOTATE-RESELECT", "选区外重画后标注已清空，新选区 \(view.selectionRect)")
        } else {
            fail("ANNOTATE-RESELECT", "选区外重画后残留 \(view.annotations.count) 条标注")
        }
        endSession()
    }

    /// P1 行为回归：无标注时复制结果与冻结帧裁剪逐像素一致。
    private func runPlainCopyUnchanged() {
        guard let (window, view) = beginSession("ANNOTATE-PLAIN") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 450, y: 350))
        let rect = view.selectionRect
        let imageRect = RectMath.imageRect(
            fromViewRect: rect, viewHeight: view.bounds.height, scale: view.shot.scale
        )
        let integral = imageRect.integral.intersection(
            CGRect(x: 0, y: 0, width: view.shot.image.width, height: view.shot.image.height)
        )
        let expected = view.shot.image.cropping(to: integral)
        NSPasteboard.general.clearContents()
        keyDown(36, characters: "\r", in: window, view: view)
        guard let actual = pasteboardImage() else {
            fail("ANNOTATE-PLAIN", "剪贴板没有图像")
            endSession()
            return
        }
        guard let expected,
              let a = srgbBytes(actual, width: Int(imageRect.width), height: Int(imageRect.height)),
              let e = srgbBytes(expected, width: Int(imageRect.width), height: Int(imageRect.height)) else {
            fail("ANNOTATE-PLAIN", "像素读取失败")
            endSession()
            return
        }
        if a == e {
            pass("ANNOTATE-PLAIN", "无标注复制与冻结帧裁剪逐字节一致")
        } else {
            var mismatched = 0
            for index in 0..<a.count where a[index] != e[index] { mismatched += 1 }
            fail("ANNOTATE-PLAIN", "无标注复制有 \(mismatched) 字节差异")
        }
        endSession()
    }

    /// 选区是否整点（integral 后预览与导出位图尺寸才一致）。
    private func verifyIntegral(_ rect: CGRect) -> Bool {
        rect.origin.x.rounded() == rect.origin.x
            && rect.origin.y.rounded() == rect.origin.y
            && rect.width.rounded() == rect.width
            && rect.height.rounded() == rect.height
    }

    // MARK: - 第二批：形状 / 样式记忆 / ⌘Z

    /// 切换工具画形状 → 复制，独立验证剪贴板中该形状的特征像素。
    private func runShapeCopy(_ id: String, tool: ShapeKind, drawPath: [CGPoint], verify: @escaping (CGImage, OverlayView, CGRect, [Annotation]) -> Void) {
        guard let (window, view) = beginSession(id) else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 600))
        let selection = view.selectionRect
        guard !selection.isEmpty else {
            fail(id, "选区未确定")
            endSession()
            return
        }
        guard tapTool(view, tool, id: id) else {
            endSession()
            return
        }
        // 画布点 = 视图点 - 选区原点
        let viewPath = drawPath.map { CGPoint(x: selection.minX + $0.x, y: selection.minY + $0.y) }
        press(view, window: window, path: viewPath)
        guard let annotation = view.annotations.last,
              annotation.shape.kind == tool else {
            fail(id, "最后一条标注不是 \(tool.rawValue)：\(view.annotations.map(\.shape.kind.rawValue))")
            endSession()
            return
        }
        let annotations = view.annotations
        NSPasteboard.general.clearContents()
        keyDown(36, characters: "\r", in: window, view: view)
        guard let image = pasteboardImage() else {
            fail(id, "剪贴板没有图像")
            endSession()
            return
        }
        verify(image, view, selection, annotations)
        endSession()
    }

    private func runShapeCopies() {
        // 椭圆：中线有色、中心与四角保留底图
        runShapeCopy("SHAPE-ELLIPSE", tool: .ellipse, drawPath: [
            CGPoint(x: 40, y: 80), CGPoint(x: 240, y: 180),
        ]) { image, view, selection, annotations in
            guard case .ellipse(let rect) = annotations.last?.shape else {
                self.fail("SHAPE-ELLIPSE", "形状不是椭圆")
                return
            }
            guard let bytes = self.srgbBytes(image, width: image.width, height: image.height) else {
                self.fail("SHAPE-ELLIPSE", "像素读取失败")
                return
            }
            let px = Int(view.shot.scale)
            let width = image.width
            let height = image.height
            func pixel(atCanvasX x: Int, canvasY y: Int) -> (r: Int, g: Int, b: Int) {
                let offset = ((height - 1 - y * px) * width + x * px) * 4
                return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
            }
            let isAnnotationColor = { (p: (r: Int, g: Int, b: Int)) in
                p.r > 180 && p.g < 130 && p.b < 130
            }
            // 内缩后椭圆：中心 (cx, cy)，半轴 (rx, ry)；下边框中点与左边框中点着色
            let cx = Int(rect.midX), cy = Int(rect.midY)
            let ry = Int(rect.height / 2 - 1.25)
            let rx = Int(rect.width / 2 - 1.25)
            if isAnnotationColor(pixel(atCanvasX: cx, canvasY: cy - ry)),
               isAnnotationColor(pixel(atCanvasX: cx - rx, canvasY: cy)) {
                self.pass("SHAPE-ELLIPSE", "椭圆中线着色 rect=\(rect)")
            } else {
                self.fail("SHAPE-ELLIPSE", "椭圆中线未着色 bottom=\(pixel(atCanvasX: cx, canvasY: cy - ry)) left=\(pixel(atCanvasX: cx - rx, canvasY: cy))")
            }
            let center = pixel(atCanvasX: cx, canvasY: cy)
            let frozen = self.frozenPixel(view, selection: selection, canvasX: cx, canvasY: cy, scale: view.shot.scale)
            if self.closeEnough(center, frozen) {
                self.pass("SHAPE-ELLIPSE-HOLLOW", "椭圆中心保留底图 \(center)")
            } else {
                self.fail("SHAPE-ELLIPSE-HOLLOW", "椭圆中心被填色 \(center) 底图 \(frozen)")
            }
        }

        // 箭头：tip 附近头部填充、线体中段有色、线外留白
        runShapeCopy("SHAPE-ARROW", tool: .arrow, drawPath: [
            CGPoint(x: 60, y: 250), CGPoint(x: 380, y: 250),
        ]) { image, view, _, annotations in
            guard case .arrow(let from, let to) = annotations.last?.shape else {
                self.fail("SHAPE-ARROW", "形状不是箭头")
                return
            }
            guard let bytes = self.srgbBytes(image, width: image.width, height: image.height) else {
                self.fail("SHAPE-ARROW", "像素读取失败")
                return
            }
            let px = Int(view.shot.scale)
            let width = image.width
            let height = image.height
            func pixel(atCanvasX x: Int, canvasY y: Int) -> (r: Int, g: Int, b: Int) {
                let offset = ((height - 1 - y * px) * width + x * px) * 4
                return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
            }
            let isAnnotationColor = { (p: (r: Int, g: Int, b: Int)) in
                p.r > 180 && p.g < 130 && p.b < 130
            }
            // 线宽 5 → 头长 22.5，tip 在 to；头部中段与线体中点都应着色
            let headInside = Int(to.x - 8)
            let midLine = Int((from.x + to.x) / 2)
            if isAnnotationColor(pixel(atCanvasX: headInside, canvasY: Int(to.y))),
               isAnnotationColor(pixel(atCanvasX: midLine, canvasY: Int(from.y))) {
                self.pass("SHAPE-ARROW", "箭头头部填充且线体着色 from=\(from) to=\(to)")
            } else {
                self.fail("SHAPE-ARROW", "箭头特征缺失 head=\(pixel(atCanvasX: headInside, canvasY: Int(to.y))) mid=\(pixel(atCanvasX: midLine, canvasY: Int(from.y)))")
            }
            let outside = pixel(atCanvasX: midLine, canvasY: Int(from.y) + 12)
            if !isAnnotationColor(outside) {
                self.pass("SHAPE-ARROW-OFFLINE", "箭头线外保留底图 \(outside)")
            } else {
                self.fail("SHAPE-ARROW-OFFLINE", "线外被着色 \(outside)")
            }
        }

        // 马赛克：块内均匀 + 与冻结帧存在差异
        runShapeCopy("SHAPE-MOSAIC", tool: .mosaic, drawPath: [
            CGPoint(x: 30, y: 150), CGPoint(x: 90, y: 150), CGPoint(x: 370, y: 150),
        ]) { image, view, selection, annotations in
            guard annotations.last?.shape.kind == .mosaic else {
                self.fail("SHAPE-MOSAIC", "形状不是马赛克")
                return
            }
            guard let bytes = self.srgbBytes(image, width: image.width, height: image.height) else {
                self.fail("SHAPE-MOSAIC", "像素读取失败")
                return
            }
            let px = Int(view.shot.scale)
            let width = image.width
            let height = image.height
            func pixel(atCanvasX x: Int, canvasY y: Int) -> (r: Int, g: Int, b: Int) {
                let offset = ((height - 1 - y * px) * width + x * px) * 4
                return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
            }
            // 块内均匀：p3 块 16pt，region.minX ≈ 30-7.5 → 22；(30,32) (100,102) 同块
            var uneven = 0
            for pair in [(30, 32), (100, 102), (200, 202)] {
                let a = pixel(atCanvasX: pair.0, canvasY: 150)
                let b = pixel(atCanvasX: pair.1, canvasY: 150)
                if abs(a.r - b.r) > 6 || abs(a.g - b.g) > 6 || abs(a.b - b.b) > 6 {
                    uneven += 1
                }
            }
            if uneven == 0 {
                self.pass("SHAPE-MOSAIC-UNIFORM", "块内采样对颜色一致")
            } else {
                self.fail("SHAPE-MOSAIC-UNIFORM", "\(uneven)/3 组块内采样对不一致")
            }
            // 与冻结帧差异只能作参考：屏幕该区域本身均匀时，块平均与原图相同，无法区分。
            // 量化正确性由 AnnotationRendererTests.mosaicQuantizesBasePixels 用条纹底图确定性验证。
            var diff = 0
            var total = 0
            for x in stride(from: 40, through: 360, by: 10) {
                let actual = pixel(atCanvasX: x, canvasY: 150)
                let frozen = self.frozenPixel(view, selection: selection, canvasX: x, canvasY: 150, scale: view.shot.scale)
                total += 1
                if abs(actual.r - frozen.r) > 12 || abs(actual.g - frozen.g) > 12 || abs(actual.b - frozen.b) > 12 {
                    diff += 1
                }
            }
            self.info("SHAPE-MOSAIC-PIXELS", "\(diff)/\(total) 个采样点与冻结帧不同（屏幕均匀时可为 0）")
        }
    }

    /// 冻结帧在画布 (canvasX, canvasY) 处的像素。canvas 原点在选区左下（y 向上），
    /// 帧像素 y 向下：帧行 = cropOrigin.y + (viewHeight - selection.minY - canvasY) * scale。
    private func frozenPixel(
        _ view: OverlayView,
        selection: CGRect,
        canvasX: Int,
        canvasY: Int,
        scale: CGFloat
    ) -> (r: Int, g: Int, b: Int) {
        guard let bytes = srgbBytes(
            view.shot.image, width: view.shot.image.width, height: view.shot.image.height
        ) else { return (-1, -1, -1) }
        let px = Int(view.shot.scale)
        let imageRect = RectMath.imageRect(
            fromViewRect: selection, viewHeight: view.bounds.height, scale: scale
        )
        let x = Int(imageRect.minX) + canvasX * px
        let y = Int(imageRect.minY) + Int((selection.height - CGFloat(canvasY))) * px
        let offset = (y * view.shot.image.width + x) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    private func closeEnough(
        _ a: (r: Int, g: Int, b: Int),
        _ b: (r: Int, g: Int, b: Int)
    ) -> Bool {
        abs(a.r - b.r) <= 8 && abs(a.g - b.g) <= 8 && abs(a.b - b.b) <= 8
    }

    /// 切工具读回各自记忆的色与笔尖：椭圆改蓝后，矩形仍是红、笔尖互不串。
    private func runToolStyleMemory() {
        guard let (window, view) = beginSession("TOOL-MEMORY") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 600))
        let selection = view.selectionRect

        guard tapTool(view, .ellipse, id: "TOOL-MEMORY"),
              pickColor(view, 5, id: "TOOL-MEMORY") else {
            endSession()
            return
        }
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 30, y: selection.minY + 60),
            CGPoint(x: selection.minX + 180, y: selection.minY + 150),
        ])
        guard let ellipseStroke = view.annotations.last,
              ellipseStroke.shape.kind == .ellipse,
              ellipseStroke.style.color == RGBAColor.palette[5] else {
            fail("TOOL-MEMORY", "椭圆应为蓝色，实际 \(String(describing: view.annotations.last?.style.color))")
            endSession()
            return
        }
        pass("TOOL-MEMORY", "椭圆工具 + 蓝色已写入")

        guard tapTool(view, .rect, id: "TOOL-MEMORY") else {
            endSession()
            return
        }
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 260, y: selection.minY + 60),
            CGPoint(x: selection.minX + 400, y: selection.minY + 140),
        ])
        guard let rectStroke = view.annotations.last,
              rectStroke.shape.kind == .rect,
              rectStroke.style.color == RGBAColor.palette[0] else {
            fail("TOOL-MEMORY", "矩形应保持默认红色，实际 \(String(describing: view.annotations.last?.style.color))")
            endSession()
            return
        }
        pass("TOOL-MEMORY", "切回矩形读回红色，两工具颜色互不串")

        // 笔尖记忆：画笔改 p5，椭圆笔尖仍应是默认 p3
        guard tapTool(view, .brush, id: "TOOL-MEMORY"),
              pickPen(view, 4, id: "TOOL-MEMORY") else {
            endSession()
            return
        }
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 40, y: selection.minY + 260),
            CGPoint(x: selection.minX + 300, y: selection.minY + 260),
            CGPoint(x: selection.minX + 310, y: selection.minY + 262),
        ])
        guard let brushStroke = view.annotations.last,
              brushStroke.shape.kind == .brush,
              brushStroke.style.pen == .p5 else {
            fail("TOOL-MEMORY", "画笔应为 p5，实际 \(String(describing: view.annotations.last?.style.pen))")
            endSession()
            return
        }
        pass("TOOL-MEMORY", "画笔工具 + p5 已写入")

        guard tapTool(view, .ellipse, id: "TOOL-MEMORY") else {
            endSession()
            return
        }
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 420, y: selection.minY + 60),
            CGPoint(x: selection.minX + 520, y: selection.minY + 130),
        ])
        guard let secondEllipse = view.annotations.last,
              secondEllipse.shape.kind == .ellipse,
              secondEllipse.style.pen == .p3,
              secondEllipse.style.color == RGBAColor.palette[5] else {
            fail("TOOL-MEMORY", "椭圆应读回自己的蓝 + p3，实际 \(String(describing: view.annotations.last?.style))")
            endSession()
            return
        }
        pass("TOOL-MEMORY", "椭圆读回自己的颜色与笔尖，画笔的 p5 不串")
        endSession()
    }

    /// ⌘Z 撤销最后一笔；空栈时 beep 不崩溃。
    private func runUndo() {
        guard let (window, view) = beginSession("UNDO") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 600))
        let selection = view.selectionRect
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 40, y: selection.minY + 40),
            CGPoint(x: selection.minX + 200, y: selection.minY + 120),
        ])
        press(view, window: window, path: [
            CGPoint(x: selection.minX + 240, y: selection.minY + 40),
            CGPoint(x: selection.minX + 400, y: selection.minY + 120),
        ])
        guard view.annotations.count == 2 else {
            fail("UNDO", "前置画两笔失败：\(view.annotations.count)")
            endSession()
            return
        }
        keyDown(6, characters: "z", in: window, view: view, modifierFlags: .command)
        guard view.annotations.count == 1 else {
            fail("UNDO", "⌘Z 后应剩 1 笔，实际 \(view.annotations.count)")
            endSession()
            return
        }
        keyDown(6, characters: "z", in: window, view: view, modifierFlags: .command)
        guard view.annotations.isEmpty else {
            fail("UNDO", "⌘Z 后应清空，实际 \(view.annotations.count)")
            endSession()
            return
        }
        // 空栈再按：beep（无法断言声音），只验证不崩溃且状态不变
        keyDown(6, characters: "z", in: window, view: view, modifierFlags: .command)
        if view.annotations.isEmpty, !view.selectionRect.isEmpty {
            pass("UNDO", "⌘Z 撤销两笔生效，空栈再按不崩溃")
        } else {
            fail("UNDO", "空栈 ⌘Z 后状态异常 selection=\(view.selectionRect)")
        }
        endSession()
    }

    /// 文字工具：选区内单击进入编辑 → Enter 只换行 → ⌘Enter 提交 → 复制后剪贴板出现标注色文字像素。
    private func runTextAnnotation() {
        guard let (window, view) = beginSession("TEXT") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 600))
        let selection = view.selectionRect
        guard tapTool(view, .text, id: "TEXT") else {
            endSession()
            return
        }
        let click = CGPoint(x: selection.minX + 60, y: selection.minY + 220)
        press(view, window: window, path: [click])
        guard let editor = view.subviews.compactMap({ $0 as? NSTextView }).first else {
            fail("TEXT-COMMIT", "单击后没有出现文字编辑器")
            endSession()
            return
        }
        editor.string = "Hello"
        sendKey(36, characters: "\r", to: editor, in: window)
        guard view.annotations.isEmpty, editor.superview != nil else {
            fail("TEXT-COMMIT", "Enter 不应提交 annotations=\(view.annotations)")
            endSession()
            return
        }
        sendKey(53, characters: "\u{1b}", to: editor, in: window)
        guard view.annotations.isEmpty, editor.superview == nil else {
            fail("TEXT-COMMIT", "Esc 应取消编辑 annotations=\(view.annotations)")
            endSession()
            return
        }
        press(view, window: window, path: [click])
        guard let reopened = view.subviews.compactMap({ $0 as? NSTextView }).first else {
            fail("TEXT-COMMIT", "取消后无法重新进入编辑")
            endSession()
            return
        }
        reopened.string = "Hello"
        sendKey(36, characters: "\r", to: reopened, in: window, modifierFlags: .command)

        guard view.annotations.count == 1,
              case .text(let text, let origin, let fontSize) = view.annotations[0].shape,
              text == "Hello",
              origin == CGPoint(x: 60, y: 220),
              fontSize == PenSize.p3.textFontSize else {
            fail("TEXT-COMMIT", "提交结果异常 annotations=\(view.annotations)")
            endSession()
            return
        }
        pass("TEXT-COMMIT", "Enter 不提交、Esc 取消、⌘Enter 提交；文字已入列 origin=\(origin) fontSize=\(fontSize)")

        NSPasteboard.general.clearContents()
        keyDown(36, characters: "\r", in: window, view: view)
        guard let image = pasteboardImage(),
              let bytes = srgbBytes(image, width: image.width, height: image.height) else {
            fail("TEXT-PIXELS", "剪贴板没有图像")
            endSession()
            return
        }
        let px = Int(view.shot.scale)
        let box = TextMetrics.boundingRect(text, fontSize: fontSize, origin: origin)
        var colored = 0
        for canvasY in Int(box.minY.rounded(.down))...Int(box.maxY.rounded(.up)) {
            for canvasX in Int(box.minX.rounded(.down))...Int(box.maxX.rounded(.up))
                where canvasX >= 0 && canvasY >= 0
                    && canvasX * px < image.width && canvasY * px < image.height {
                let offset = ((image.height - 1 - canvasY * px) * image.width + canvasX * px) * 4
                if Int(bytes[offset]) > 180,
                   Int(bytes[offset + 1]) < 130,
                   Int(bytes[offset + 2]) < 130 {
                    colored += 1
                }
            }
        }
        if colored > 0 {
            pass("TEXT-PIXELS", "剪贴板文字区域有 \(colored) 个标注色像素")
        } else {
            fail("TEXT-PIXELS", "文字区域没有标注色像素 box=\(box)")
        }
        endSession()
    }

    /// 多行文字：两行中文，断言行数、换行保留与包围盒高度。
    private func runMultilineText() {
        guard let (window, view) = beginSession("TEXT-MULTILINE") else { return }
        drag(view, window: window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 750, y: 640))
        let selection = view.selectionRect
        guard tapTool(view, .text, id: "TEXT-MULTILINE") else {
            endSession()
            return
        }
        let click = CGPoint(x: selection.minX + 60, y: selection.minY + 280)
        press(view, window: window, path: [click])
        guard let editor = view.subviews.compactMap({ $0 as? NSTextView }).first else {
            fail("TEXT-MULTILINE", "单击后没有出现文字编辑器")
            endSession()
            return
        }
        editor.string = "测试文字\n测试文字"
        sendKey(36, characters: "\r", to: editor, in: window, modifierFlags: .command)

        guard view.annotations.count == 1,
              case .text(let text, let origin, let fontSize) = view.annotations[0].shape,
              text == "测试文字\n测试文字" else {
            fail("TEXT-MULTILINE", "多行提交异常 annotations=\(view.annotations)")
            endSession()
            return
        }
        let layout = TextMetrics.multiline(text, fontSize: fontSize, origin: origin)
        // 单行实测高度：行距不小于它才不重叠，包围盒要盖住两行叠起来的高度。
        let lineHeight = TextMetrics.boundingRect("测试文字", fontSize: fontSize, origin: origin).height
        let step = layout.lines[0].baseline.y - layout.lines[1].baseline.y
        guard layout.lines.count == 2,
              step >= lineHeight - 0.01,
              layout.rect.height >= step + lineHeight - 0.5,
              layout.lines[1].baseline.y < origin.y else {
            fail("TEXT-MULTILINE", "行布局异常 lines=\(layout.lines.count) rect=\(layout.rect) 行距=\(step) 单行高=\(lineHeight)")
            endSession()
            return
        }
        pass("TEXT-MULTILINE", "两行已入列 lines=\(layout.lines.count) rect.height=\(layout.rect.height) 行距=\(step) 单行高=\(lineHeight)")
        endSession()
    }

    // MARK: - 主流程

    func runAll() {
        if !ScreenCaptureService.hasPermission() {
            print("FATAL 屏幕录制权限缺失，无法执行标注验收")
            exit(2)
        }

        runPlainCopyUnchanged()
        runDrawAndCopy()
        runClickAndTinyStroke()
        runReselectClears()
        runShapeCopies()
        runToolStyleMemory()
        runUndo()
        runTextAnnotation()
        runMultilineText()

        print("SUMMARY passes=\(passes) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}

@main
struct P2AnnotateE2EMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)

            let base = URL(fileURLWithPath: "/tmp/yaosnap-verify", isDirectory: true)
            let evidence = base.appendingPathComponent("evidence", isDirectory: true)
            try? FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)

            let harness = AnnotateHarness(evidenceDir: evidence)
            harness.runAll()
        }
    }
}
