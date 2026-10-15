import BookLibrary
import SwiftUI

/// Where the library screens go; one navigation destination for all of them.
enum LibraryRoute: Hashable {
    case book(Book, serverId: UUID)
    case books(title: String, query: BookQuery, serverId: UUID)
    case authors(serverId: UUID)
    case narrators(serverId: UUID)
    case series(serverId: UUID)
    case oneSeries(SeriesSummary, serverId: UUID)
    case collections(serverId: UUID)
    case collection(Collection, serverId: UUID)

    static func == (a: LibraryRoute, b: LibraryRoute) -> Bool { a.key == b.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }

    private var key: String {
        switch self {
        case .book(let book, let serverId): "book|\(serverId)|\(book.id)"
        case .books(let title, let query, let serverId): "books|\(serverId)|\(title)|\(query.authorId ?? "")|\(query.narratorId ?? "")|\(query.seriesId ?? "")|\(query.filter.rawValue)|\(query.sort.rawValue)|\(query.text ?? "")"
        case .authors(let serverId): "authors|\(serverId)"
        case .narrators(let serverId): "narrators|\(serverId)"
        case .series(let serverId): "series|\(serverId)"
        case .oneSeries(let series, let serverId): "oneSeries|\(serverId)|\(series.id)"
        case .collections(let serverId): "collections|\(serverId)"
        case .collection(let collection, let serverId): "collection|\(serverId)|\(collection.id)"
        }
    }
}

extension View {
    func libraryDestinations() -> some View {
        navigationDestination(for: LibraryRoute.self) { route in
            switch route {
            case .book(let book, let serverId): BookDetailView(book: book, serverId: serverId)
            case .books(let title, let query, let serverId): BooksListView(title: title, query: query, serverId: serverId)
            case .authors(let serverId): PeopleView(kind: .authors, serverId: serverId)
            case .narrators(let serverId): PeopleView(kind: .narrators, serverId: serverId)
            case .series(let serverId): SeriesListView(serverId: serverId)
            case .oneSeries(let series, let serverId): SeriesDetailView(series: series, serverId: serverId)
            case .collections(let serverId): CollectionsView(serverId: serverId)
            case .collection(let collection, let serverId): CollectionDetailView(collection: collection, serverId: serverId)
            }
        }
    }
}
