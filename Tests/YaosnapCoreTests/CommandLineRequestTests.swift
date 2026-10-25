import Foundation
import Testing
@testable import YaosnapCore

struct CommandLineRequestTests {
    private func request(_ arguments: [String]) throws -> CommandLineRequest? {
        guard case .request(let request) = try CommandLineParser.parse(arguments) else {
            return nil
        }
        return request
    }

    @Test func bareSnipStartsCapture() throws {
        let parsed = try #require(try request([]))
        #expect(parsed.command == .snip)
        #expect(parsed.url.absoluteString == "yaosnap://snip")
        #expect(try request(["snip"])?.command == .snip)
    }

    @Test func outputClipboardMapsToClipboard() throws {
        #expect(try request(["-o", "clipboard"])?.command == .clipboard)
        #expect(try request(["snip", "-o", "clipboard"])?.command == .clipboard)
        #expect(try request(["-o", "clipboard"])?.url.absoluteString == "yaosnap://clipboard")
    }

    @Test func outputQuickSaveMapsToQuickSave() throws {
        #expect(try request(["-o", "quick-save"])?.command == .quickSave)
        #expect(try request(["-o", "quick-save"])?.url.absoluteString == "yaosnap://quick-save")
    }

    @Test func outputFileNameMapsToSavePath() throws {
        let parsed = try #require(try request(["-o", "/tmp/shot.png"]))
        #expect(parsed.command == .save(path: "/tmp/shot.png"))
        #expect(parsed.url.absoluteString == "yaosnap://save?path=/tmp/shot.png")
    }

    @Test func posMapsToPinCoordinates() throws {
        let integer = try #require(try request(["--pos", "12", "34"]))
        #expect(integer.command == .pin(x: 12, y: 34))
        #expect(integer.url.absoluteString == "yaosnap://pin?x=12&y=34")

        let fractional = try #require(try request(["snip", "--pos", "-10.5", "20"]))
        #expect(fractional.command == .pin(x: -10.5, y: 20))
        #expect(fractional.url.absoluteString == "yaosnap://pin?x=-10.5&y=20")
    }

    @Test func standaloneCommands() throws {
        let cases: [(String, CommandLineCommand, String)] = [
            ("pick-color", .pickColor, "yaosnap://pick-color"),
            ("barcode-scan", .barcodeScan, "yaosnap://barcode-scan"),
            ("show-images", .showImages, "yaosnap://show-images"),
            ("hide-images", .hideImages, "yaosnap://hide-images"),
        ]
        for (argument, command, url) in cases {
            let parsed = try #require(try request([argument]))
            #expect(parsed.command == command)
            #expect(parsed.url.absoluteString == url)
        }
    }

    @Test func helpForms() throws {
        #expect(try CommandLineParser.parse(["--help"]) == .help)
        #expect(try CommandLineParser.parse(["-h"]) == .help)
        #expect(try CommandLineParser.parse(["snip", "--help"]) == .help)
    }

    @Test func invalidArgumentsThrow() {
        #expect(throws: CommandLineParseError.unknownArgument("bogus")) {
            try CommandLineParser.parse(["bogus"])
        }
        #expect(throws: CommandLineParseError.missingValue("-o")) {
            try CommandLineParser.parse(["-o"])
        }
        #expect(throws: CommandLineParseError.missingValue("-o")) {
            try CommandLineParser.parse(["-o", ""])
        }
        #expect(throws: CommandLineParseError.missingValue("--pos X Y")) {
            try CommandLineParser.parse(["--pos", "1"])
        }
        #expect(throws: CommandLineParseError.invalidNumber("left")) {
            try CommandLineParser.parse(["--pos", "left", "2"])
        }
        #expect(throws: CommandLineParseError.invalidNumber("1e999")) {
            try CommandLineParser.parse(["--pos", "1e999", "2"])
        }
        #expect(throws: CommandLineParseError.extraArgument("extra")) {
            try CommandLineParser.parse(["-o", "clipboard", "extra"])
        }
        #expect(throws: CommandLineParseError.extraArgument("3")) {
            try CommandLineParser.parse(["--pos", "1", "2", "3"])
        }
        #expect(throws: CommandLineParseError.unknownArgument("junk")) {
            try CommandLineParser.parse(["snip", "junk"])
        }
    }

    @Test func urlRoundTripForEveryCommand() throws {
        let commands: [CommandLineCommand] = [
            .snip,
            .clipboard,
            .save(path: "/tmp/a b&c?.png"),
            .quickSave,
            .pin(x: -12.5, y: 300),
            .pickColor,
            .barcodeScan,
            .showImages,
            .hideImages,
        ]
        for command in commands {
            let original = CommandLineRequest(command: command)
            let decoded = try CommandLineRequest(url: original.url)
            #expect(decoded == original)
        }
    }

    @Test func urlWithEscapedPathRoundTrips() throws {
        let path = "/tmp/截图 #1 & 100%.png"
        let original = CommandLineRequest(command: .save(path: path))
        let decoded = try CommandLineRequest(url: original.url)
        #expect(decoded == original)
    }

    @Test func invalidURLsThrow() {
        let invalid = [
            "https://snip",
            "yaosnap://bogus",
            "yaosnap://save",
            "yaosnap://save?path=",
            "yaosnap://pin?x=1",
            "yaosnap://pin?x=a&y=2",
            "yaosnap://pin?x=1e999&y=2",
        ]
        for raw in invalid {
            let url = URL(string: raw)!
            #expect(throws: (any Error).self) {
                try CommandLineRequest(url: url)
            }
        }
    }
}
