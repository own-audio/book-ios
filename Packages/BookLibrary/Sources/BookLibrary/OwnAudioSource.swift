import Foundation
import OwnAudioKit

/// An own.audio server through its own API (`/api/v2`): the library on the phone from its
/// snapshot and change feed (books with their files, chapters and series, the contributors,
/// the listener's progress, bookmarks and favourites), browsing and search over that copy,
/// per-device positions, and — signed per file — streams and covers.
public struct OwnAudioSource: BookSource, ChangeFeedCatalogue, LiveLibraryUpdates, BookUploader {
    public let client: OwnAudioClient
    public let userId: String?
    let device: DeviceIdentity
    let catalogue: OwnAudioCatalogue

    public init(client: OwnAudioClient, userId: String?, device: DeviceIdentity, catalogue: OwnAudioCatalogue = OwnAudioCatalogue()) {
        self.client = client
        self.userId = userId
        self.device = device
        self.catalogue = catalogue
    }

    public var capabilities: Capabilities { [.favourites, .perDevicePositions, .familySharing, .upload, .liveUpdates, .changeFeed, .lowerBitrate, .narratorIds] }

    public func checkConnection() async -> ConnectionStatus {
        guard await client.tokens.current != nil else { return .rejected }
        do {
            _ = try await client.me()
            return .ok
        } catch OwnAudioError.signedOut {
            return .rejected
        } catch OwnAudioError.problem(let p) where p.status == 401 {
            return .rejected
        } catch {
            return .unreachable
        }
    }

    // MARK: - Browsing, from the copy on the phone

    public func shelves() async throws -> [Shelf] {
        let library = try await synced()
        let byId = Dictionary(uniqueKeysWithValues: library.books.map { ($0.id, $0) })
        let started = library.progress.sorted { $0.value.updatedAt > $1.value.updatedAt }
        let continueListening = started.filter { !$0.value.finished }.compactMap { byId[$0.key] }
        let listenAgain = started.filter { $0.value.finished }.compactMap { byId[$0.key] }
        let recent = library.books.sorted { $0.addedAt > $1.addedAt }.prefix(10)
        return [
            Shelf(id: "continue-listening", title: "Continue Listening", kind: .books(Array(continueListening.prefix(10)))),
            Shelf(id: "recently-added", title: "Recently Added", kind: .books(Array(recent))),
            Shelf(id: "listen-again", title: "Listen Again", kind: .books(Array(listenAgain.prefix(10)))),
        ].filter { !$0.isEmpty }
    }

