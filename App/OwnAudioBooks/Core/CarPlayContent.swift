import BookLibrary
import CarPlay
import Foundation

/// What the car's screen shows, kept apart from the scene delegate so the unit tests can check it
/// without a car: the start list, which books Continue Listening holds online and offline, the
/// speed the rate button goes to next, and how a list is built. Shaped like the podcasts app's.
enum CarPlayContent {
    /// CarPlay's guidelines ask for short lists; the system also caps them.
    static let maxItems = 100

    enum RootEntry: CaseIterable, Equatable {
        case continueListening, downloads, library, series, authors

        var title: String {
            switch self {
            case .continueListening: String(localized: "Continue Listening")
            case .downloads: String(localized: "Downloads")
            case .library: String(localized: "Library")
            case .series: String(localized: "Series")
            case .authors: String(localized: "Authors")
            }
        }

        var symbol: String {
            switch self {
            case .continueListening: "play.circle"
            case .downloads: "arrow.down.circle"
            case .library: "books.vertical"
            case .series: "square.stack.3d.up"
            case .authors: "person.2"
            }
        }
    }

    /// Continue Listening first and downloads next, because a car often has no signal. With no
    /// server, no lists: the start screen says to add one on the iPhone.
    static func rootEntries(hasServer: Bool) -> [RootEntry] {
        hasServer ? RootEntry.allCases : []
    }

    /// Online: the server's own Continue Listening shelf.
    static func continueListening(fromShelves shelves: [Shelf]) -> [Book] {
        guard let shelf = shelves.first(where: { $0.id == "continue-listening" }), case .books(let books) = shelf.kind else { return [] }
        return Array(books.prefix(maxItems))
    }

    /// Offline: the books on the phone that are started and not finished.
    static func continueListening(offline books: [Book], progress: (Book) -> ListeningProgress?) -> [Book] {
        Array(books.filter { progress($0).map { $0.positionMs > 0 && !$0.finished } ?? false }.prefix(maxItems))
    }

    /// 1× → 1.25× → … → 2× → 0.75× → 1×, the steps of the phone's speed settings.
    static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    static func nextRate(after current: Float) -> Float {
        rates.first { $0 > current + 0.01 } ?? rates[0]
    }

    /// A chapter's row: its title, or "Chapter 3" for one without.
    static func chapterTitle(_ title: String, index: Int) -> String {
        title.isEmpty ? String(localized: "Chapter \(index + 1)") : title
    }

    /// A list as the car shows it: one section, the rows, and what it says when empty.
    static func listTemplate(title: String, items: [CPListItem], emptyText: String) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [CPListSection(items: Array(items.prefix(maxItems)))])
        template.emptyViewTitleVariants = [emptyText]
        return template
    }
}
