import CoreGraphics
import Foundation
import Testing
@testable import YaosnapCore

struct CaptureHistoryMenuTests {
    private func entry(width: Int, height: Int, at time: TimeInterval) -> CaptureHistoryEntry {
        let image = WhiteboardImage.make(width: width, height: height, background: .solid(.black))!
        return CaptureHistoryEntry(
            image: image,
            displaySize: CGSize(width: width, height: height),
            createdAt: Date(timeIntervalSince1970: time)
        )
    }

    @Test func emptyHistoryHasNoItems() {
        #expect(CaptureHistoryMenu.items(from: []).isEmpty)
    }

    @Test func itemsKeepNewestFirstOrderAndCapAtTen() {
        let entries = (0..<12).map { index in
            entry(width: 100 + index, height: 50, at: 1_700_000_000 - Double(index))
        }
        let items = CaptureHistoryMenu.items(from: entries)

        #expect(items.count == CaptureHistoryMenu.limit)
        #expect(items.map(\.index) == Array(0..<CaptureHistoryMenu.limit))
        #expect(items[0].title.hasSuffix(" · 100×50"))
        #expect(items[1].title.hasSuffix(" · 101×50"))
        #expect(items[9].title.hasSuffix(" · 109×50"))
    }

    @Test func titleCarriesTimestampAndPixelSize() {
        let items = CaptureHistoryMenu.items(from: [entry(width: 320, height: 200, at: 1_700_000_000)])

        let title = items.first?.title ?? ""
        #expect(title.range(
            of: #"^\d{2}:\d{2}:\d{2} · 320×200$"#,
            options: .regularExpression
        ) != nil)
    }
}
