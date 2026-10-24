import Foundation
import Testing
@testable import OwnAudioBooks

/// The widget is redrawn only when what it shows changes.
@Suite("Widget snapshot")
struct WidgetSnapshotTests {
    private func entry(_ id: String, fraction: Double = 0.25) -> WidgetSnapshot.Entry {
        WidgetSnapshot.Entry(id: id, title: "Book \(id)", author: "Someone", fraction: fraction, remainingMs: 1_000, cover: nil)
    }

    @Test("the same books written a minute later are not a change")
    func timeIsNotAChange() {
        let saved = WidgetSnapshot(entries: [entry("a"), entry("b")], at: Date(timeIntervalSince1970: 0))
        let again = WidgetSnapshot(entries: [entry("a"), entry("b")], at: Date(timeIntervalSince1970: 60))
        #expect(!again.differs(from: saved))
    }

    @Test("another position, order or book is a change")
    func entriesAreAChange() {
        let saved = WidgetSnapshot(entries: [entry("a"), entry("b")], at: Date(timeIntervalSince1970: 0))
        #expect(WidgetSnapshot(entries: [entry("a", fraction: 0.5), entry("b")], at: saved.at).differs(from: saved))
        #expect(WidgetSnapshot(entries: [entry("b"), entry("a")], at: saved.at).differs(from: saved))
        #expect(WidgetSnapshot(entries: [entry("a")], at: saved.at).differs(from: saved))
    }

    @Test("nothing saved yet: the first snapshot is written, even an empty one")
    func firstWrite() {
        #expect(WidgetSnapshot(entries: [], at: Date()).differs(from: nil))
        #expect(WidgetSnapshot(entries: [entry("a")], at: Date()).differs(from: nil))
    }
}
