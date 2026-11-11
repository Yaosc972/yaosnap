import AppKit
import CoreGraphics
import Foundation
import YaosnapCore

/// P3 贴图第一批验收 harness。驱动真实 PinController / PinWindow，
/// 验证单张 / 多张共存、关闭、隐藏显示、Esc 与双击。
@MainActor
final class PinHarness {
    private let controller = PinController()
    private var passes = 0
    private var failures = 0

    // MARK: - 基础设施

    private func pass(_ id: String, _ detail: String) {
        passes += 1
        print("PASS \(id) \(detail)")
    }

    private func fail(_ id: String, _ detail: String) {
        failures += 1
        print("FAIL \(id) \(detail)")
    }

    private func pump(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private var imageSerial = 0

    private func makeImage(width: Int, height: Int) -> CGImage {
        imageSerial += 1
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // 每次生成不同像素，剪贴板内容才算真的变了，不会误触关闭贴图的恢复。
        ctx.setFillColor(CGColor(
            srgbRed: 0.9,
            green: min(1, 0.3 + CGFloat(imageSerial) * 0.01),
            blue: 0.2,
            alpha: 1
        ))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func putImage(width: Int, height: Int) {
        let image = NSImage(
            cgImage: makeImage(width: width, height: height),
            size: NSSize(width: width, height: height)
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.writeObjects([image])
    }

    private func putString(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private func putTransparentImage(width: Int, height: Int) {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let image = NSImage(
            cgImage: ctx.makeImage()!,
            size: NSSize(width: width, height: height)
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.writeObjects([image])
    }

    private func shiftClick(_ window: PinWindow) {
        guard let view = window.contentView,
              let event = NSEvent.mouseEvent(
                  with: .leftMouseDown,
                  location: CGPoint(x: 20, y: 15),
                  modifierFlags: .shift,
                  timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: window.windowNumber,
                  context: nil,
                  eventNumber: 0,
                  clickCount: 1,
                  pressure: 1
              ) else { return }
        view.mouseDown(with: event)
    }

    private func allPinWindows() -> [PinWindow] {
        NSApp.windows.compactMap { $0 as? PinWindow }
    }

    private func visiblePinWindows() -> [PinWindow] {
        allPinWindows().filter(\.isVisible)
    }

    private func keyEvent(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        window: NSWindow
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func mouseEvent(clickCount: Int, window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: 5, y: 5),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        )
    }

    private func mouseDragEvent(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        window: NSWindow
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }

    /// 把窗口内容离屏渲染成位图再取像素，屏幕休眠时也不会拿到全黑。
    private func sampledPixel(
        of window: PinWindow,
        atRelative point: CGPoint
    ) -> (r: Int, g: Int, b: Int)? {
        guard let view = window.contentView,
              view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return nil }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = context.data else { return nil }
        let x = min(width - 1, max(0, Int(point.x * CGFloat(width))))
        let yFromBottom = min(height - 1, max(0, Int(point.y * CGFloat(height))))
        let offset = ((height - 1 - yFromBottom) * width + x) * 4
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    // MARK: - 用例

    private func runFirstPin() {
        putImage(width: 40, height: 30)
        let pinned = controller.pinFromPasteboard()
        pump()
        let windows = visiblePinWindows()
        guard pinned, windows.count == 1 else {
            fail("PIN-ONE", "期望 1 个贴图窗口，实际 \(windows.count)")
            return
        }
        let size = windows[0].frame.size
        if size == NSSize(width: 40, height: 30),
           windows[0].level == .floating,
           windows[0].styleMask.isEmpty,
           !windows[0].isOpaque {
            pass("PIN-ONE", "单张贴图 40x30，无边框置顶透明，尺寸一致")
        } else {
            fail("PIN-ONE", "尺寸 \(Int(size.width))x\(Int(size.height))，level=\(windows[0].level.rawValue)")
        }
    }

    private func runSecondPin() {
        putImage(width: 60, height: 40)
        let pinned = controller.pinFromPasteboard()
        pump()
        let windows = visiblePinWindows()
        if pinned, windows.count == 2 {
            pass("PIN-TWO", "第二张贴图后两个窗口共存")
        } else {
            fail("PIN-TWO", "期望 2 个贴图窗口，实际 \(windows.count)")
        }
    }

    private func runCloseOne() {
        let windows = visiblePinWindows()
        guard let first = windows.first else {
            fail("PIN-CLOSE", "没有可关闭的贴图窗口")
            return
        }
        first.close()
        pump()
        let remaining = visiblePinWindows()
        if remaining.count == 1 {
            pass("PIN-CLOSE", "关闭一个后剩 1 个")
        } else {
            fail("PIN-CLOSE", "期望剩 1 个窗口，实际 \(remaining.count)")
        }
    }

    private func runHideShow() {
        let hidden = controller.toggleVisibility()
        pump()
        let visibleAfterHide = visiblePinWindows().count
        if !hidden, visibleAfterHide == 0 {
            pass("PIN-HIDE", "隐藏全部后无可见窗口")
        } else {
            fail("PIN-HIDE", "隐藏后可见 \(visibleAfterHide) 个")
        }

        let shown = controller.toggleVisibility()
        pump()
        let visibleAfterShow = visiblePinWindows().count
        if shown, visibleAfterShow == 1 {
            pass("PIN-SHOW", "再次切换后窗口恢复可见")
        } else {
            fail("PIN-SHOW", "显示后可见 \(visibleAfterShow) 个")
        }
    }

    private func runEscape() {
        guard let window = visiblePinWindows().first,
              let view = window.contentView,
              let event = keyEvent(keyCode: 53, characters: "\u{1b}", window: window) else {
            fail("PIN-ESC", "没有可发送 Esc 的贴图窗口")
            return
        }
        view.keyDown(with: event)
        pump()
        if visiblePinWindows().isEmpty {
            pass("PIN-ESC", "Esc 关闭当前贴图")
        } else {
            fail("PIN-ESC", "Esc 后仍有 \(visiblePinWindows().count) 个窗口")
        }
    }

    private func runDoubleClick() {
        putImage(width: 24, height: 24)
        let pinned = controller.pinFromPasteboard()
        pump()
        guard pinned,
              let window = visiblePinWindows().first,
              let view = window.contentView,
              let event = mouseEvent(clickCount: 2, window: window) else {
            fail("PIN-DBLCLICK", "没有可双击的贴图窗口")
            return
        }
        view.mouseDown(with: event)
        pump()
        if visiblePinWindows().isEmpty {
            pass("PIN-DBLCLICK", "左键双击关闭贴图")
        } else {
            fail("PIN-DBLCLICK", "双击后仍有 \(visiblePinWindows().count) 个窗口")
        }
    }

    private func runColorPin() {
        putString("#FF8800")
        let pinned = controller.pinFromPasteboard()
        pump()
        guard pinned, let window = visiblePinWindows().first else {
            fail("PIN-COLOR", "颜色文本没有贴出窗口")
            return
        }
        let expected = PasteboardReader.colorBlockSize
        if window.frame.size == expected {
            pass("PIN-COLOR", "HEX 颜色生成 \(Int(expected.width))x\(Int(expected.height)) 色块")
        } else {
            fail("PIN-COLOR", "色块尺寸 \(window.frame.size)，期望 \(expected)")
        }
        window.close()
        pump()
    }

    private func runTextPin() {
        putString("贴图文本第二行\nsecond line")
        let pinned = controller.pinFromPasteboard()
        pump()
        guard pinned, let window = visiblePinWindows().first else {
            fail("PIN-TEXT", "纯文本没有贴出窗口")
            return
        }
        let size = window.frame.size
        if size.width > 64, size.height > 64 {
            pass("PIN-TEXT", "纯文本渲染成 \(Int(size.width))x\(Int(size.height)) 窗口")
        } else {
            fail("PIN-TEXT", "文本窗口尺寸异常 \(size)")
        }
        window.close()
        pump()
    }

    private func runFilePathPin() {
        let ctx = CGContext(
            data: nil, width: 20, height: 10,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.7, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        let cgImage = ctx.makeImage()!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yaosnap-pin-e2e-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = ImageOutput.pngData(from: cgImage) else {
            fail("PIN-FILE", "测试 PNG 编码失败")
            return
        }
        try? data.write(to: url)

        putString(url.path)
        let pinned = controller.pinFromPasteboard()
        pump()
        guard pinned, let window = visiblePinWindows().first else {
            fail("PIN-FILE", "图片路径没有贴出窗口")
            return
        }
        if window.frame.size == NSSize(width: 20, height: 10) {
            pass("PIN-FILE", "图片文件路径贴出 20x10 图像")
        } else {
            fail("PIN-FILE", "文件贴图尺寸 \(window.frame.size)，期望 20x10")
        }
        window.close()
        pump()
    }

    private func runHTMLPin() {
        let html = "<html><body><p>HTML 贴图</p></body></html>".data(using: .utf8)!
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(html, forType: .html)

        let pinned = controller.pinFromPasteboard()
        pump()
        guard pinned, let window = visiblePinWindows().first else {
            fail("PIN-HTML", "HTML 没有贴出窗口")
            return
        }
        let size = window.frame.size
        let minHeight = PasteboardReader.textPadding * 2 + PasteboardReader.textFontSize
        if size.width > 64, size.height > minHeight {
            pass("PIN-HTML", "HTML 转文本渲染成 \(Int(size.width))x\(Int(size.height)) 窗口")
        } else {
            fail("PIN-HTML", "HTML 窗口尺寸异常 \(size)")
        }
        window.close()
        pump()
    }

    /// 记下已有窗口号再贴一张 40x30，返回新增的窗口。每个用例只碰自己新建的窗口。
    private func pinFreshWindow() -> PinWindow? {
        let before = Set(allPinWindows().map(\.windowNumber))
        putImage(width: 40, height: 30)
        guard controller.pinFromPasteboard() else { return nil }
        pump()
        return allPinWindows().first { !before.contains($0.windowNumber) }
    }

    /// 把 CGImage 规范成固定 sRGB 像素数据，两张图直接比较就能发现标注差异。
    private func bitmapData(_ image: CGImage) -> Data? {
        guard image.width > 0, image.height > 0,
              let ctx = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: image.width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = ctx.data else { return nil }
        return Data(bytes: data, count: image.width * image.height * 4)
    }

    /// 按下、拖动、抬起三步模拟画一笔标注。
    private func dragAnnotation(
        _ view: PinContentView,
        window: PinWindow,
        from: CGPoint,
        to: CGPoint
    ) {
        guard let down = mouseDragEvent(.leftMouseDown, at: from, window: window),
              let drag = mouseDragEvent(.leftMouseDragged, at: to, window: window),
              let up = mouseDragEvent(.leftMouseUp, at: to, window: window) else {
            fail("PIN-ANNOTATE", "构造标注拖拽失败")
            return
        }
        view.mouseDown(with: down)
        view.mouseDragged(with: drag)
        view.mouseUp(with: up)
    }

    private func runAnnotate() {
        controller.closeAll()
        pump()
        guard let window = pinFreshWindow(),
              let view = window.contentView as? PinContentView,
              let before = window.flattenedImage() else {
            fail("PIN-ANNOTATE", "没有新建贴图窗口或导出图不可用")
            return
        }
        view.setAnnotateMode(true)
        // zoom=1 无旋转时视图坐标即画布坐标，探测矩形底边中点。
        let probe = CGPoint(x: 0.5, y: 10.0 / 30.0)
        let beforePixel = sampledPixel(of: window, atRelative: probe)
        guard view.annotationTool == .rect else {
            fail("PIN-ANNOTATE", "进入标注模式后工具不是矩形")
            window.close()
            return
        }
        dragAnnotation(view, window: window, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 30, y: 20))
        pump(0.1)
        guard view.annotations.count == 1, view.annotations[0].shape.kind == .rect else {
            fail("PIN-ANNOTATE", "标注数 \(view.annotations.count)，期望 1 笔矩形")
            window.close()
            return
        }
        guard let after = window.flattenedImage(),
              let beforeData = bitmapData(before),
              let afterData = bitmapData(after),
              beforeData != afterData else {
            fail("PIN-ANNOTATE", "导出图与标注前相同，标注未进入导出")
            window.close()
            return
        }
        pass("PIN-ANNOTATE", "拖拽产生 1 笔矩形标注，导出图像与标注前不同")

        if let beforePixel,
           let afterPixel = sampledPixel(of: window, atRelative: probe),
           abs(afterPixel.r - beforePixel.r)
               + abs(afterPixel.g - beforePixel.g)
               + abs(afterPixel.b - beforePixel.b) > 15 {
            pass("PIN-ANNOTATE-PIXEL", "预览同位置像素 \(beforePixel)→\(afterPixel) 已带标注")
        } else {
            fail(
                "PIN-ANNOTATE-PIXEL",
                "预览未画出标注 \(String(describing: beforePixel))→\(String(describing: sampledPixel(of: window, atRelative: probe)))"
            )
        }

        // 起点离第一笔够远，否则按下去算「选中/拖动」而不是新落笔。
        dragAnnotation(view, window: window, from: CGPoint(x: 2, y: 2), to: CGPoint(x: 25, y: 15))
        pump(0.05)
        guard view.annotations.count == 2 else {
            fail("PIN-ANNOTATE-UNDO", "第二笔后标注数 \(view.annotations.count)，期望 2")
            window.close()
            return
        }
        guard let undo = keyEvent(
            keyCode: 6,
            characters: "z",
            modifiers: [.command],
            window: window
        ) else {
            fail("PIN-ANNOTATE-UNDO", "构造 ⌘Z 失败")
            window.close()
            return
        }
        view.keyDown(with: undo)
        pump(0.05)
        if view.annotations.count == 1 {
            pass("PIN-ANNOTATE-UNDO", "⌘Z 撤销最后一笔，数量回到 1")
        } else {
            fail("PIN-ANNOTATE-UNDO", "撤销后标注数 \(view.annotations.count)，期望 1")
        }

        guard let esc = keyEvent(keyCode: 53, characters: "\u{1b}", window: window) else {
            fail("PIN-ANNOTATE-ESC", "构造 Esc 失败")
            window.close()
            return
        }
        // Esc 有两级：先把选中取消掉，再按一次才退出标注模式。
        let hadSelection = !view.selectedAnnotationIDs.isEmpty
        view.keyDown(with: esc)
        pump(0.05)
        let deselected = view.selectedAnnotationIDs.isEmpty && view.annotationTool != nil
        view.keyDown(with: esc)
        pump(0.05)
        if window.isVisible, view.annotationTool == nil, !hadSelection || deselected {
            pass("PIN-ANNOTATE-ESC", "Esc 先取消选中再退出标注模式，窗口保留")
        } else {
            fail(
                "PIN-ANNOTATE-ESC",
                "有选中=\(hadSelection) 第一下取消选中=\(deselected) annotationTool=\(String(describing: view.annotationTool)) visible=\(window.isVisible)"
            )
        }
        window.close()
        pump()
    }

    /// 单击一次（按下 + 抬起），给序号/折线/文字这类点按工具用。
    private func clickAt(_ view: PinContentView, window: PinWindow, at point: CGPoint) {
        guard let down = mouseDragEvent(.leftMouseDown, at: point, window: window),
              let up = mouseDragEvent(.leftMouseUp, at: point, window: window) else {
            fail("PIN-TOOLS", "构造点击失败")
            return
        }
        view.mouseDown(with: down)
        view.mouseUp(with: up)
    }

    /// 贴图标注要跟截图主界面一样能画全套工具，这里逐个工具驱动一遍。
    private func runAnnotateTools() {
        controller.closeAll()
        pump()
        guard let window = pinFreshWindow(),
              let view = window.contentView as? PinContentView else {
            fail("PIN-TOOLS", "没有新建贴图窗口")
            return
        }
        view.setAnnotateMode(true)
        view.layoutSubtreeIfNeeded()
        pump(0.1)

        // 底栏先是得真的可见，再谈工具全不全。底栏挂在贴图窗口的浮动子窗口里。
        let bar = window.childWindows?
            .compactMap { $0.contentView as? PinAnnotateBar }
            .first
        if let bar {
            let missing = Set(ShapeKind.allCases).subtracting(bar.exposedTools)
            if bar.frame.width > 0, bar.frame.height > 0, missing.isEmpty {
                pass(
                    "PIN-TOOLS-BAR",
                    "底栏 \(Int(bar.frame.width))x\(Int(bar.frame.height))，覆盖全部 \(ShapeKind.allCases.count) 个工具"
                )
            } else {
                fail(
                    "PIN-TOOLS-BAR",
                    "底栏 \(Int(bar.frame.width))x\(Int(bar.frame.height))，缺工具 \(missing.map { String(describing: $0) })"
                )
            }
        } else {
            fail("PIN-TOOLS-BAR", "标注模式下找不到浮动标注底栏")
        }

        let dragTools: [ShapeKind] = [
            .rect, .roundedRect, .ellipse, .line, .arrow,
            .brush, .marker, .mosaic, .blur, .mosaicRect, .magnify,
        ]
        for kind in dragTools {
            // 每个工具在干净画布上画：叠在上一笔上按下去是「选中/拖动」，不是新落笔。
            view.restoreAnnotations([])
            view.annotationTool = kind
            let before = view.annotations.count
            dragAnnotation(view, window: window, from: CGPoint(x: 8, y: 8), to: CGPoint(x: 30, y: 22))
            pump(0.02)
            if view.annotations.count == before + 1, view.annotations.last?.shape.kind == kind {
                pass("PIN-TOOLS-\(String(describing: kind))", "拖拽落笔 \(String(describing: kind))")
            } else {
                fail(
                    "PIN-TOOLS-\(String(describing: kind))",
                    "标注数 \(view.annotations.count) 期望 \(before + 1)，末笔 \(String(describing: view.annotations.last?.shape.kind))"
                )
            }
        }

        view.restoreAnnotations([])
        view.annotationTool = .serial
        let serialBefore = view.annotations.count
        clickAt(view, window: window, at: CGPoint(x: 20, y: 15))
        clickAt(view, window: window, at: CGPoint(x: 26, y: 15))
        pump(0.02)
        let serialValues = view.annotations.suffix(2).compactMap { annotation -> Int? in
            guard case .serial(let value, _, _) = annotation.shape else { return nil }
            return value
        }
        if view.annotations.count == serialBefore + 2, serialValues == [1, 2] {
            pass("PIN-TOOLS-SERIAL", "两次点击落序号 1、2")
        } else {
            fail(
                "PIN-TOOLS-SERIAL",
                "标注数 \(view.annotations.count) 期望 \(serialBefore + 2)，序号 \(serialValues)"
            )
        }

        view.restoreAnnotations([])
        view.annotationTool = .polyline
        let polyBefore = view.annotations.count
        clickAt(view, window: window, at: CGPoint(x: 5, y: 5))
        clickAt(view, window: window, at: CGPoint(x: 15, y: 12))
        clickAt(view, window: window, at: CGPoint(x: 25, y: 6))
        if let enter = keyEvent(keyCode: 36, characters: "\r", window: window) {
            view.keyDown(with: enter)
        }
        pump(0.02)
        if view.annotations.count == polyBefore + 1,
           case .polyline(let points)? = view.annotations.last?.shape,
           points.count == 3 {
            pass("PIN-TOOLS-POLYLINE", "三次点击 + Enter 落一笔 3 点折线")
        } else {
            fail(
                "PIN-TOOLS-POLYLINE",
                "标注数 \(view.annotations.count) 期望 \(polyBefore + 1)，末笔 \(String(describing: view.annotations.last?.shape))"
            )
        }

        view.restoreAnnotations([])
        view.annotationTool = .text
        let textBefore = view.annotations.count
        clickAt(view, window: window, at: CGPoint(x: 6, y: 6))
        pump(0.05)
        if let editor = view.subviews.compactMap({ $0 as? NSTextView }).first {
            editor.string = "文字"
            if let commit = keyEvent(keyCode: 36, characters: "\r", modifiers: [.command], window: window) {
                editor.keyDown(with: commit)
            }
            pump(0.05)
        }
        var textCommitted = false
        if view.annotations.count == textBefore + 1,
           case .text(let text, _, _, _)? = view.annotations.last?.shape,
           text == "文字" {
            textCommitted = true
        }
        if textCommitted {
            pass("PIN-TOOLS-TEXT", "点击出输入框，⌘Enter 提交文字标注")
        } else {
            fail(
                "PIN-TOOLS-TEXT",
                "标注数 \(view.annotations.count) 期望 \(textBefore + 1)，末笔 \(String(describing: view.annotations.last?.shape))"
            )
        }

        view.restoreAnnotations([])
        view.annotationTool = .rect
        dragAnnotation(view, window: window, from: CGPoint(x: 8, y: 8), to: CGPoint(x: 30, y: 20))
        pump(0.02)
        view.annotationTool = .eraser
        let eraseBefore = view.annotations.count
        dragAnnotation(view, window: window, from: CGPoint(x: 2, y: 2), to: CGPoint(x: 38, y: 28))
        pump(0.02)
        if eraseBefore > 0, view.annotations.count < eraseBefore {
            pass("PIN-TOOLS-ERASER", "橡皮擦一次拖动删掉 \(eraseBefore - view.annotations.count) 笔")
        } else {
            fail(
                "PIN-TOOLS-ERASER",
                "擦除前 \(eraseBefore) 笔，擦除后 \(view.annotations.count) 笔，期望减少"
            )
        }
        // 存一张示意截图，人工确认底栏位置与工具齐全。
        if let panel = window.childWindows?.first(where: { $0.contentView is PinAnnotateBar }) {
            dumpAnnotateLayout(window: window, panel: panel)
        }

        // 收起贴图时底栏必须跟着消失，否则屏幕上会留一条没人管的工具栏。
        view.setAnnotateMode(false)
        pump(0.05)
        let detached = window.childWindows?.contains { $0.contentView is PinAnnotateBar } != true
        if detached {
            pass("PIN-TOOLS-DETACH", "退出标注模式后底栏浮窗已移除")
        } else {
            fail("PIN-TOOLS-DETACH", "退出标注模式后底栏浮窗还在")
        }

        view.setAnnotateMode(true)
        pump(0.05)
        controller.hideAll()
        pump(0.05)
        let hiddenWithParent = window.childWindows?.contains { $0.isVisible } != true
        if hiddenWithParent {
            pass("PIN-TOOLS-HIDE", "收起贴图后底栏一起隐藏")
        } else {
            fail("PIN-TOOLS-HIDE", "收起贴图后底栏仍然可见")
        }
        controller.showAll()
        pump(0.05)
        window.close()
        pump()
    }

    /// 把贴图窗口与浮动底栏一起渲染成一张 PNG，给人工验收用。
    private func dumpAnnotateLayout(window: PinWindow, panel: NSWindow) {
        guard let view = window.contentView, let bar = panel.contentView else { return }
        let union = window.frame.union(panel.frame)
        let padding: CGFloat = 12
        let scale: CGFloat = 2
        let pointSize = NSSize(width: union.width + padding * 2, height: union.height + padding * 2)
        let image = NSImage(size: NSSize(width: pointSize.width * scale, height: pointSize.height * scale))
        image.lockFocus()
        NSColor(white: 0.86, alpha: 1).setFill()
        NSRect(origin: .zero, size: NSSize(
            width: pointSize.width * scale,
            height: pointSize.height * scale
        )).fill()
        if let context = NSGraphicsContext.current?.cgContext {
            context.scaleBy(x: scale, y: scale)
            func draw(_ target: NSView, from frame: NSRect) {
                guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
                target.cacheDisplay(in: target.bounds, to: rep)
                rep.draw(in: NSRect(
                    x: frame.minX - union.minX + padding,
                    y: frame.minY - union.minY + padding,
                    width: target.bounds.width,
                    height: target.bounds.height
                ))
            }
            draw(view, from: window.frame)
            draw(bar, from: panel.frame)
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: "/tmp/yaosnap-verify/evidence/pin-annotate-layout.png")
        try? png.write(to: url)
        print("EVIDENCE \(url.path)")
    }

    /// 关闭再按贴图键恢复，图上的标注必须跟着回来（用户抱怨过同类问题：
    /// 截图历史丢标注；贴图这条链路原先也没接）。
    private func runAnnotateRestore() {
        controller.closeAll()
        pump()
        guard let window = pinFreshWindow(),
              let view = window.contentView as? PinContentView else {
            fail("PIN-ANNOTATE-RESTORE", "没有新建贴图窗口")
            return
        }
        view.setAnnotateMode(true)
        dragAnnotation(view, window: window, from: CGPoint(x: 8, y: 8), to: CGPoint(x: 30, y: 20))
        view.setAnnotateMode(false)
        pump(0.05)
        guard view.annotations.count == 1, let annotated = window.flattenedImage() else {
            fail("PIN-ANNOTATE-RESTORE", "标注数 \(view.annotations.count)，期望 1")
            window.close()
            return
        }
        // 普通关闭才会进恢复列表。
        window.close()
        pump(0.1)
        let before = Set(allPinWindows().map(\.windowNumber))
        guard controller.pinFromPasteboard() else {
            fail("PIN-ANNOTATE-RESTORE", "从恢复列表贴回失败")
            return
        }
        pump(0.1)
        guard let restored = allPinWindows().first(where: { !before.contains($0.windowNumber) }),
              let restoredView = restored.contentView as? PinContentView else {
            fail("PIN-ANNOTATE-RESTORE", "没有恢复出新贴图窗口")
            return
        }
        guard restoredView.annotations.count == 1 else {
            fail("PIN-ANNOTATE-RESTORE", "恢复后标注数 \(restoredView.annotations.count)，期望 1")
            restored.close()
            return
        }
        guard let after = restored.flattenedImage(),
              let left = bitmapData(annotated),
              let right = bitmapData(after),
              left == right else {
            fail("PIN-ANNOTATE-RESTORE", "恢复后的导出图与关闭前不一致，标注没带回来")
            restored.close()
            return
        }
        pass("PIN-ANNOTATE-RESTORE", "关闭再恢复，标注与导出图完全一致")

        // 历史翻页换图时，标注要换成该历史项自己的那份，不能串台。
        let otherAnnotation = Annotation(
            shape: .ellipse(CGRect(x: 3, y: 3, width: 10, height: 8)),
            style: Style(color: RGBAColor.palette[1], pen: .p3)
        )
        restored.applyHistory(PinRestoreEntry(
            image: restored.pasteImage,
            transform: restored.transform,
            frame: restored.frame,
            basePointSize: restored.basePointSize,
            groupID: 1,
            annotations: [otherAnnotation]
        ))
        pump(0.05)
        let switched = restoredView.annotations.map(\.id) == [otherAnnotation.id]
        if switched {
            pass("PIN-ANNOTATE-HISTORY", "历史翻页换图后标注跟着换成该历史项自己的那笔")
        } else {
            fail(
                "PIN-ANNOTATE-HISTORY",
                "翻页后标注 \(restoredView.annotations.map { String(describing: $0.shape.kind) })，期望只留该历史项的 1 笔"
            )
        }
        restored.close()
        pump()
    }

    /// 画好的标注要能点选、拖动、删除、改样式；贴图这条链路原先画完就是死图。
    private func runAnnotateSelect() {
        controller.closeAll()
        pump()
        guard let window = pinFreshWindow(),
              let view = window.contentView as? PinContentView else {
            fail("PIN-SELECT", "没有新建贴图窗口")
            return
        }
        view.setAnnotateMode(true)
        dragAnnotation(view, window: window, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 30, y: 20))
        pump(0.05)
        guard view.annotations.count == 1, let original = view.annotations.first else {
            fail("PIN-SELECT", "标注数 \(view.annotations.count)，期望 1")
            window.close()
            return
        }
        // 画完自动选中（与截图主界面一致）。
        let autoSelected = view.selectedAnnotationIDs == [original.id]
        // 点空白处取消选中，且不会留下新标注（零尺寸草稿被丢弃）。
        clickAt(view, window: window, at: CGPoint(x: 36, y: 4))
        pump(0.05)
        let deselected = view.selectedAnnotationIDs.isEmpty && view.annotations.count == 1
        // 再点回矩形的左边描边：命中即选中，也不产生新一笔。
        clickAt(view, window: window, at: CGPoint(x: 10, y: 15))
        pump(0.05)
        if autoSelected, deselected, view.selectedAnnotationIDs == [original.id],
           view.annotations.count == 1 {
            pass("PIN-SELECT", "画完自动选中；点空白取消选中；点描边重新选中（标注数始终 1）")
        } else {
            fail(
                "PIN-SELECT",
                "自动选中=\(autoSelected) 点空白取消=\(deselected) 选中数=\(view.selectedAnnotationIDs.count) 标注数=\(view.annotations.count)"
            )
        }

        // 从描边上拖 6pt：整笔平移，数量不变。
        dragAnnotation(view, window: window, from: CGPoint(x: 10, y: 15), to: CGPoint(x: 16, y: 21))
        pump(0.05)
        let movedShape = view.annotations.first?.shape
        var movedBy: CGPoint?
        if case .rect(let rect) = original.shape, case .rect(let moved)? = movedShape {
            movedBy = CGPoint(x: moved.minX - rect.minX, y: moved.minY - rect.minY)
        }
        if let movedBy, abs(movedBy.x - 6) < 1.5, abs(movedBy.y - 6) < 1.5,
           view.annotations.count == 1 {
            pass("PIN-MOVE", "拖动选中标注平移 (\(movedBy.x), \(movedBy.y))，数量仍为 1")
        } else {
            fail(
                "PIN-MOVE",
                "位移 \(String(describing: movedBy))，标注数 \(view.annotations.count)，期望约 (6,6) 且 1 笔"
            )
        }

        // 改颜色作用到选中标注，而不是只影响下一笔。
        let colorBefore = view.annotations.first?.style.color
        view.cycleAnnotationColor()
        pump(0.02)
        if let color = view.annotations.first?.style.color, color != colorBefore {
            pass("PIN-RESTYLE", "改颜色后选中标注的样式跟着变")
        } else {
            fail("PIN-RESTYLE", "选中标注的颜色没变，仍是 \(String(describing: view.annotations.first?.style.color))")
        }

        // Delete 删掉选中的那一笔，⌘Z 能撤回来。
        if let del = keyEvent(keyCode: 51, characters: "\u{7f}", window: window) {
            view.keyDown(with: del)
            pump(0.05)
        }
        let deleted = view.annotations.isEmpty && view.selectedAnnotationIDs.isEmpty
        if deleted {
            pass("PIN-DELETE", "Delete 删掉选中标注")
        } else {
            fail("PIN-DELETE", "删除后标注数 \(view.annotations.count)，选中 \(view.selectedAnnotationIDs.count)")
        }
        if let undo = keyEvent(keyCode: 6, characters: "z", modifiers: [.command], window: window) {
            view.keyDown(with: undo)
            pump(0.05)
        }
        if view.annotations.count == 1 {
            pass("PIN-DELETE-UNDO", "⌘Z 撤回删除，标注数回到 1")
        } else {
            fail("PIN-DELETE-UNDO", "撤回后标注数 \(view.annotations.count)，期望 1")
        }
        window.close()
        pump()
    }

    private func runZoom() {
        guard let window = pinFreshWindow() else {
            fail("PIN-ZOOM", "没有新建贴图窗口")
            return
        }
        window.setScale(2)
        pump(0.1)
        let size = window.frame.size
        if size == NSSize(width: 80, height: 60) {
            pass("PIN-ZOOM", "scale 2 后窗口 80x60")
        } else {
            fail("PIN-ZOOM", "窗口 \(Int(size.width))x\(Int(size.height))，期望 80x60")
        }
        window.close()
        pump()
    }

    private func runRotate() {
        guard let window = pinFreshWindow() else {
            fail("PIN-ROTATE", "没有新建贴图窗口")
            return
        }
        window.rotate(byQuarterTurns: 1)
        pump(0.1)
        let size = window.frame.size
        if size == NSSize(width: 30, height: 40) {
            pass("PIN-ROTATE", "顺时针 90 度后窗口 30x40")
        } else {
            fail("PIN-ROTATE", "窗口 \(Int(size.width))x\(Int(size.height))，期望 30x40")
        }
        window.close()
        pump()
    }

    private func runOpacity() {
        guard let window = pinFreshWindow() else {
            fail("PIN-OPACITY", "没有新建贴图窗口")
            return
        }
        window.setOpacity(0.5)
        pump(0.1)
        if window.alphaValue == 0.5 {
            pass("PIN-OPACITY", "透明度 0.5 生效")
        } else {
            fail("PIN-OPACITY", "alphaValue 为 \(window.alphaValue)，期望 0.5")
        }
        window.close()
        pump()
    }

    private func runContextMenu() {
        guard let window = pinFreshWindow(), let view = window.contentView else {
            fail("PIN-MENU", "没有贴图窗口")
            return
        }
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: CGPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let menu = view.menu(for: event) else {
            fail("PIN-MENU", "右键菜单未生成")
            window.close()
            return
        }
        let titles = menu.items.map(\.title)
        let expected = [
            "复制图像", "图像另存为…", "窗口阴影", "缩放", "图像处理",
            "裁剪", "粘贴", "移动到分组", "关闭", "销毁",
        ]
        let missing = expected.filter { !titles.contains($0) }
        guard missing.isEmpty else {
            fail("PIN-MENU", "缺少菜单项 \(missing)，实际 \(titles)")
            window.close()
            return
        }
        let effects = menu.items.first { $0.title == "图像处理" }?.submenu?.items.map(\.title) ?? []
        guard effects.contains("向左旋转"), effects.contains("向右旋转"),
              effects.contains("水平翻转"), effects.contains("垂直翻转") else {
            fail("PIN-MENU", "图像处理子菜单不全 \(effects)")
            window.close()
            return
        }
        pass("PIN-MENU", "右键菜单 \(titles.count) 项，图像处理子菜单四项齐全")
        window.close()
    }

    private func runImageEffects() {
        guard let window = pinFreshWindow(), let view = window.contentView,
              let original = sampledPixel(of: window, atRelative: CGPoint(x: 0.5, y: 0.5)),
              let grayEvent = keyEvent(keyCode: 5, characters: "g", window: window) else {
            fail("PIN-GRAYSCALE", "没有可读像素的贴图窗口")
            return
        }
        view.keyDown(with: grayEvent)
        pump(0.1)
        guard let gray = sampledPixel(of: window, atRelative: CGPoint(x: 0.5, y: 0.5)) else {
            fail("PIN-GRAYSCALE", "灰度后读不到像素")
            window.close()
            return
        }
        if gray.r == gray.g, gray.g == gray.b,
           !(original.r == original.g && original.g == original.b) {
            pass("PIN-GRAYSCALE", "G 后像素 \(gray.r),\(gray.g),\(gray.b) 三通道相等")
        } else {
            fail("PIN-GRAYSCALE", "原色 \(original)，灰度后 \(gray)")
        }

        guard let invertEvent = keyEvent(keyCode: 34, characters: "i", window: window) else {
            fail("PIN-INVERT", "构造 I 键失败")
            window.close()
            return
        }
        view.keyDown(with: invertEvent)
        pump(0.1)
        guard let inverted = sampledPixel(of: window, atRelative: CGPoint(x: 0.5, y: 0.5)) else {
            fail("PIN-INVERT", "反色后读不到像素")
            window.close()
            return
        }
        if abs(inverted.r - (255 - gray.r)) <= 2,
           abs(inverted.g - (255 - gray.g)) <= 2,
           abs(inverted.b - (255 - gray.b)) <= 2 {
            pass("PIN-INVERT", "反色后像素 \(inverted) 等于 255 减灰度值")
        } else {
            fail("PIN-INVERT", "灰度 \(gray)，反色后 \(inverted)")
        }

        // 关掉两个开关应回到原色，验证原始图没有被改写。
        view.keyDown(with: invertEvent)
        view.keyDown(with: grayEvent)
        pump(0.1)
        if let restored = sampledPixel(of: window, atRelative: CGPoint(x: 0.5, y: 0.5)),
           abs(restored.r - original.r) <= 2,
           abs(restored.g - original.g) <= 2,
           abs(restored.b - original.b) <= 2 {
            pass("PIN-EFFECT-RESTORE", "关掉灰度与反色后恢复原色")
        } else {
            fail("PIN-EFFECT-RESTORE", "原色 \(original)，恢复后读像素失败或颜色不符")
        }
        window.close()
        pump()
    }

    private func runCrop() {
        guard let window = pinFreshWindow(), let view = window.contentView else {
            fail("PIN-CROP", "没有新建贴图窗口")
            return
        }
        let before = window.frame
        guard let cropKey = keyEvent(keyCode: 8, characters: "c", window: window),
              let down = mouseDragEvent(.leftMouseDown, at: CGPoint(x: 0, y: 0), window: window),
              let drag = mouseDragEvent(.leftMouseDragged, at: CGPoint(x: 20, y: 30), window: window),
              let up = mouseDragEvent(.leftMouseUp, at: CGPoint(x: 20, y: 30), window: window) else {
            fail("PIN-CROP", "构造裁剪事件失败")
            window.close()
            return
        }
        view.keyDown(with: cropKey)
        pump(0.05)
        view.mouseDown(with: down)
        view.mouseDragged(with: drag)
        view.mouseUp(with: up)
        pump(0.1)

        let after = window.frame
        if after.size == NSSize(width: 20, height: 30),
           after.minX == before.minX,
           after.maxY == before.maxY {
            pass("PIN-CROP", "裁剪后窗口 20x30，左上角未动")
        } else {
            fail("PIN-CROP", "裁剪后 frame \(after)，裁剪前 \(before)")
        }

        guard let undo = keyEvent(
            keyCode: 6,
            characters: "z",
            modifiers: [.command],
            window: window
        ) else {
            fail("PIN-CROP-UNDO", "构造 ⌘Z 失败")
            window.close()
            return
        }
        view.keyDown(with: undo)
        pump(0.1)
        if window.frame.size == before.size,
           window.frame.minX == before.minX,
           window.frame.maxY == before.maxY {
            pass("PIN-CROP-UNDO", "⌘Z 恢复到裁剪前的 40x30")
        } else {
            fail("PIN-CROP-UNDO", "撤销后 frame \(window.frame)，期望 \(before)")
        }
        window.close()
        pump()
    }

    private func runMiddleReset() {
        guard let window = pinFreshWindow(), let view = window.contentView else {
            fail("PIN-MIDDLE-RESET", "没有新建贴图窗口")
            return
        }
        window.setScale(2)
        window.rotate(byQuarterTurns: 1)
        window.setOpacity(0.5)
        window.toggleFlipHorizontal()
        pump(0.1)

        guard let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .otherMouseDown,
            mouseCursorPosition: .zero,
            mouseButton: .center
        ), let event = NSEvent(cgEvent: cgEvent) else {
            fail("PIN-MIDDLE-RESET", "构造中键事件失败")
            window.close()
            return
        }
        view.otherMouseDown(with: event)
        pump(0.1)

        let size = window.frame.size
        if size == NSSize(width: 40, height: 30),
           window.alphaValue == 1,
           window.transform == .identity {
            pass("PIN-MIDDLE-RESET", "中键恢复到 40x30、不透明、identity")
        } else {
            fail("PIN-MIDDLE-RESET", "尺寸 \(size) alpha \(window.alphaValue)")
        }
        window.close()
        pump()
    }

    private func runControlW() {
        guard let window = pinFreshWindow(), let view = window.contentView else {
            fail("PIN-CTRL-W", "没有新建贴图窗口")
            return
        }
        let before = visiblePinWindows().count
        guard let event = keyEvent(
            keyCode: 13,
            characters: "w",
            modifiers: .control,
            window: window
        ) else {
            fail("PIN-CTRL-W", "构造 Ctrl+W 事件失败")
            window.close()
            return
        }
        view.keyDown(with: event)
        pump()
        let after = visiblePinWindows().count
        if after == before - 1 {
            pass("PIN-CTRL-W", "Ctrl+W 关闭当前贴图")
        } else {
            fail("PIN-CTRL-W", "关闭后可见 \(after) 个，期望 \(before - 1)")
        }
        window.close()
        pump()
    }

    private func runRestoreClosed() {
        guard let window = pinFreshWindow() else {
            fail("PIN-RESTORE", "没有新建贴图窗口")
            return
        }
        window.setScale(1.5)
        pump(0.1)
        let frame = window.frame
        let transform = window.transform
        window.close()
        pump()

        // 不再写剪贴板：内容与上次贴出相同，贴图键应该恢复而不是新建。
        let before = Set(allPinWindows().map(\.windowNumber))
        let pinned = controller.pinFromPasteboard()
        pump()
        guard pinned, let restored = allPinWindows().first(where: { !before.contains($0.windowNumber) }) else {
            fail("PIN-RESTORE", "剪贴板未变时没有恢复关闭的贴图")
            return
        }
        if restored.frame == frame, restored.transform == transform {
            pass("PIN-RESTORE", "关闭后贴图键恢复原位置与变换")
        } else {
            fail("PIN-RESTORE", "恢复后 frame \(restored.frame) transform \(restored.transform)")
        }
    }

    private func runPinHistory() {
        controller.setRestoreCapacity(5)
        var historyFrames: [CGRect] = []
        for size in [(40, 30), (60, 40), (80, 50)] {
            putImage(width: size.0, height: size.1)
            guard controller.pinFromPasteboard(), let pin = allPinWindows().last else {
                fail("PIN-HISTORY", "准备历史贴图失败 size=\(size)")
                return
            }
            historyFrames.append(pin.frame)
            pin.close()
            pump()
        }
        guard historyFrames.count == 3 else {
            fail("PIN-HISTORY", "历史准备不足 \(historyFrames.count)")
            return
        }

        putImage(width: 100, height: 60)
        guard controller.pinFromPasteboard(), let host = allPinWindows().last else {
            fail("PIN-HISTORY", "翻页载体贴图失败")
            return
        }
        pump()
        let hostFrame = host.frame

        guard let forward = keyEvent(keyCode: 47, characters: ".", window: host) else {
            fail("PIN-HISTORY", "构造句号事件失败")
            host.close()
            return
        }
        host.contentView?.keyDown(with: forward)
        pump()
        guard host.frame == historyFrames[0] else {
            fail("PIN-HISTORY", "句号后 frame \(host.frame)，期望最早一张 \(historyFrames[0])")
            host.close()
            return
        }

        guard let forwardAgain = keyEvent(keyCode: 47, characters: ".", window: host) else {
            fail("PIN-HISTORY", "构造第二次句号事件失败")
            host.close()
            return
        }
        host.contentView?.keyDown(with: forwardAgain)
        pump()
        guard host.frame == historyFrames[1] else {
            fail("PIN-HISTORY", "再按句号后 frame \(host.frame)，期望第二张 \(historyFrames[1])")
            host.close()
            return
        }

        guard let back = keyEvent(keyCode: 43, characters: ",", window: host) else {
            fail("PIN-HISTORY", "构造逗号事件失败")
            host.close()
            return
        }
        host.contentView?.keyDown(with: back)
        pump()
        guard host.frame == historyFrames[0] else {
            fail("PIN-HISTORY", "逗号后 frame \(host.frame)，期望回到最早一张 \(historyFrames[0])")
            host.close()
            return
        }
        pass("PIN-HISTORY", "句号与逗号在历史间翻页，窗口位置随历史项还原")
        host.close()
        controller.setRestoreCapacity(1)
    }

    private func runPassthrough() {
        guard let window = pinFreshWindow() else {
            fail("PIN-PASSTHROUGH", "没有新建贴图窗口")
            return
        }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        _ = controller.togglePassthrough(at: center)
        pump(0.05)
        guard window.ignoresMouseEvents else {
            fail("PIN-PASSTHROUGH", "切换后 ignoresMouseEvents 仍为 false")
            return
        }
        if visiblePinWindows().contains(where: { $0 !== window && $0.ignoresMouseEvents }) {
            fail("PIN-PASSTHROUGH", "穿透切换影响了光标未覆盖的贴图")
            return
        }

        _ = controller.togglePassthrough(at: center)
        pump(0.05)
        if window.ignoresMouseEvents {
            fail("PIN-PASSTHROUGH", "再次切换后仍为穿透")
        } else {
            pass("PIN-PASSTHROUGH", "切换后穿透，再切换恢复可点击")
        }
    }

    private func runGroupSwitch() {
        controller.closeAll()
        pump()
        guard let defaultPin = pinFreshWindow(), let secondPin = pinFreshWindow() else {
            fail("PIN-GROUP-SWITCH", "没有新建贴图窗口")
            return
        }
        guard controller.addGroup(named: "工作"),
              let workID = controller.pinGroups.first(where: { $0.name == "工作" })?.id else {
            fail("PIN-GROUP-SWITCH", "新建分组失败")
            return
        }
        guard controller.activateGroup(workID) else {
            fail("PIN-GROUP-SWITCH", "切换分组失败")
            return
        }
        let afterSwitch = visiblePinWindows()
        if afterSwitch.isEmpty {
            pass("PIN-GROUP-SWITCH", "切到空分组后原组贴图全部隐藏")
        } else {
            fail("PIN-GROUP-SWITCH", "切组后仍有 \(afterSwitch.count) 个可见贴图")
        }

        guard controller.activateGroup(PinBoard.defaultGroupID) else {
            fail("PIN-GROUP-RESTORE", "切回默认组失败")
            return
        }
        let restored = visiblePinWindows()
        if restored.count == 2,
           restored.contains(where: { $0 === defaultPin }),
           restored.contains(where: { $0 === secondPin }) {
            pass("PIN-GROUP-RESTORE", "切回默认组后两张贴图恢复可见")
        } else {
            fail("PIN-GROUP-RESTORE", "切回后可见 \(restored.count) 个")
        }

        controller.deleteGroup(workID)
        pump()
    }

    private func runSolo() {
        controller.closeAll()
        pump()
        guard let solo = pinFreshWindow(), let other = pinFreshWindow() else {
            fail("PIN-SOLO", "没有新建贴图窗口")
            return
        }
        guard controller.toggleSolo(pinID: solo.pinID) else {
            fail("PIN-SOLO", "开启 Solo 失败")
            return
        }
        pump(0.1)
        let soloVisible = visiblePinWindows()
        if soloVisible.count == 1, soloVisible[0] === solo {
            pass("PIN-SOLO", "Solo 后只显示目标贴图")
        } else {
            fail("PIN-SOLO", "Solo 后可见 \(soloVisible.count) 个，期望 1")
        }

        guard controller.toggleSolo(pinID: solo.pinID) else {
            fail("PIN-SOLO-EXIT", "退出 Solo 失败")
            return
        }
        pump(0.1)
        let afterExit = visiblePinWindows()
        if afterExit.count == 2,
           afterExit.contains(where: { $0 === solo }),
           afterExit.contains(where: { $0 === other }) {
            pass("PIN-SOLO-EXIT", "退出 Solo 后两张贴图恢复可见")
        } else {
            fail("PIN-SOLO-EXIT", "退出后可见 \(afterExit.count) 个，期望 2")
        }

        solo.close()
        other.close()
        pump()
    }

    private func runMultiSelect() {
        controller.closeAll()
        pump()
        guard let first = pinFreshWindow(), let second = pinFreshWindow() else {
            fail("PIN-MULTI-SELECT", "没有新建两张贴图")
            return
        }
        shiftClick(first)
        shiftClick(second)
        pump(0.1)
        if controller.selectedPinCount == 2,
           first.isMultiSelected,
           second.isMultiSelected {
            pass("PIN-MULTI-SELECT", "Shift 点击两张贴图后多选集合为 2")
        } else {
            fail("PIN-MULTI-SELECT", "多选集合 \(controller.selectedPinCount)")
        }
    }

    private func runMultiDrag() {
        guard controller.selectedPinCount == 2 else {
            fail("PIN-MULTI-DRAG", "多选集合不是 2")
            return
        }
        let windows = visiblePinWindows()
        guard windows.count == 2, let moverView = windows[0].contentView else {
            fail("PIN-MULTI-DRAG", "可见贴图不是 2 张")
            return
        }
        let mover = windows[0]
        let other = windows[1]
        let moverOrigin = mover.frame.origin
        let otherOrigin = other.frame.origin
        guard let down = mouseDragEvent(.leftMouseDown, at: CGPoint(x: 20, y: 15), window: mover),
              let drag = mouseDragEvent(.leftMouseDragged, at: CGPoint(x: 40, y: 30), window: mover),
              let up = mouseDragEvent(.leftMouseUp, at: CGPoint(x: 40, y: 30), window: mover) else {
            fail("PIN-MULTI-DRAG", "构造拖动事件失败")
            return
        }
        moverView.mouseDown(with: down)
        moverView.mouseDragged(with: drag)
        moverView.mouseUp(with: up)
        pump(0.1)

        let moverDelta = CGPoint(
            x: mover.frame.minX - moverOrigin.x,
            y: mover.frame.minY - moverOrigin.y
        )
        let otherDelta = CGPoint(
            x: other.frame.minX - otherOrigin.x,
            y: other.frame.minY - otherOrigin.y
        )
        if moverDelta != .zero, moverDelta == otherDelta {
            pass("PIN-MULTI-DRAG", "拖动一张后两张位移一致 \(Int(moverDelta.x)),\(Int(moverDelta.y))")
        } else {
            fail("PIN-MULTI-DRAG", "位移 \(moverDelta) / \(otherDelta)")
        }
    }

    private func runMultiEscape() {
        guard controller.selectedPinCount == 2,
              let window = visiblePinWindows().first,
              let view = window.contentView,
              let event = keyEvent(keyCode: 53, characters: "\u{1b}", window: window) else {
            fail("PIN-MULTI-ESC", "多选集合不是 2 或没有窗口")
            return
        }
        view.keyDown(with: event)
        pump(0.1)
        if visiblePinWindows().isEmpty, controller.selectedPinCount == 0 {
            pass("PIN-MULTI-ESC", "Esc 关闭整组后窗口数为 0")
        } else {
            fail("PIN-MULTI-ESC", "Esc 后可见 \(visiblePinWindows().count) 个")
        }
    }

    private func runBackground() {
        controller.closeAll()
        pump()
        let before = Set(allPinWindows().map(\.windowNumber))
        putTransparentImage(width: 40, height: 30)
        guard controller.pinFromPasteboard() else {
            fail("PIN-BACKGROUND", "透明图没有贴出窗口")
            return
        }
        pump()
        guard let window = allPinWindows().first(where: { !before.contains($0.windowNumber) }) else {
            fail("PIN-BACKGROUND", "找不到新建的透明贴图")
            return
        }
        guard window.background == .transparent else {
            fail("PIN-BACKGROUND", "默认背景不是透明：\(window.background.rawValue)")
            return
        }
        window.setBackground(.darkCheckerboard)
        pump(0.1)
        let pixel = sampledPixel(of: window, atRelative: CGPoint(x: 0.1, y: 0.1))
        if window.background == .darkCheckerboard,
           let pixel,
           pixel.r < 90, pixel.g < 90, pixel.b < 90 {
            pass(
                "PIN-BACKGROUND",
                "切暗色棋盘后背景为 \(window.background.rawValue)，像素 \(pixel.r),\(pixel.g),\(pixel.b)"
            )
        } else {
            fail("PIN-BACKGROUND", "background=\(window.background.rawValue) pixel=\(String(describing: pixel))")
        }
        window.close()
        pump()
    }

    func runAll() {
        runFirstPin()
        runSecondPin()
        runCloseOne()
        runHideShow()
        runEscape()
        runDoubleClick()
        runColorPin()
        runTextPin()
        runHTMLPin()
        runFilePathPin()
        runZoom()
        runRotate()
        runOpacity()
        runContextMenu()
        runImageEffects()
        runCrop()
        runMiddleReset()
        runControlW()
        runRestoreClosed()
        runPinHistory()
        runPassthrough()
        runGroupSwitch()
        runSolo()
        runMultiSelect()
        runMultiDrag()
        runMultiEscape()
        runBackground()
        runAnnotate()
        runAnnotateTools()
        runAnnotateRestore()
        runAnnotateSelect()
        controller.closeAll()
        print("SUMMARY passes=\(passes) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}

@main
struct P3PinE2EMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)

            let base = URL(fileURLWithPath: "/tmp/yaosnap-verify", isDirectory: true)
            let evidence = base.appendingPathComponent("evidence", isDirectory: true)
            try? FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)

            let harness = PinHarness()
            harness.runAll()
        }
    }
}
