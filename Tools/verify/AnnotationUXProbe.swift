import AppKit
import CoreGraphics
import Foundation
import YaosnapCore

/// 标注交互探针：复现「在已有形状内部起笔变成拖动旧形状」与「画完不能直接拉手柄」。
@MainActor
final class ProbeWiring {
    let controller = SnipController(historyStore: CaptureHistoryStore(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("yaosnap-probe-history-\(UUID().uuidString)", isDirectory: true)
    ))

    init() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(escape(_:)), name: .snipEscapePressed, object: nil)
        center.addObserver(self, selector: #selector(committed(_:)), name: .snipCommitted, object: nil)
    }

    @objc private func escape(_ notification: Notification) { controller.cancel() }
    @objc private func committed(_ notification: Notification) { controller.commitSelection(notification) }
}

func pump(_ seconds: TimeInterval = 0.2) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

@MainActor
func mouseEvent(
    _ type: NSEvent.EventType,
    at point: CGPoint,
    in window: NSWindow
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
        pressure: type == .leftMouseUp ? 0 : 1
    )
}

@MainActor
func drag(_ view: OverlayView, _ window: NSWindow, from: CGPoint, to: CGPoint) {
    if let down = mouseEvent(.leftMouseDown, at: from, in: window) { view.mouseDown(with: down) }
    for step in 1...4 {
        let t = CGFloat(step) / 4
        let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        if let dragged = mouseEvent(.leftMouseDragged, at: point, in: window) {
            view.mouseDragged(with: dragged)
        }
    }
    if let up = mouseEvent(.leftMouseUp, at: to, in: window) { view.mouseUp(with: up) }
    pump(0.15)
}

@MainActor
func keyDown(_ view: OverlayView, _ window: NSWindow, keyCode: UInt16) {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: keyCode
    ) else { return }
    view.keyDown(with: event)
    pump(0.1)
}

@MainActor
func shapeBounds(_ view: OverlayView, index: Int) -> CGRect? {
    let annotations = view.annotations
    guard annotations.indices.contains(index) else { return nil }
    return annotations[index].shape.bounds
}

@MainActor
func run() {
    let wiring = ProbeWiring()
    wiring.controller.start()
    pump(0.4)

    guard let window = NSApp.windows.compactMap({ $0 as? SnipOverlayWindow }).first(where: \.isVisible),
          let view = window.contentView as? OverlayView else {
        print("PROBE-FAIL no overlay window")
        return
    }

    view.autoSelectOnCreation = ProcessInfo.processInfo.environment["PROBE_AUTOSELECT"] == "1"
    drag(view, window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 500))
    pump(0.2)

    drag(view, window, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 250, y: 250))
    pump(0.2)
    let afterFirst = view.annotations.count
    let firstBounds = shapeBounds(view, index: 0)
    print("PROBE first-shape count=\(afterFirst) bounds=\(String(describing: firstBounds))")

    drag(view, window, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 230, y: 230))
    pump(0.2)
    let afterSecond = view.annotations.count
    let movedBounds = shapeBounds(view, index: 0)
    print("PROBE second-drag count=\(afterSecond) firstBounds=\(String(describing: movedBounds))")

    if afterSecond > afterFirst {
        print("PROBE-A PASS inside existing shape starts a new annotation")
    } else if let firstBounds, let movedBounds, firstBounds != movedBounds {
        print("PROBE-A FAIL inside existing shape moved the old annotation instead of drawing")
    } else {
        print("PROBE-A INCONCLUSIVE count=\(afterSecond)")
    }

    let beforeHandle = view.annotations.last?.shape.bounds
    if let bounds = beforeHandle {
        // 形状 bounds 是画布坐标（原点在选区左下），拖拽事件用视图坐标，需加选区原点。
        let origin = view.selectionRect.origin
        drag(
            view,
            window,
            from: CGPoint(x: origin.x + bounds.maxX, y: origin.y + bounds.maxY),
            to: CGPoint(x: origin.x + bounds.maxX + 40, y: origin.y + bounds.maxY + 40)
        )
        pump(0.2)
        let afterHandle = view.annotations.last?.shape.bounds
        print("PROBE-B before=\(String(describing: bounds)) after=\(String(describing: afterHandle))")
        if bounds != afterHandle, view.annotations.count == afterSecond {
            print("PROBE-B PASS corner drag resized the shape without switching tools")
        } else if bounds == afterHandle {
            print("PROBE-B FAIL corner drag did nothing (needs select tool)")
        } else {
            print("PROBE-B INCONCLUSIVE shape count changed")
        }
    }

    let beforeDelete = view.annotations.count
    keyDown(view, window, keyCode: 51)
    let afterDelete = view.annotations.count
    print("PROBE-C before=\(beforeDelete) after=\(afterDelete)")
    if afterDelete == beforeDelete - 1 {
        print("PROBE-C PASS delete removed the shape that was showing handles")
    } else {
        print("PROBE-C FAIL delete did nothing without a selection")
    }

    wiring.controller.cancel()
}

@main
struct ProbeMain {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        run()
    }
}

