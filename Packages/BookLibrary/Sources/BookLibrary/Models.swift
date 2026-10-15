import Foundation

// The app's records, whatever the server. Positions and durations are milliseconds of **book
// time** — from the start of the book, across its files; the engine converts to a file and an
// offset at the edge. Ids are the server's own, opaque; the app prefixes them with the server's
// id where several servers meet.

public struct Person: Sendable, Equatable, Hashable, Identifiable {
    /// The server's id, or the name where a server has none (Audiobookshelf's narrators).
    public let id: String
    public let name: String
    public var bookCount: Int?
    public var imageURL: URL?

    public init(id: String, name: String, bookCount: Int? = nil, imageURL: URL? = nil) {
        self.id = id
        self.name = name
        self.bookCount = bookCount
        self.imageURL = imageURL
    }
}

/// A book's place in a series. `sequence` is as the server has it ("1", "1.5", "1-3");
/// `position` is the number in it, for sorting.
public struct SeriesRef: Sendable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let sequence: String?

    public init(id: String, name: String, sequence: String?) {
        self.id = id
        self.name = name
        self.sequence = sequence
    }

    public var position: Double? {
        guard let sequence else { return nil }
        let head = sequence.prefix { $0.isNumber || $0 == "." || $0 == "," }.replacingOccurrences(of: ",", with: ".")
        return Double(head)
    }
}

/// One file of a book, in playing order; `startMs` is where it begins in book time.
public struct BookFile: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String?
    public let durationMs: Int64
    public let startMs: Int64
    public let sizeBytes: Int64?
    public let contentType: String?

    public init(id: String, title: String?, durationMs: Int64, startMs: Int64, sizeBytes: Int64?, contentType: String?) {
        self.id = id
        self.title = title
        self.durationMs = durationMs
        self.startMs = startMs
        self.sizeBytes = sizeBytes
        self.contentType = contentType
    }

    public var endMs: Int64 { startMs + durationMs }

    /// Files laid end to end from the durations.
    public static func timeline(_ files: [(id: String, title: String?, durationMs: Int64, sizeBytes: Int64?, contentType: String?)]) -> [BookFile] {
        var start: Int64 = 0
        return files.map { f in
            defer { start += f.durationMs }
            return BookFile(id: f.id, title: f.title, durationMs: f.durationMs, startMs: start, sizeBytes: f.sizeBytes, contentType: f.contentType)
        }
    }
}

public struct Chapter: Sendable, Equatable, Identifiable {
    public let title: String
    public let startMs: Int64
    public let endMs: Int64

    public init(title: String, startMs: Int64, endMs: Int64) {
        self.title = title
        self.startMs = startMs
        self.endMs = endMs
    }

    public var id: Int64 { startMs }
    public var durationMs: Int64 { endMs - startMs }
}

public enum Visibility: String, Sendable, Codable {
    case `private`, family
}

public struct Book: Sendable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var subtitle: String?
    public var authors: [Person]
    public var narrators: [Person]
    public var series: [SeriesRef]
    public var description: String?
    public var durationMs: Int64
    public var addedAt: Date
    public var publishedYear: String?
    public var publisher: String?
    public var genres: [String]
    public var language: String?
    public var coverURL: URL?
    /// Only from the detail (and own.audio's feed): nil means not loaded, [] none.
    public var files: [BookFile]?
    public var chapters: [Chapter]?
    /// own.audio: whose it is and who sees it.
    public var ownerId: String?
    public var visibility: Visibility?
    public var isMissing = false

    public init(
        id: String, title: String, subtitle: String? = nil, authors: [Person] = [], narrators: [Person] = [], series: [SeriesRef] = [],
        description: String? = nil, durationMs: Int64, addedAt: Date, publishedYear: String? = nil, publisher: String? = nil,
        genres: [String] = [], language: String? = nil, coverURL: URL? = nil, files: [BookFile]? = nil, chapters: [Chapter]? = nil,
        ownerId: String? = nil, visibility: Visibility? = nil, isMissing: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.authors = authors
        self.narrators = narrators
        self.series = series
        self.description = description
        self.durationMs = durationMs
        self.addedAt = addedAt
        self.publishedYear = publishedYear
        self.publisher = publisher
        self.genres = genres
        self.language = language
        self.coverURL = coverURL
        self.files = files
        self.chapters = chapters
        self.ownerId = ownerId
        self.visibility = visibility
        self.isMissing = isMissing
    }

    public var authorLine: String { authors.map(\.name).joined(separator: ", ") }
    public var narratorLine: String { narrators.map(\.name).joined(separator: ", ") }

    /// The file playing at `positionMs` and the offset in it; the last file when past the end.
    public func file(at positionMs: Int64) -> (file: BookFile, offsetMs: Int64)? {
        guard let files, !files.isEmpty else { return nil }
        let file = files.last { $0.startMs <= positionMs } ?? files[0]
        return (file, max(0, min(positionMs - file.startMs, file.durationMs)))
    }

    /// Book time of an offset in a file.
    public func position(fileId: String, offsetMs: Int64) -> Int64? {
        files?.first { $0.id == fileId }.map { $0.startMs + offsetMs }
    }
}

