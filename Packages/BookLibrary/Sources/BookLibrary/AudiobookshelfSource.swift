import AudiobookshelfKit
import Foundation

/// An Audiobookshelf server, one book library of it. Lists come from the server page by page;
/// progress and bookmarks are the account's, read from `/api/me`; playing goes through a play
/// session so the server's listening statistics count it.
public struct AudiobookshelfSource: BookSource {
    public let client: AudiobookshelfClient
    public let libraryId: String
    public let userId: String?
    let device: DeviceIdentity

    public init(client: AudiobookshelfClient, libraryId: String, userId: String?, device: DeviceIdentity) {
        self.client = client
        self.libraryId = libraryId
        self.userId = userId
        self.device = device
    }

    public var capabilities: Capabilities { [.series, .collections, .serverSearch, .lowerBitrate] }

    public func checkConnection() async -> ConnectionStatus {
        guard await client.tokens.current != nil else { return .rejected }
        do {
            _ = try await client.authorize()
            return .ok
        } catch AudiobookshelfError.signedOut, AudiobookshelfError.http(401, _), AudiobookshelfError.http(403, _) {
            return .rejected
        } catch {
            return .unreachable
        }
    }

    // MARK: - Browsing

    public func shelves() async throws -> [Shelf] {
        try await translating {
            try await client.personalized(libraryId: libraryId).compactMap { shelf -> Shelf? in
                switch shelf.type {
                case "book": return Shelf(id: shelf.id, title: shelf.label, kind: .books(shelf.books.map(book)))
                case "series": return Shelf(id: shelf.id, title: shelf.label, kind: .series(shelf.series.map(summary)))
                case "authors": return Shelf(id: shelf.id, title: shelf.label, kind: .authors(shelf.authors.map(person)))
                default: return nil
                }
            }
        }
    }

    public func books(_ query: BookQuery, cursor: String?, limit: Int) async throws -> BooksPage {
        try await translating {
            if let text = query.text, !text.isEmpty {
                // The server's filter has no text; its search does, one page.
                let hits = try await client.search(libraryId: libraryId, text, limit: limit).book.map { book($0.libraryItem) }
                return BooksPage(books: hits, next: nil, total: hits.count)
            }
            let page = Int(cursor ?? "0") ?? 0
            let filter: AudiobookshelfClient.ItemFilter?
            if let id = query.seriesId { filter = .series(id: id) }
            else if let id = query.authorId { filter = .author(id: id) }
            else if let name = query.narratorId { filter = .narrator(name: name) }
            else {
                switch query.filter {
                case .all: filter = nil
                case .notStarted: filter = .progress(.notStarted)
                case .inProgress: filter = .progress(.inProgress)
                case .finished: filter = .progress(.finished)
                }
            }
            let sort: AudiobookshelfClient.ItemSort
            if query.seriesId != nil { sort = .sequence }
            else {
                switch query.sort {
                case .title: sort = .title
                case .author: sort = .author
                case .added: sort = .added
                case .duration: sort = .duration
                }
            }
            let answer = try await client.items(libraryId: libraryId, page: page, limit: limit, sort: sort, descending: query.descending, filter: filter)
            return BooksPage(books: answer.results.map(book), next: answer.hasMore ? String(page + 1) : nil, total: answer.total)
        }
    }

    public func book(id: String) async throws -> Book {
        try await translating { book(try await client.item(id: id)) }
    }

    public func authors() async throws -> [Person] {
        try await translating { try await client.authors(libraryId: libraryId).map(person) }
    }

    /// Narrators have no ids on the server; the name is the id, and what the filter takes.
    public func narrators() async throws -> [Person] {
        try await translating { try await client.narrators(libraryId: libraryId).map { Person(id: $0.name, name: Mojibake.repair($0.name), bookCount: $0.numBooks) } }
    }

    public func series() async throws -> [SeriesSummary] {
        try await translating {
            var out: [SeriesSummary] = []
            var page = 0
            while true {
                let answer = try await client.series(libraryId: libraryId, page: page, limit: 200)
                out += answer.results.map(summary)
                guard answer.hasMore, !answer.results.isEmpty else { return out }
                page += 1
            }
        }
    }

    /// The series' record has no books; they are the items filtered by it, in series order.
    public func series(id: String) async throws -> SeriesSummary {
        try await translating {
            let series = try await client.series(id: id)
            let books = try await client.allItems(libraryId: libraryId, sort: .sequence, filter: .series(id: id)).map(book)
            return SeriesSummary(id: series.id, name: Mojibake.repair(series.name), bookCount: books.count, books: books)
        }
    }

    public func collections() async throws -> [Collection] {
        try await translating {
            try await client.collections(libraryId: libraryId).map {
                Collection(id: $0.id, name: Mojibake.repair($0.name), description: $0.description, books: $0.books.map(book))
            }
        }
    }

