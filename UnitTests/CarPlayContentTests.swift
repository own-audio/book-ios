import BookLibrary
import CarPlay
import Foundation
import Testing
@testable import OwnAudioBooks

/// What the car's screen shows, checked without a car (see `CarPlayContent`).
@MainActor
@Suite("CarPlay content")
struct CarPlayContentTests {
    private func book(_ id: String) -> Book {
        Book(id: id, title: "Book \(id)", durationMs: 3_600_000, addedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("the start screen lists Continue Listening, Downloads, Library, Series and Authors")
    func root() {
        #expect(CarPlayContent.rootEntries(hasServer: true) == [.continueListening, .downloads, .library, .series, .authors])
        #expect(CarPlayContent.rootEntries(hasServer: true).map(\.title) == ["Continue Listening", "Downloads", "Library", "Series", "Authors"])
        #expect(CarPlayContent.rootEntries(hasServer: false).isEmpty, "no server: no lists")
    }

    @Test("online, Continue Listening is the server's own shelf, at most 100")
    func continueOnline() {
        let shelves = [
            Shelf(id: "recently-added", title: "Recently Added", kind: .books([book("x")])),
            Shelf(id: "continue-listening", title: "Continue Listening", kind: .books((0..<130).map { book("c\($0)") })),
        ]
        let books = CarPlayContent.continueListening(fromShelves: shelves)
        #expect(books.count == CarPlayContent.maxItems)
        #expect(books.first?.id == "c0")
        #expect(CarPlayContent.continueListening(fromShelves: [shelves[0]]).isEmpty, "no such shelf: nothing")
    }

    @Test("offline, Continue Listening is the downloaded books that are started and not finished")
    func continueOffline() {
        let progress: [String: ListeningProgress] = [
            "started": ListeningProgress(positionMs: 60_000, finished: false, updatedAt: .distantPast),
            "finished": ListeningProgress(positionMs: 3_600_000, finished: true, updatedAt: .distantPast),
            "fresh": ListeningProgress(positionMs: 0, finished: false, updatedAt: .distantPast),
        ]
        let books = CarPlayContent.continueListening(offline: ["started", "finished", "fresh", "unknown"].map(book)) { progress[$0.id] }
        #expect(books.map(\.id) == ["started"])
    }

    @Test("the rate button goes 1× → 1.25× … 2× → 0.75× → 1×")
    func rates() {
        var rate: Float = 1
        var seen: [Float] = []
        for _ in 0..<6 {
            rate = CarPlayContent.nextRate(after: rate)
            seen.append(rate)
        }
        #expect(seen == [1.25, 1.5, 1.75, 2, 0.75, 1])
    }

    @Test("a chapter without a title is numbered")
    func chapterTitles() {
        #expect(CarPlayContent.chapterTitle("Down the Rabbit-Hole", index: 0) == "Down the Rabbit-Hole")
        #expect(CarPlayContent.chapterTitle("", index: 2) == "Chapter 3")
    }

    @Test("a list: one section, its rows, at most 100, and the empty text")
    func listTemplate() {
        let items = (0..<120).map { CPListItem(text: "Row \($0)", detailText: nil) }
        let template = CarPlayContent.listTemplate(title: "Downloads", items: items, emptyText: "Nothing downloaded")
        #expect(template.title == "Downloads")
        #expect(template.sections.count == 1)
        #expect(template.sections[0].items.count == CarPlayContent.maxItems)
        #expect(template.emptyViewTitleVariants == ["Nothing downloaded"])
    }
}