/// Where one listener is in one book.
public struct ListeningProgress: Sendable, Equatable {
    public var positionMs: Int64
    public var finished: Bool
    public var updatedAt: Date
    /// Where other devices left off, where the server keeps that (own.audio).
    public var devices: [DevicePosition]

    public init(positionMs: Int64, finished: Bool, updatedAt: Date, devices: [DevicePosition] = []) {
        self.positionMs = positionMs
        self.finished = finished
        self.updatedAt = updatedAt
        self.devices = devices
    }
}

public struct DevicePosition: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String?
    public let kind: String
    public let positionMs: Int64
    public let finished: Bool
    public let at: Date
    public let isThisDevice: Bool

    public init(id: String, name: String?, kind: String, positionMs: Int64, finished: Bool, at: Date, isThisDevice: Bool) {
        self.id = id
        self.name = name
        self.kind = kind
        self.positionMs = positionMs
        self.finished = finished
        self.at = at
        self.isThisDevice = isThisDevice
    }
}

public struct Bookmark: Sendable, Equatable, Identifiable {
    /// own.audio's id; Audiobookshelf keys bookmarks by time, so the time in seconds.
    public let id: String
    public let bookId: String
    public let positionMs: Int64
    public var label: String?
    public let createdAt: Date

    public init(id: String, bookId: String, positionMs: Int64, label: String?, createdAt: Date) {
        self.id = id
        self.bookId = bookId
        self.positionMs = positionMs
        self.label = label
        self.createdAt = createdAt
    }
}

public struct SeriesSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public var bookCount: Int
    /// In series order, when loaded.
    public var books: [Book]?

    public init(id: String, name: String, bookCount: Int, books: [Book]? = nil) {
        self.id = id
        self.name = name
        self.bookCount = bookCount
        self.books = books
    }
}

public struct Collection: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    public let books: [Book]

    public init(id: String, name: String, description: String?, books: [Book]) {
        self.id = id
        self.name = name
        self.description = description
        self.books = books
    }
}

/// A row of the home screen.
public struct Shelf: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case books([Book])
        case series([SeriesSummary])
        case authors([Person])
    }
    /// `continue-listening`, `recently-added`, `continue-series`, `listen-again`, `discover`…
    public let id: String
    public let title: String
    public let kind: Kind

    public init(id: String, title: String, kind: Kind) {
        self.id = id
        self.title = title
        self.kind = kind
    }

    public var isEmpty: Bool {
        switch kind {
        case .books(let b): b.isEmpty
        case .series(let s): s.isEmpty
        case .authors(let a): a.isEmpty
        }
    }
}

public enum BookSort: String, Sendable, CaseIterable, Codable {
    case title, author, added, duration
}

public enum BookFilter: String, Sendable, CaseIterable, Codable {
    case all, notStarted, inProgress, finished
}