    public func search(_ text: String) async throws -> SearchResult {
        try await translating {
            let answer = try await client.search(libraryId: libraryId, text)
            return SearchResult(
                books: answer.book.map { book($0.libraryItem) },
                authors: answer.authors.map(person),
                narrators: answer.narrators.map { Person(id: $0.name, name: Mojibake.repair($0.name), bookCount: $0.numBooks) },
                series: answer.series.map { SeriesSummary(id: $0.series.id, name: Mojibake.repair($0.series.name), bookCount: $0.books.count, books: $0.books.map(book)) }
            )
        }
    }

    // MARK: - The listener's state

    public func progress(bookId: String) async throws -> ListeningProgress? {
        try await translating { try await client.progress(itemId: bookId).map(Self.progress) }
    }

    public func allProgress() async throws -> [String: ListeningProgress] {
        try await translating {
            var out: [String: ListeningProgress] = [:]
            for p in try await client.me().mediaProgress where p.episodeId == nil {
                out[p.libraryItemId] = Self.progress(p)
            }
            return out
        }
    }

    public func saveProgress(bookId: String, positionMs: Int64, durationMs: Int64, finished: Bool, at: Date) async throws -> ListeningProgress {
        try await translating {
            try await client.updateProgress(itemId: bookId, .init(currentTime: Double(positionMs) / 1000, duration: Double(durationMs) / 1000, isFinished: finished))
            return ListeningProgress(positionMs: positionMs, finished: finished, updatedAt: at)
        }
    }

    public func clearProgress(bookId: String) async throws {
        try await translating {
            guard let current = try await client.progress(itemId: bookId) else { return }
            try await client.deleteProgress(progressId: current.id)
        }
    }

    public func bookmarks(bookId: String) async throws -> [Bookmark] {
        try await translating {
            try await client.me().bookmarks.filter { $0.libraryItemId == bookId }.map(Self.bookmark).sorted { $0.positionMs < $1.positionMs }
        }
    }

    public func addBookmark(bookId: String, positionMs: Int64, label: String?) async throws -> Bookmark {
        try await translating { Self.bookmark(try await client.createBookmark(itemId: bookId, time: Double(positionMs) / 1000, title: label ?? "")) }
    }

    public func renameBookmark(_ bookmark: Bookmark, label: String?) async throws -> Bookmark {
        try await translating { Self.bookmark(try await client.updateBookmark(itemId: bookmark.bookId, time: Double(bookmark.positionMs) / 1000, title: label ?? "")) }
    }

    public func deleteBookmark(_ bookmark: Bookmark) async throws {
        try await translating { try await client.deleteBookmark(itemId: bookmark.bookId, time: Double(bookmark.positionMs) / 1000) }
    }

    public func favourites() async throws -> Set<String> { [] }

    public func setFavourite(bookId: String, _ on: Bool) async throws {
        throw SourceError.unsupported
    }

    // MARK: - Playing

    /// A play session: one part per file, or one HLS playlist when a smaller stream was asked
    /// for (the server transcodes to HLS, which AVPlayer plays). A new session for the same
    /// book closes the open one, so the caller keeps one plan per book.
    public func playPlan(for book: Book, maxBitrateKbps: Int?) async throws -> PlayPlan {
        try await translating {
            let session = try await client.play(itemId: book.id, device: device.audiobookshelf, forceTranscode: maxBitrateKbps != nil)
            let token = try await client.freshToken()
            let parts = session.audioTracks.map { track in
                PlayPlan.Part(
                    fileId: Self.fileId(track), url: client.mediaURL(contentUrl: track.contentUrl, token: token),
                    startMs: Self.ms(track.startOffset), durationMs: Self.ms(track.duration), contentType: track.mimeType, isHLS: session.isHLS
                )
            }
            return PlayPlan(bookId: book.id, parts: parts, sessionId: session.id, expiresAt: await client.tokens.current?.expiresAt, startPositionMs: Self.ms(session.currentTime))
        }
    }

    public func report(_ report: PlaybackReport) async throws -> ListeningProgress? {
        try await translating {
            let seconds = Double(report.positionMs) / 1000
            if let sessionId = report.sessionId {
                if report.closes {
                    try await client.closeSession(id: sessionId, currentTime: seconds, timeListened: Double(report.listenedMs) / 1000, duration: Double(report.durationMs) / 1000)
                } else {
                    try await client.syncSession(id: sessionId, currentTime: seconds, timeListened: Double(report.listenedMs) / 1000, duration: Double(report.durationMs) / 1000)
                }
                if report.finished {
                    try await client.updateProgress(itemId: report.bookId, .init(currentTime: seconds, duration: Double(report.durationMs) / 1000, isFinished: true))
                }
            } else {
                try await client.updateProgress(itemId: report.bookId, .init(currentTime: seconds, duration: Double(report.durationMs) / 1000, isFinished: report.finished))
            }
            return ListeningProgress(positionMs: report.positionMs, finished: report.finished, updatedAt: report.at)
        }
    }

