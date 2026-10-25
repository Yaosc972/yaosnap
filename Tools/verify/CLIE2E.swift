import Foundation
import YaosnapCore

var passes = 0
var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        passes += 1
        print("PASS \(label)")
    } else {
        failures += 1
        print("FAIL \(label)")
    }
}

// app 侧 application(_:open:) 直接使用同一个 CommandLineRequest(url:) 解析函数，
// 这里编译 Core 即可覆盖 app 收到的每种 URL 形态。
let urlCases: [(CommandLineCommand, String)] = [
    (.snip, "yaosnap://snip"),
    (.delayedSnip(seconds: 3), "yaosnap://snip?delay=3"),
    (.clipboard, "yaosnap://clipboard"),
    (.save(path: "/tmp/a.png"), "yaosnap://save?path=/tmp/a.png"),
    (.quickSave, "yaosnap://quick-save"),
    (.pin(x: 12, y: 34), "yaosnap://pin?x=12&y=34"),
    (.pickColor, "yaosnap://pick-color"),
    (.barcodeScan, "yaosnap://barcode-scan"),
    (.showImages, "yaosnap://show-images"),
    (.hideImages, "yaosnap://hide-images"),
    (.whiteboard(color: nil, activeScreen: false), "yaosnap://whiteboard"),
    (.whiteboard(color: WhiteboardColor.parse("#112233"), activeScreen: false),
     "yaosnap://whiteboard?color=%23112233"),
    (.whiteboard(color: .gray, activeScreen: true),
     "yaosnap://whiteboard?color=%23808080&active_screen=1"),
]

for (command, expected) in urlCases {
    let request = CommandLineRequest(command: command)
    check(request.url.absoluteString == expected, "build \(expected), got \(request.url.absoluteString)")
    check((try? CommandLineRequest(url: request.url)) == request, "round trip \(expected)")
}

let argumentCases: [([String], String)] = [
    ([], "yaosnap://snip"),
    (["snip"], "yaosnap://snip"),
    (["--delay", "1"], "yaosnap://snip?delay=1"),
    (["snip", "--delay", "60"], "yaosnap://snip?delay=60"),
    (["-o", "clipboard"], "yaosnap://clipboard"),
    (["snip", "-o", "clipboard"], "yaosnap://clipboard"),
    (["-o", "quick-save"], "yaosnap://quick-save"),
    (["-o", "/tmp/shot.png"], "yaosnap://save?path=/tmp/shot.png"),
    (["--pos", "12", "34"], "yaosnap://pin?x=12&y=34"),
    (["snip", "--pos", "-10.5", "20"], "yaosnap://pin?x=-10.5&y=20"),
    (["pick-color"], "yaosnap://pick-color"),
    (["barcode-scan"], "yaosnap://barcode-scan"),
    (["show-images"], "yaosnap://show-images"),
    (["hide-images"], "yaosnap://hide-images"),
    (["whiteboard"], "yaosnap://whiteboard"),
    (["snip", "whiteboard", "--color", "#112233"],
     "yaosnap://whiteboard?color=%23112233"),
    (["whiteboard", "--active-screen"], "yaosnap://whiteboard?active_screen=1"),
    (["whiteboard", "--color", "red", "--active-screen"],
     "yaosnap://whiteboard?color=%23ff0000&active_screen=1"),
]

for (arguments, expected) in argumentCases {
    guard case .request(let request) = try? CommandLineParser.parse(arguments) else {
        check(false, "parse \(arguments)")
        continue
    }
    check(request.url.absoluteString == expected, "parse \(arguments) -> \(expected)")
}

let rejected: [([String], String)] = [
    (["bogus"], "unknown argument"),
    (["-o"], "missing -o value"),
    (["-o", ""], "empty -o value"),
    (["--pos", "1"], "missing y"),
    (["--pos", "left", "2"], "non numeric x"),
    (["-o", "clipboard", "extra"], "extra argument"),
    (["--delay", "0"], "delay below range"),
    (["--delay", "61"], "delay above range"),
    (["whiteboard", "--color"], "whiteboard missing color"),
    (["whiteboard", "--bogus"], "whiteboard unknown option"),
]

for (arguments, label) in rejected {
    check((try? CommandLineParser.parse(arguments)) == nil, "reject \(label)")
}

print("HARNESS passes=\(passes) failures=\(failures)")
exit(failures == 0 ? 0 : 1)