/// What to list: a filter, and at most one of author, narrator or series.
public struct BookQuery: Sendable, Equatable {
    public var sort: BookSort = .title
    public var descending = false
    public var filter: BookFilter = .all
    public var authorId: String?
    public var narratorId: String?
    public var seriesId: String?
    public var text: String?

    public init(sort: BookSort = .title, descending: Bool = false, filter: BookFilter = .all, authorId: String? = nil, narratorId: String? = nil, seriesId: String? = nil, text: String? = nil) {
        self.sort = sort
        self.descending = descending
        self.filter = filter
        self.authorId = authorId
        self.narratorId = narratorId
        self.seriesId = seriesId
        self.text = text
    }
}

public struct BooksPage: Sendable, Equatable {
    public let books: [Book]
    /// Opaque; nil on the last page.
    public let next: String?
    public let total: Int?

    public init(books: [Book], next: String?, total: Int?) {
        self.books = books
        self.next = next
        self.total = total
    }
}

public struct SearchResult: Sendable, Equatable {
    public var books: [Book] = []
    public var authors: [Person] = []
    public var narrators: [Person] = []
    public var series: [SeriesSummary] = []

    public init(books: [Book] = [], authors: [Person] = [], narrators: [Person] = [], series: [SeriesSummary] = []) {
        self.books = books
        self.authors = authors
        self.narrators = narrators
        self.series = series
    }
}

/// How to play a book right now: one part per file (or one HLS playlist), with links that
/// expire; `sessionId` is the server's play session where it keeps one.
public struct PlayPlan: Sendable, Equatable {
    public struct Part: Sendable, Equatable, Identifiable {
        public let fileId: String
        public let url: URL
        public let startMs: Int64
        public let durationMs: Int64
        public let contentType: String?
        public let isHLS: Bool
        public var id: String { fileId }

        public init(fileId: String, url: URL, startMs: Int64, durationMs: Int64, contentType: String?, isHLS: Bool) {
            self.fileId = fileId
            self.url = url
            self.startMs = startMs
            self.durationMs = durationMs
            self.contentType = contentType
            self.isHLS = isHLS
        }
    }
    public let bookId: String
    public let parts: [Part]
    public let sessionId: String?
    public let expiresAt: Date?
    /// Where the server says the listener is, for sessions that carry it.
    public let startPositionMs: Int64?

    public init(bookId: String, parts: [Part], sessionId: String?, expiresAt: Date?, startPositionMs: Int64?) {
        self.bookId = bookId
        self.parts = parts
        self.sessionId = sessionId
        self.expiresAt = expiresAt
        self.startPositionMs = startPositionMs
    }
}

/// What the player tells the server while and after playing.
public struct PlaybackReport: Sendable, Equatable {
    public let bookId: String
    public let sessionId: String?
    public let positionMs: Int64
    /// Milliseconds listened since the last report.
    public let listenedMs: Int64
    public let durationMs: Int64
    public let finished: Bool
    /// The device's clock when the position was reached.
    public let at: Date
    /// The last report of this session.
    public let closes: Bool

    public init(bookId: String, sessionId: String?, positionMs: Int64, listenedMs: Int64, durationMs: Int64, finished: Bool, at: Date = Date(), closes: Bool = false) {
        self.bookId = bookId
        self.sessionId = sessionId
        self.positionMs = positionMs
        self.listenedMs = listenedMs
        self.durationMs = durationMs
        self.finished = finished
        self.at = at
        self.closes = closes
    }
}

public enum ConnectionStatus: Equatable, Sendable {
    case ok
    /// Reachable, but the sign-in is refused.
    case rejected
    case unreachable
}

/// The errors screens show, whatever the server.
public enum SourceError: Error, Sendable, Equatable {
    case signInRejected
    case notAllowed
    case notFound
    case http(Int)
    /// The answer couldn't be read; the message says whose protocol was expected.
    case unreadable
    case network
    /// Offline, and this wasn't saved from an earlier visit.
    case offline
    /// The server doesn't have this feature.
    case unsupported
    /// The server's own message.
    case server(String)
}
