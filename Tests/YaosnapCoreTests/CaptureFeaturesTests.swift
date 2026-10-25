import CoreGraphics
import Testing
@testable import YaosnapCore

struct CaptureFeaturesTests {
    private func cand(
        _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
        layer: Int = 0, owner: String = "App", pid: pid_t = 8
    ) -> WindowCandidate {
        WindowCandidate(
            bounds: CGRect(x: x, y: y, width: w, height: h),
            ownerName: owner,
            layer: layer,
            windowID: Int.random(in: 1...99999),
            ownerPID: pid
        )
    }

    // MARK: - 延时参数

    @Test func delayAcceptsOneThroughSixty() {
        #expect(DelayCapture.seconds(from: "1") == 1)
        #expect(DelayCapture.seconds(from: "30") == 30)
        #expect(DelayCapture.seconds(from: "60") == 60)
    }

    @Test func delayRejectsOutOfRangeAndNonNumeric() {
        #expect(DelayCapture.seconds(from: "0") == nil)
        #expect(DelayCapture.seconds(from: "61") == nil)
        #expect(DelayCapture.seconds(from: "-1") == nil)
        #expect(DelayCapture.seconds(from: "1.5") == nil)
        #expect(DelayCapture.seconds(from: "") == nil)
        #expect(DelayCapture.seconds(from: "abc") == nil)
    }

    @Test func delayOptionParsesAndRoundTrips() throws {
        guard case .request(let request) = try CommandLineParser.parse(["--delay", "5"]) else {
            Issue.record("--delay 5 应解析为请求")
            return
        }
        #expect(request.command == .delayedSnip(seconds: 5))
        #expect(request.url.absoluteString == "yaosnap://snip?delay=5")
        #expect(try CommandLineRequest(url: request.url) == request)

        guard case .request(let prefixed) = try CommandLineParser.parse(
            ["snip", "--delay", "60"]
        ) else {
            Issue.record("snip --delay 60 应解析为请求")
            return
        }
        #expect(prefixed.command == .delayedSnip(seconds: 60))
    }

    @Test func delayOptionRejectsOutOfRange() {
        #expect(throws: CommandLineParseError.invalidDelay("0")) {
            try CommandLineParser.parse(["--delay", "0"])
        }
        #expect(throws: CommandLineParseError.invalidDelay("61")) {
            try CommandLineParser.parse(["--delay", "61"])
        }
    }

    // MARK: - 重复上次区域

    @Test func repeatRegionKeepsSameScreenSelection() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let region = CaptureRegion(
            displayID: 1,
            rect: CGRect(x: 100, y: 120, width: 300, height: 200),
            displayBounds: bounds
        )
        #expect(RepeatRegion.map(region, onto: bounds) == region.rect)
    }

    @Test func repeatRegionScalesProportionallyIntoTargetScreen() {
        let region = CaptureRegion(
            displayID: 1,
            rect: CGRect(x: 500, y: 500, width: 200, height: 100),
            displayBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000)
        )
        let mapped = RepeatRegion.map(
            region,
            onto: CGRect(x: 1000, y: 0, width: 500, height: 500)
        )
        #expect(mapped == CGRect(x: 1250, y: 250, width: 100, height: 50))
    }

    @Test func repeatRegionNeverEscapesTargetBounds() {
        let region = CaptureRegion(
            displayID: 1,
            rect: CGRect(x: 900, y: 900, width: 400, height: 400),
            displayBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000)
        )
        let target = CGRect(x: 0, y: 0, width: 500, height: 300)
        let mapped = RepeatRegion.map(region, onto: target)
        #expect(target.contains(mapped))
    }

    // MARK: - 活动窗口候选

    @Test func activeWindowPicksFrontmostForeignWindow() {
        let own = cand(0, 0, 800, 600, owner: "Yaosnap", pid: 7)
        let front = cand(100, 100, 640, 480, owner: "Front", pid: 8)
        let back = cand(0, 0, 1440, 900, owner: "Back", pid: 9)
        let picked = ActiveWindow.pick(from: [own, front, back], ownPID: 7)
        #expect(picked?.ownerName == "Front")
    }

    @Test func activeWindowReturnsNilWithOnlyOwnWindows() {
        let own = cand(0, 0, 800, 600, owner: "Yaosnap", pid: 7)
        #expect(ActiveWindow.pick(from: [own], ownPID: 7) == nil)
    }

    @Test func activeWindowSkipsNonNormalLayers() {
        let menu = cand(0, 0, 1440, 25, layer: 25, owner: "Window Server", pid: 9)
        #expect(ActiveWindow.pick(from: [menu], ownPID: 7) == nil)
    }
}
