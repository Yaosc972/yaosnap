import AppKit
import YaosnapCore

/// URL 命令到现有能力的唯一分发点。解析与校验在 Core，这里只做机械接线。
@MainActor
final class AppCommandRouter {
    private let snipController: SnipController
    private let pinController: PinController

    init(snipController: SnipController, pinController: PinController) {
        self.snipController = snipController
        self.pinController = pinController
    }

    func handle(_ url: URL) {
        do {
            handle(try CommandLineRequest(url: url))
        } catch {
            print("[cli] 无法解析 URL \(url.absoluteString): \(error)")
        }
    }

    func handle(_ request: CommandLineRequest) {
        switch request.command {
        case .snip:
            snipController.start()
        case .delayedSnip(let seconds):
            snipController.startDelayed(seconds: seconds)
        case .clipboard:
            snipController.copyLatestCapture()
        case .save(let path):
            snipController.saveLatestCapture(to: path)
        case .quickSave:
            snipController.quickSaveLatestCapture()
        case .pin(let x, let y):
            guard let entry = snipController.latestCapture else {
                print("[cli] 贴图失败：还没有成功输出的截图")
                NSSound.beep()
                return
            }
            pinController.pin(
                image: PasteImage(image: entry.image, pointSize: entry.displaySize),
                at: CGPoint(x: x, y: y)
            )
        case .pickColor:
            snipController.startPickColor()
        case .barcodeScan:
            snipController.scanScreenForBarcode()
        case .showImages:
            pinController.showAll()
        case .hideImages:
            pinController.hideAll()
        case .whiteboard(let background, let activeScreen):
            snipController.startWhiteboard(background: background, activeScreen: activeScreen)
        }
    }
}