    /// The original file with a fresh token; an HLS part needs a new plan instead.
    public func partURL(for book: Book, fileId: String, startMs: Int64?, maxBitrateKbps: Int?) async throws -> PlayPlan.Part {
        guard maxBitrateKbps == nil, let file = book.files?.first(where: { $0.id == fileId }) else { throw SourceError.unsupported }
        return try await translating {
            let token = try await client.freshToken()
            return PlayPlan.Part(fileId: fileId, url: client.fileURL(itemId: book.id, ino: fileId, token: token), startMs: file.startMs, durationMs: file.durationMs, contentType: file.contentType, isHLS: false)
        }
    }

    public func signOut() async {
        await client.signOut()
    }

    // MARK: - From the server's records to the app's

    func book(_ item: LibraryItem) -> Book {
        let m = item.media.metadata
        let authors: [Person] = m.authors?.map(person)
            ?? Self.names(m.authorName).map { Person(id: $0, name: $0) }
        let narrators: [Person] = (m.narrators ?? Self.names(m.narratorName)).map { Person(id: $0, name: Mojibake.repair($0)) }
        let series: [SeriesRef] = m.series?.map { SeriesRef(id: $0.id, name: Mojibake.repair($0.name), sequence: $0.sequence) }
            ?? Self.seriesRefs(m.seriesName)
        let files = item.media.tracks.map { tracks in
            tracks.map { BookFile(id: Self.fileId($0), title: Mojibake.repair($0.title), durationMs: Self.ms($0.duration), startMs: Self.ms($0.startOffset), sizeBytes: nil, contentType: $0.mimeType) }
        }
        let chapters = item.media.chapters.map { chapters in
            chapters.map { Chapter(title: Mojibake.repair($0.title), startMs: Self.ms($0.start), endMs: Self.ms($0.end)) }
        }
        return Book(
            id: item.id, title: Mojibake.repair(m.title ?? "Untitled"), subtitle: Mojibake.repair(m.subtitle), authors: authors, narrators: narrators,
            series: series, description: m.description, durationMs: Self.ms(item.media.duration), addedAt: Date(timeIntervalSince1970: Double(item.addedAt) / 1000),
            publishedYear: m.publishedYear, publisher: m.publisher, genres: m.genres, language: m.language,
            coverURL: item.media.coverPath == nil ? nil : client.coverURL(itemId: item.id, width: 600),
            files: files, chapters: chapters, isMissing: item.isMissing
        )
    }

    func person(_ author: Author) -> Person {
        Person(id: author.id, name: Mojibake.repair(author.name), bookCount: author.numBooks)
    }

    func summary(_ series: Series) -> SeriesSummary {
        let books = series.books.map(book).sorted { ($0.series.first?.position ?? 0, $0.title) < ($1.series.first?.position ?? 0, $1.title) }
        return SeriesSummary(id: series.id, name: Mojibake.repair(series.name), bookCount: books.count, books: books)
    }

    static func progress(_ p: MediaProgress) -> ListeningProgress {
        ListeningProgress(positionMs: ms(p.currentTime), finished: p.isFinished, updatedAt: p.updatedAt)
    }

    static func bookmark(_ b: AudiobookshelfKit.Bookmark) -> Bookmark {
        Bookmark(id: Self.timeKey(b.time), bookId: b.libraryItemId, positionMs: ms(b.time), label: b.title.isEmpty ? nil : Mojibake.repair(b.title), createdAt: Date(timeIntervalSince1970: Double(b.createdAt) / 1000))
    }

    static func timeKey(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? String(Int64(seconds)) : String(seconds)
    }

    static func fileId(_ track: AudioTrack) -> String {
        track.ino ?? String(track.index)
    }

    static func ms(_ seconds: Double) -> Int64 {
        Int64((seconds * 1000).rounded())
    }

    /// "A, B" on a list row; the detail has the records.
    static func names(_ joined: String?) -> [String] {
        guard let joined, !joined.isEmpty else { return [] }
        return joined.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A list row's "Name #1, Other #2": the name is the only id the row has.
    static func seriesRefs(_ seriesName: String?) -> [SeriesRef] {
        guard let seriesName, !seriesName.isEmpty else { return [] }
        return seriesName.split(separator: ",").map { entry in
            let text = entry.trimmingCharacters(in: .whitespaces)
            if let hash = text.range(of: " #", options: .backwards) {
                let name = String(text[..<hash.lowerBound])
                return SeriesRef(id: name, name: Mojibake.repair(name), sequence: String(text[hash.upperBound...]))
            }
            return SeriesRef(id: text, name: Mojibake.repair(text), sequence: nil)
        }
    }

    func translating<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as AudiobookshelfError {
            throw Self.sourceError(error)
        }
    }

    static func sourceError(_ error: AudiobookshelfError) -> SourceError {
        switch error {
        case .invalidCredentials, .signedOut: .signInRejected
        case .http(401, _): .signInRejected
        case .http(403, _): .notAllowed
        case .http(404, _): .notFound
        case .http(let status, let message): message.map { .server($0) } ?? .http(status)
        case .decoding: .unreadable
        case .network: .network
        case .offline: .offline
        }
    }
}