    public func books(_ query: BookQuery, cursor: String?, limit: Int) async throws -> BooksPage {
        let library = try await synced()
        var books = library.books
        if let id = query.authorId { books = books.filter { $0.authors.contains { $0.id == id } } }
        if let id = query.narratorId { books = books.filter { $0.narrators.contains { $0.id == id } } }
        if let id = query.seriesId { books = books.filter { $0.series.contains { $0.id == id } } }
        if let text = query.text?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            books = books.filter { Self.matches($0, text) }
        }
        switch query.filter {
        case .all: break
        case .notStarted: books = books.filter { library.progress[$0.id] == nil }
        case .inProgress: books = books.filter { library.progress[$0.id].map { !$0.finished } ?? false }
        case .finished: books = books.filter { library.progress[$0.id]?.finished ?? false }
        case .favourites: books = books.filter { library.favourites.contains($0.id) }
        }
        if let id = query.seriesId {
            books.sort { ($0.series.first { $0.id == id }?.position ?? 0, $0.title) < ($1.series.first { $0.id == id }?.position ?? 0, $1.title) }
        } else {
            books.sort { a, b in
                let less: Bool
                switch query.sort {
                case .title: less = a.title.localizedStandardCompare(b.title) == .orderedAscending
                case .author:
                    let byAuthor = a.authorLine.localizedStandardCompare(b.authorLine)
                    less = byAuthor == .orderedSame ? a.title.localizedStandardCompare(b.title) == .orderedAscending : byAuthor == .orderedAscending
                case .added: less = a.addedAt < b.addedAt
                case .duration: less = a.durationMs < b.durationMs
                }
                return query.descending ? !less && (a.id != b.id) : less
            }
        }
        let offset = Int(cursor ?? "0") ?? 0
        let page = Array(books.dropFirst(offset).prefix(limit))
        let next = offset + limit < books.count ? String(offset + limit) : nil
        return BooksPage(books: page, next: next, total: books.count)
    }

    public func book(id: String) async throws -> Book {
        if let book = try await synced().books.first(where: { $0.id == id }) { return book }
        return try await translating {
            let answer = try await client.book(id: id)
            let contributors = Dictionary(uniqueKeysWithValues: (answer.included?.contributors ?? []).map { ($0.id, $0) })
            return Self.book(answer.record, contributors: contributors)
        }
    }

    /// Straight from the server: a record from the synced snapshot keeps the image link it was
    /// sent with, and that link is signed for a week or two and built for the address the
    /// server had then (a home address, say, before it got a public one).
    public func currentCoverURL(bookId: String) async -> URL? {
        try? await translating {
            let answer = try await client.book(id: bookId)
            return answer.record.image.flatMap { Self.image($0, width: 600) }
        }
    }

    public func authors() async throws -> [Person] {
        try await synced().authors
    }

    public func narrators() async throws -> [Person] {
        try await synced().narrators
    }

    public func series() async throws -> [SeriesSummary] {
        Self.series(of: try await synced().books)
    }

    public func series(id: String) async throws -> SeriesSummary {
        guard let found = Self.series(of: try await synced().books).first(where: { $0.id == id }) else { throw SourceError.notFound }
        return found
    }

    /// The server has none yet.
    public func collections() async throws -> [Collection] { [] }

    public func search(_ text: String) async throws -> SearchResult {
        let library = try await synced()
        let needle = text.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return SearchResult() }
        return SearchResult(
            books: library.books.filter { Self.matches($0, needle) },
            authors: library.authors.filter { $0.name.localizedCaseInsensitiveContains(needle) },
            narrators: library.narrators.filter { $0.name.localizedCaseInsensitiveContains(needle) },
            series: Self.series(of: library.books).filter { $0.name.localizedCaseInsensitiveContains(needle) }
        )
    }

    // MARK: - The listener's state

    /// From the server, with every device's position; the copy on the phone when it can't be reached.
    public func progress(bookId: String) async throws -> ListeningProgress? {
        do {
            return try await client.progress(.book, id: bookId).map(Self.progress)
        } catch OwnAudioError.network, OwnAudioError.offline {
            return try await synced().progress[bookId]
        } catch let error as OwnAudioError {
            throw Self.sourceError(error)
        }
    }

    public func allProgress() async throws -> [String: ListeningProgress] {
        try await synced().progress
    }

    public func saveProgress(bookId: String, positionMs: Int64, durationMs: Int64, finished: Bool, at: Date) async throws -> ListeningProgress {
        try await translating {
            let answer = try await client.saveProgress(.book, id: bookId, positionMs: positionMs, finished: finished, at: at)
            let progress = Self.progress(answer.progress)
            catalogue.remember(progress: progress, bookId: bookId)
            return progress
        }
    }

    public func clearProgress(bookId: String) async throws {
        try await translating {
            try await client.deleteProgress(.book, id: bookId)
            catalogue.remember(progress: nil, bookId: bookId)
        }
    }

    public func bookmarks(bookId: String) async throws -> [Bookmark] {
        do {
            return try await client.all { try await client.bookmarks(.book, itemId: bookId, cursor: $0) }.map(Self.bookmark).sorted { $0.positionMs < $1.positionMs }
        } catch OwnAudioError.network, OwnAudioError.offline {
            return try await synced().bookmarks.filter { $0.bookId == bookId }
        } catch let error as OwnAudioError {
            throw Self.sourceError(error)
        }
    }

    public func addBookmark(bookId: String, positionMs: Int64, label: String?) async throws -> Bookmark {
        try await translating { Self.bookmark(try await client.createBookmark(.book, itemId: bookId, positionMs: positionMs, label: label)) }
    }

    public func renameBookmark(_ bookmark: Bookmark, label: String?) async throws -> Bookmark {
        try await translating { Self.bookmark(try await client.updateBookmark(id: bookmark.id, label: .some(label))) }
    }

    public func deleteBookmark(_ bookmark: Bookmark) async throws {
        try await translating { try await client.deleteBookmark(id: bookmark.id) }
    }

    public func favourites() async throws -> Set<String> {
        do {
            return Set(try await client.all { try await client.favourites(.book, cursor: $0) }.map(\.id))
        } catch OwnAudioError.network, OwnAudioError.offline {
            return try await synced().favourites
        } catch let error as OwnAudioError {
            throw Self.sourceError(error)
        }
    }

    public func setFavourite(bookId: String, _ on: Bool) async throws {
        try await translating {
            try await client.setFavourite(.book, id: bookId, on)
            catalogue.remember(favourite: on, bookId: bookId)
        }
    }

    // MARK: - Playing

    /// One signed link per file, asked for at once; links last hours and are renewed with
    /// `partURL` when they run out.
    public func playPlan(for book: Book, maxBitrateKbps: Int?) async throws -> PlayPlan {
        let book = book.files == nil ? try await self.book(id: book.id) : book
        guard let files = book.files, !files.isEmpty else { throw SourceError.notFound }
        return try await translating {
            let infos = try await withThrowingTaskGroup(of: (Int, PlaybackInfo).self) { group in
                for (index, file) in files.enumerated() {
                    group.addTask { (index, try await client.playbackInfo(kind: "book_file", id: file.id, capabilities: Self.capabilities(maxBitrateKbps))) }
                }
                var out = [PlaybackInfo?](repeating: nil, count: files.count)
                for try await (index, info) in group { out[index] = info }
                return out.compactMap { $0 }
            }
            let parts = zip(files, infos).map { file, info in
                PlayPlan.Part(fileId: file.id, url: info.url, startMs: file.startMs, durationMs: file.durationMs, contentType: info.contentType ?? file.contentType, isHLS: false)
            }
            return PlayPlan(bookId: book.id, parts: parts, sessionId: nil, expiresAt: infos.map(\.expiresAt).min(), startPositionMs: nil)
        }
    }

    public func report(_ report: PlaybackReport) async throws -> ListeningProgress? {
        try await saveProgress(bookId: report.bookId, positionMs: report.positionMs, durationMs: report.durationMs, finished: report.finished, at: report.at)
    }

    public func partURL(for book: Book, fileId: String, startMs: Int64?, maxBitrateKbps: Int?) async throws -> PlayPlan.Part {
        guard let file = book.files?.first(where: { $0.id == fileId }) else { throw SourceError.notFound }
        return try await translating {
            let info = try await client.playbackInfo(kind: "book_file", id: fileId, capabilities: Self.capabilities(maxBitrateKbps), startMs: startMs.map { $0 - file.startMs })
            return PlayPlan.Part(fileId: fileId, url: info.url, startMs: file.startMs, durationMs: file.durationMs, contentType: info.contentType ?? file.contentType, isHLS: false)
        }
    }

    static func capabilities(_ maxBitrateKbps: Int?) -> PlaybackCapabilities {
        PlaybackCapabilities(
            direct: ["audio/mpeg", "audio/mp4", "audio/x-m4a", "audio/x-m4b", "audio/aac", "audio/flac", "audio/wav", "audio/x-wav", "audio/aiff"],
            transcode: ["aac", "mp3"], maxBitrateKbps: maxBitrateKbps
        )
    }

    public func signOut() async {
        await client.signOut()
    }

    // MARK: - The library on the phone

    /// What the snapshot holds for a book library.
    static let snapshotKinds = ["contributor", "book", "favourite", "progress", "bookmark"]

    static func keeps(_ kind: String) -> Bool {
        kind == "contributor" || kind == "book" || kind == "bookmark" || kind == "favourite.book" || kind == "progress.book"
    }

    /// The library, synced first when nothing was loaded yet.
    func synced() async throws -> OwnAudioCatalogue.Library {
        if let library = catalogue.library { return library }
        _ = try await syncCatalogue(catalogue.state)
        guard let library = catalogue.library else { throw SourceError.unreadable }
        return library
    }

    public func syncCatalogue(_ state: FeedState?) async throws -> FeedResult {
        guard await client.tokens.current != nil else { throw SourceError.signInRejected }
        do {
            var updated: FeedState
            if let state, let changed = try await changes(since: state) {
                updated = changed
            } else {
                updated = try await snapshot()
            }
            updated.syncedAt = Date()
            let library = Self.library(updated)
            catalogue.load(updated, library: library)
            return FeedResult(state: updated, books: library.books, authors: library.authors, narrators: library.narrators, progress: library.progress, bookmarks: library.bookmarks, favourites: library.favourites)
        } catch let error as OwnAudioError {
            throw Self.sourceError(error)
        }
    }

    /// The state with the changes applied, or nil when a fresh snapshot is needed.
    private func changes(since state: FeedState) async throws -> FeedState? {
        var records = state.records
        var cursor = state.cursor
        while true {
            let page: ChangesAnswer
            do {
                page = try await client.changes(since: cursor)
            } catch OwnAudioError.problem(let p) where p.code == "sync_cursor_expired" || p.code == "invalid_cursor" {
                return nil
            }
            if page.reset { return nil }
            for change in page.changes where Self.keeps(change.kind) {
                if change.op == "upsert", let record = change.record, let data = try? JSONEncoder().encode(record) {
                    records[change.kind, default: [:]][change.id] = data
                } else {
                    records[change.kind]?[change.id] = nil
                }
            }
            cursor = page.cursor
            if !page.hasMore { break }
        }
        return FeedState(cursor: cursor, records: records)
    }

    private func snapshot() async throws -> FeedState {
        var records: [String: [String: Data]] = [:]
        var begin: String?
        var end: String?
        try await client.snapshot(kinds: Self.snapshotKinds) { line in
            switch line {
            case .begin(let cursor): begin = cursor
            case .record(let kind, let id, let record):
                if Self.keeps(kind), let data = try? JSONEncoder().encode(record) { records[kind, default: [:]][id] = data }
            case .end(let cursor): end = cursor
            }
        }
        guard let cursor = end ?? begin else { throw SourceError.unreadable }
        return FeedState(cursor: cursor, records: records)
    }

    public func libraryChanges() -> AsyncThrowingStream<Void, Error> {
        let events = client.events()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events where event.type == "library" {
                        continuation.yield()
                    }
                    continuation.finish()
                } catch let error as OwnAudioError {
                    continuation.finish(throwing: Self.sourceError(error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - From the API's records to the app's

    static func library(_ state: FeedState) -> OwnAudioCatalogue.Library {
        func decoded<T: Decodable>(_ kind: String, _ type: T.Type) -> [String: T] {
            var out: [String: T] = [:]
            for (id, data) in state.records[kind] ?? [:] {
                if let value = try? JSONDecoder.ownAudio.decode(T.self, from: data) { out[id] = value }
            }
            return out
        }
        let contributors = decoded("contributor", OwnAudioKit.Contributor.self)
        let books = decoded("book", OwnAudioKit.Book.self).values.map { book($0, contributors: contributors) }
        var progress: [String: ListeningProgress] = [:]
        for p in decoded("progress.book", OwnAudioKit.Progress.self).values where p.kind == "book" { progress[p.id] = Self.progress(p) }
        let bookmarks = decoded("bookmark", OwnAudioKit.Bookmark.self).values.filter { $0.kind == "book" }.map(bookmark).sorted { $0.positionMs < $1.positionMs }
        let favourites = Set(decoded("favourite.book", OwnAudioKit.Favourite.self).values.filter { $0.kind == "book" }.map(\.id))
        return OwnAudioCatalogue.Library(
            books: books, authors: people(role: "author", in: books, contributors: contributors),
            narrators: people(role: "narrator", in: books, contributors: contributors),
            progress: progress, bookmarks: bookmarks, favourites: favourites
        )
    }

    /// Contributors credited in a role on at least one book, with how many.
    static func people(role: String, in books: [Book], contributors: [String: OwnAudioKit.Contributor]) -> [Person] {
        var counts: [String: Int] = [:]
        for book in books {
            for person in (role == "author" ? book.authors : book.narrators) { counts[person.id, default: 0] += 1 }
        }
        return counts.map { id, count in
            let c = contributors[id]
            return Person(id: id, name: c?.name ?? "", bookCount: count, imageURL: c?.image.flatMap { image($0, width: 256) })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func book(_ b: OwnAudioKit.Book, contributors: [String: OwnAudioKit.Contributor]) -> Book {
        func credited(_ role: String) -> [Person] {
            b.credits.filter { $0.role == role }.sorted { $0.position < $1.position }.map { credit in
                let c = contributors[credit.contributorId]
                return Person(id: credit.contributorId, name: credit.creditedAs ?? c?.name ?? "", imageURL: c?.image.flatMap { image($0, width: 256) })
            }
        }
        let files = b.files.map { files in
            BookFile.timeline(files.sorted { $0.position < $1.position }.map { ($0.id, $0.title, $0.durationMs ?? 0, $0.sizeBytes, $0.contentType) })
        }
        let duration = b.durationMs ?? files?.last?.endMs ?? 0
        let chapters = b.chapters.map { marks -> [Chapter] in
            let sorted = marks.sorted { $0.startMs < $1.startMs }
            return sorted.enumerated().map { index, mark in
                let end = index + 1 < sorted.count ? sorted[index + 1].startMs : max(duration, mark.startMs)
                return Chapter(title: mark.title ?? "Chapter \(mark.position + 1)", startMs: mark.startMs, endMs: end)
            }
        }
        return Book(
            id: b.id, title: b.title, authors: credited("author"), narrators: credited("narrator"),
            series: (b.series ?? []).map { SeriesRef(id: $0.seriesId, name: $0.name, sequence: $0.position.map(Self.sequence)) },
            description: b.description, durationMs: duration, addedAt: b.createdAt, publishedYear: b.publishedYear.map(String.init), publisher: b.publisher,
            coverURL: b.image.flatMap { image($0, width: 600) }, files: files, chapters: chapters,
            ownerId: b.ownerId, visibility: Visibility(rawValue: b.visibility)
        )
    }

    static func sequence(_ position: Double) -> String {
        position == position.rounded() ? String(Int64(position)) : String(position)
    }

    static func series(of books: [Book]) -> [SeriesSummary] {
        var byId: [String: (name: String, books: [Book])] = [:]
        for book in books {
            for ref in book.series { byId[ref.id, default: (ref.name, [])].books.append(book) }
        }
        return byId.map { id, entry in
            let ordered = entry.books.sorted { ($0.series.first { $0.id == id }?.position ?? 0, $0.title) < ($1.series.first { $0.id == id }?.position ?? 0, $1.title) }
            return SeriesSummary(id: id, name: entry.name, bookCount: ordered.count, books: ordered)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func progress(_ p: OwnAudioKit.Progress) -> ListeningProgress {
        ListeningProgress(
            positionMs: p.positionMs, finished: p.finished, updatedAt: p.updatedAt,
            devices: (p.devices ?? []).map { DevicePosition(id: $0.deviceId, name: $0.deviceName, kind: $0.deviceKind, positionMs: $0.positionMs, finished: $0.finished, at: $0.at, isThisDevice: $0.current) }
        )
    }

    static func bookmark(_ b: OwnAudioKit.Bookmark) -> Bookmark {
        Bookmark(id: b.id, bookId: b.itemId, positionMs: b.positionMs, label: b.label, createdAt: b.createdAt)
    }

    /// A signed image link at one of the server's sizes (64, 128, 256, 512, 1024).
    static func image(_ link: String, width: Int) -> URL? {
        guard var components = URLComponents(string: link) else { return nil }
        let w = [64, 128, 256, 512, 1024].first { $0 >= width } ?? 1024
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "w" } + [URLQueryItem(name: "w", value: String(w))]
        return components.url
    }

    static func matches(_ book: Book, _ text: String) -> Bool {
        book.title.localizedCaseInsensitiveContains(text)
            || book.authors.contains { $0.name.localizedCaseInsensitiveContains(text) }
            || book.narrators.contains { $0.name.localizedCaseInsensitiveContains(text) }
            || book.series.contains { $0.name.localizedCaseInsensitiveContains(text) }
    }

    func translating<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as OwnAudioError {
            throw Self.sourceError(error)
        }
    }

    static func sourceError(_ error: OwnAudioError) -> SourceError {
        switch error {
        case .signedOut: .signInRejected
        case .twoFactorRequired: .signInRejected
        case .problem(let p):
            switch p.status {
            case 400 where p.code == "invalid_grant": .signInRejected
            case 401: .signInRejected
            case 403: .notAllowed
            case 404: .notFound
            case 501: .unsupported
            default: p.detail.map { .server($0) } ?? .http(p.status)
            }
        case .http(let status): .http(status)
        case .decoding: .unreadable
        case .network: .network
        case .offline: .offline
        }
    }
}

extension OwnAudioSource {
    public func uploadTarget(kind: String, fileName: String, contentType: String, sizeBytes: Int64) async throws -> UploadTarget {
        try await translating {
            let link = try await client.createUpload(kind: kind == "cover" ? "book_cover" : "book_file", filename: fileName, contentType: contentType, sizeBytes: sizeBytes)
            return UploadTarget(uploadId: link.uploadId, url: link.url, method: link.method, headers: link.headers, expiresAt: link.expiresAt)
        }
    }

    public func createBook(title: String?, authors: [String], narrators: [String], description: String?, visibility: Visibility, coverUploadId: String?, files: [ImportedFile], importId: String) async throws -> Book {
        try await translating {
            let made = try await client.createBook(NewBook(
                title: title, author: authors.isEmpty ? nil : authors.joined(separator: "; "), narrator: narrators.isEmpty ? nil : narrators.joined(separator: "; "),
                description: description, visibility: visibility.rawValue, coverUploadId: coverUploadId,
                files: files.enumerated().map { index, file in
                    NewBook.File(uploadId: file.uploadId, relativePath: String(format: "%03d - %@", index + 1, file.fileName), title: file.title)
                }
            ), idempotencyKey: importId)
            let detail = (try? await client.book(id: made.id)) ?? WithIncluded(record: made, included: nil)
            let contributors = Dictionary(uniqueKeysWithValues: (detail.included?.contributors ?? []).map { ($0.id, $0) })
            // The new book joins the copy on the phone at the next feed sync; until then the
            // record is returned as the server made it.
            return Self.book(detail.record, contributors: contributors)
        }
    }
}

/// A device signed in to an own.audio account.
public struct DeviceSession: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public let name: String?
    public let signedInAt: Date
    public let lastUsedAt: Date?
    public let isThisDevice: Bool
}

extension OwnAudioSource {
    /// The devices signed in to this account, this one marked.
    public func sessions() async throws -> [DeviceSession] {
        try await translating {
            try await client.sessions().map { DeviceSession(id: $0.id, kind: $0.deviceKind, name: $0.deviceName, signedInAt: $0.signedInAt, lastUsedAt: $0.lastUsedAt, isThisDevice: $0.current) }
        }
    }

    public func revokeSession(id: String) async throws {
        try await translating { try await client.revokeSession(id: id) }
    }

    /// Every device out, this one included; the server then needs a fresh sign-in.
    public func signOutEverywhere() async throws {
        try await translating { try await client.revokeAllSessions() }
    }
}

// The listening statistics as OwnAudioKit decodes them; the app sees the kit only through here.
public typealias ListeningStats = OwnAudioKit.ListeningStats
public typealias MemberListening = OwnAudioKit.MemberListening
public typealias StatsRange = OwnAudioKit.StatsRange

extension OwnAudioSource {
    /// Deletes the account and everything it owns on the server. A refusal keeps its status:
    /// `.http(400)` for the server's last admin, `.http(403)` for an account nobody may delete.
    public func deleteAccount() async throws {
        do {
            try await client.deleteAccount()
        } catch OwnAudioError.problem(let p) where p.status == 400 || p.status == 403 {
            throw SourceError.http(p.status)
        } catch let error as OwnAudioError {
            throw Self.sourceError(error)
        }
    }

    public func listeningStats(_ range: StatsRange) async throws -> ListeningStats {
        try await translating { try await client.listeningStats(range) }
    }

    /// The family admin's overview; `.notAllowed` or `.http(403)` for anyone else.
    public func familyListening(_ range: StatsRange) async throws -> [MemberListening] {
        try await translating { try await client.familyListening(range) }
    }

    public func setStatsShared(withFamilyAdmin shared: Bool) async throws {
        try await translating { try await client.setStatsShared(withFamilyAdmin: shared) }
    }
}

/// One own.audio server's library as the change feed brought it, shared by the sources the
/// app rebuilds, so a new address does not mean a new snapshot. The app saves `state` between
/// launches and hands it back through `syncCatalogue`.
public final class OwnAudioCatalogue: @unchecked Sendable {
    public struct Library: Sendable {
        public var books: [Book]
        public var authors: [Person]
        public var narrators: [Person]
        public var progress: [String: ListeningProgress]
        public var bookmarks: [Bookmark]
        public var favourites: Set<String>
    }

    private let lock = NSLock()
    private var _state: FeedState?
    private var _library: Library?

    public init() {}

    public var state: FeedState? {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    var library: Library? {
        lock.lock()
        defer { lock.unlock() }
        return _library
    }

    func load(_ state: FeedState, library: Library) {
        lock.lock()
        _state = state
        _library = library
        lock.unlock()
    }

    /// A state saved by an earlier launch, before the first sync.
    public func restore(_ state: FeedState) {
        load(state, library: OwnAudioSource.library(state))
    }

    func remember(progress: ListeningProgress?, bookId: String) {
        lock.lock()
        _library?.progress[bookId] = progress
        lock.unlock()
    }

    func remember(favourite on: Bool, bookId: String) {
        lock.lock()
        if on { _library?.favourites.insert(bookId) } else { _library?.favourites.remove(bookId) }
        lock.unlock()
    }

    func remember(visibility: Visibility, bookId: String) {
        lock.lock()
        if let index = _library?.books.firstIndex(where: { $0.id == bookId }) { _library?.books[index].visibility = visibility }
        lock.unlock()
    }

    /// What is on the phone, for a settings screen; nil before the first sync.
    public var summary: (books: Int, authors: Int, syncedAt: Date?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let library = _library else { return nil }
        return (library.books.count, library.authors.count, _state?.syncedAt)
    }

    /// Another household's library: the next sync starts from a fresh snapshot.
    public func reset() {
        lock.lock()
        _state = nil
        _library = nil
        lock.unlock()
    }
}
