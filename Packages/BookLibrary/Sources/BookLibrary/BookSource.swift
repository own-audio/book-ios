import Foundation

/// What a server can do beyond the basics every source has (shelves, books, progress,
/// bookmarks, play). Screens ask before offering a feature, so a missing one is hidden, not
/// broken.
public struct Capabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let series = Capabilities(rawValue: 1 << 0)
    public static let collections = Capabilities(rawValue: 1 << 1)
    /// Search runs on the server; otherwise over the catalogue on the phone.
    public static let serverSearch = Capabilities(rawValue: 1 << 2)
    public static let favourites = Capabilities(rawValue: 1 << 3)
    /// The server keeps where each device left off, so "continue from the car" is possible.
    public static let perDevicePositions = Capabilities(rawValue: 1 << 4)
    /// Books have an owner and are private or shared with the household.
    public static let familySharing = Capabilities(rawValue: 1 << 5)
    public static let upload = Capabilities(rawValue: 1 << 6)
    /// The server says when something changed (`LiveLibraryUpdates`).
    public static let liveUpdates = Capabilities(rawValue: 1 << 7)
    /// The whole library comes from a snapshot and a change feed (`ChangeFeedCatalogue`).
    public static let changeFeed = Capabilities(rawValue: 1 << 8)
    /// The server makes a smaller stream on request.
    public static let lowerBitrate = Capabilities(rawValue: 1 << 9)
    /// Narrators are records with ids, not just names.
    public static let narratorIds = Capabilities(rawValue: 1 << 10)
}

/// One server, whatever its kind. Every method may throw `SourceError`.
public protocol BookSource: Sendable {
    var capabilities: Capabilities { get }

    func checkConnection() async -> ConnectionStatus

    // Browsing
    func shelves() async throws -> [Shelf]
    func books(_ query: BookQuery, cursor: String?, limit: Int) async throws -> BooksPage
    /// With files and chapters.
    func book(id: String) async throws -> Book
    func authors() async throws -> [Person]
    func narrators() async throws -> [Person]
    func series() async throws -> [SeriesSummary]
    /// With its books in order.
    func series(id: String) async throws -> SeriesSummary
    func collections() async throws -> [Collection]
    func search(_ text: String) async throws -> SearchResult

    // The listener's state
    func progress(bookId: String) async throws -> ListeningProgress?
    /// Every book the listener started, by id.
    func allProgress() async throws -> [String: ListeningProgress]
    /// Returns what the server holds after the save: another device's newer position wins.
    func saveProgress(bookId: String, positionMs: Int64, durationMs: Int64, finished: Bool, at: Date) async throws -> ListeningProgress
    func clearProgress(bookId: String) async throws
    func bookmarks(bookId: String) async throws -> [Bookmark]
    func addBookmark(bookId: String, positionMs: Int64, label: String?) async throws -> Bookmark
    func renameBookmark(_ bookmark: Bookmark, label: String?) async throws -> Bookmark
    func deleteBookmark(_ bookmark: Bookmark) async throws
    func favourites() async throws -> Set<String>
    func setFavourite(bookId: String, _ on: Bool) async throws

    // Playing
    /// `maxBitrateKbps` asks for a smaller stream where the server makes one.
    func playPlan(for book: Book, maxBitrateKbps: Int?) async throws -> PlayPlan
    /// A position reached while playing; what the server holds afterwards.
    func report(_ report: PlaybackReport) async throws -> ListeningProgress?
    /// The link for one file again, after the plan's links ran out.
    func partURL(for book: Book, fileId: String, startMs: Int64?, maxBitrateKbps: Int?) async throws -> PlayPlan.Part

    func signOut() async
}

extension BookSource {
    public func books(_ query: BookQuery = BookQuery(), limit: Int = 100) async throws -> BooksPage {
        try await books(query, cursor: nil, limit: limit)
    }

    /// Every page.
    public func allBooks(_ query: BookQuery = BookQuery()) async throws -> [Book] {
        var out: [Book] = []
        var cursor: String?
        repeat {
            let page = try await books(query, cursor: cursor, limit: 200)
            out += page.books
            cursor = page.next
        } while cursor != nil
        return out
    }
}

/// A source that can keep the library on the phone up to date from a change feed: the whole
/// library once, then only what changed. Sources without one are synced by paging.
public protocol ChangeFeedCatalogue: BookSource {
    /// Brings `state` up to date — from scratch when it is nil, or when the server says the
    /// changes since it are too many or too old — and returns it with the library it describes.
    func syncCatalogue(_ state: FeedState?) async throws -> FeedResult
}

/// A source that says when the library changed elsewhere, so the copy on the phone can catch
/// up at once rather than at the next scheduled sync.
public protocol LiveLibraryUpdates: BookSource {
    /// One element per change, until the connection ends (normally or with an error).
    func libraryChanges() -> AsyncThrowingStream<Void, Error>
}

/// Where a change feed was read up to, and the records it brought, kept between launches as
/// JSON the app does not look into.
public struct FeedState: Codable, Sendable, Equatable {
    public let cursor: String
    /// By kind (`book`, `contributor`, `progress.book`, `bookmark`, `favourite.book`), then by
    /// id, the record as it came.
    public var records: [String: [String: Data]]

    public init(cursor: String, records: [String: [String: Data]]) {
        self.cursor = cursor
        self.records = records
    }
}

public struct FeedResult: Sendable {
    public let state: FeedState
    public let books: [Book]
    public let authors: [Person]
    public let narrators: [Person]
    public let progress: [String: ListeningProgress]
    public let bookmarks: [Bookmark]
    public let favourites: Set<String>
}
