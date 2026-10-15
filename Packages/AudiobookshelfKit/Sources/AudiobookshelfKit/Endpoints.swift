import Foundation

// The calls, grouped as the app uses them. Every list is scoped to one library, as the server
// has it; the app shows only libraries whose `mediaType` is `book`.

extension AudiobookshelfClient {
    // MARK: - The account

    /// The signed-in account with its progress and bookmarks, and the server's settings; what
    /// the app asks at launch and as its connection check.
    public func authorize() async throws -> SignIn {
        let answer: SignInAnswer = try await call("POST", "api/authorize", body: Empty())
        return try answer.signIn()
    }

    /// The account again: every `mediaProgress` and `bookmarks` row. There is no change feed,
    /// so this is how progress made elsewhere is noticed.
    public func me() async throws -> User {
        try await get("api/me")
    }

    // MARK: - Libraries and items

    /// Every library the account reaches, book libraries only.
    public func bookLibraries() async throws -> [Library] {
        let answer: LibrariesAnswer = try await get("api/libraries")
        return answer.libraries.filter { $0.mediaType == "book" }
    }

    public enum ItemSort: String, Sendable, CaseIterable {
        case title = "media.metadata.title"
        case author = "media.metadata.authorNameLF"
        case added = "addedAt"
        case duration = "media.duration"
        case publishedYear = "media.metadata.publishedYear"
        case progress = "progress"
        /// Only with a series filter.
        case sequence = "sequence"
    }

    /// `filter=<group>.<base64url(value)>`; URL-safe base64 because `+` in a query is a space to
    /// the server.
    public enum ItemFilter: Sendable, Equatable {
        case author(id: String)
        case narrator(name: String)
        case series(id: String)
        case genre(String)
        case tag(String)
        case progress(Progress)
        public enum Progress: String, Sendable { case finished, inProgress = "in-progress", notStarted = "not-started", notFinished = "not-finished" }

        var value: String {
            switch self {
            case .author(let id): return "authors.\(Self.encode(id))"
            case .narrator(let name): return "narrators.\(Self.encode(name))"
            case .series(let id): return "series.\(Self.encode(id))"
            case .genre(let g): return "genres.\(Self.encode(g))"
            case .tag(let t): return "tags.\(Self.encode(t))"
            case .progress(let p): return "progress.\(Self.encode(p.rawValue))"
            }
        }

        static func encode(_ s: String) -> String {
            Data(s.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
    }

    /// A page of a library's books. `collapseSeries` folds a series into one row.
    public func items(libraryId: String, page: Int = 0, limit: Int = 100, sort: ItemSort = .title, descending: Bool = false, filter: ItemFilter? = nil, collapseSeries: Bool = false) async throws -> Page<LibraryItem> {
        try await get("api/libraries/\(libraryId)/items", query: [
            "page": String(page), "limit": String(limit), "sort": sort.rawValue, "desc": descending ? "1" : "0",
            "filter": filter?.value, "collapseseries": collapseSeries ? "1" : nil,
        ])
    }

    /// Every book of a library, page after page.
    public func allItems(libraryId: String, sort: ItemSort = .title, filter: ItemFilter? = nil, pageSize: Int = 200) async throws -> [LibraryItem] {
        var all: [LibraryItem] = []
        var page = 0
        while true {
            let p = try await items(libraryId: libraryId, page: page, limit: pageSize, sort: sort, filter: filter)
            all += p.results
            guard p.hasMore, !p.results.isEmpty else { return all }
            page += 1
        }
    }

    /// One book with its files, tracks, chapters and the caller's progress.
    public func item(id: String) async throws -> LibraryItem {
        try await get("api/items/\(id)", query: ["expanded": "1", "include": "progress"])
    }

    public func series(libraryId: String, page: Int = 0, limit: Int = 100) async throws -> Page<Series> {
        try await get("api/libraries/\(libraryId)/series", query: ["page": String(page), "limit": String(limit), "sort": "name"])
    }

    public func series(id: String) async throws -> Series {
        try await get("api/series/\(id)", query: ["include": "progress"])
    }

    public func authors(libraryId: String) async throws -> [Author] {
        struct Answer: Decodable { let authors: [Author] }
        let answer: Answer = try await get("api/libraries/\(libraryId)/authors")
        return answer.authors
    }

    public func narrators(libraryId: String) async throws -> [Narrator] {
        struct Answer: Decodable { let narrators: [Narrator] }
        let answer: Answer = try await get("api/libraries/\(libraryId)/narrators")
        return answer.narrators
    }

    public func collections(libraryId: String) async throws -> [Collection] {
        let page: Page<Collection> = try await get("api/libraries/\(libraryId)/collections", query: ["limit": "500"])
        return page.results
    }

    /// The home screen's shelves, as the server composes them for this user.
    public func personalized(libraryId: String, limit: Int = 10) async throws -> [Shelf] {
        try await get("api/libraries/\(libraryId)/personalized", query: ["limit": String(limit)])
    }

    /// One library at a time, as the server has it.
    public func search(libraryId: String, _ query: String, limit: Int = 25) async throws -> SearchAnswer {
        try await get("api/libraries/\(libraryId)/search", query: ["q": query, "limit": String(limit)])
    }

    // MARK: - Progress and bookmarks

    public func progress(itemId: String) async throws -> MediaProgress? {
        do {
            return try await get("api/me/progress/\(itemId)")
        } catch AudiobookshelfError.http(404, _) {
            return nil
        }
    }

    public struct ProgressUpdate: Encodable, Sendable, Equatable {
        public var currentTime: Double
        public var duration: Double
        public var progress: Double
        public var isFinished: Bool
        public var hideFromContinueListening: Bool?
        public var libraryItemId: String?

        public init(currentTime: Double, duration: Double, isFinished: Bool, hideFromContinueListening: Bool? = nil) {
            self.currentTime = currentTime
            self.duration = duration
            self.progress = duration > 0 ? min(1, max(0, currentTime / duration)) : 0
            self.isFinished = isFinished
            self.hideFromContinueListening = hideFromContinueListening
        }
    }

    /// Sets the position outside a play session (a mark-as-finished, a position moved by hand,
    /// a reset).
    public func updateProgress(itemId: String, _ update: ProgressUpdate) async throws {
        try await send("PATCH", "api/me/progress/\(itemId)", body: update)
    }

    /// Several at once, each naming its `libraryItemId`.
    public func updateProgress(batch: [(itemId: String, update: ProgressUpdate)]) async throws {
        let body = batch.map { var u = $0.update; u.libraryItemId = $0.itemId; return u }
        try await send("PATCH", "api/me/progress/batch/update", body: body)
    }

    /// Forgets the position; `progressId` is `MediaProgress.id`, not the item's.
    public func deleteProgress(progressId: String) async throws {
        try await send("DELETE", "api/me/progress/\(progressId)", body: Optional<Empty>.none)
    }

    public func createBookmark(itemId: String, time: Double, title: String) async throws -> Bookmark {
        struct Body: Encodable { let time: Double; let title: String }
        return try await call("POST", "api/me/item/\(itemId)/bookmark", body: Body(time: time, title: title))
    }

    /// Renames the bookmark at `time`.
    public func updateBookmark(itemId: String, time: Double, title: String) async throws -> Bookmark {
        struct Body: Encodable { let time: Double; let title: String }
        return try await call("PATCH", "api/me/item/\(itemId)/bookmark", body: Body(time: time, title: title))
    }

    public func deleteBookmark(itemId: String, time: Double) async throws {
        let t = time == time.rounded() ? String(Int64(time)) : String(time)
        try await send("DELETE", "api/me/item/\(itemId)/bookmark/\(t)", body: Optional<Empty>.none)
    }

    // MARK: - Play sessions

    /// Opens a play session: the files to play (or one HLS playlist when the server transcodes)
    /// and the position to start at. Progress reported through the session counts as
    /// listening in the server's statistics.
    public func play(itemId: String, device: DeviceInfo, supportedMimeTypes: [String] = ["audio/mpeg", "audio/mp4", "audio/x-m4a", "audio/x-m4b", "audio/aac", "audio/flac", "audio/wav", "audio/x-wav", "audio/aiff"], forceTranscode: Bool = false) async throws -> PlaybackSession {
        struct Body: Encodable {
            let deviceInfo: DeviceInfo
            let forceDirectPlay: Bool
            let forceTranscode: Bool
            let supportedMimeTypes: [String]
            let mediaPlayer: String
        }
        return try await call("POST", "api/items/\(itemId)/play", body: Body(deviceInfo: device, forceDirectPlay: false, forceTranscode: forceTranscode, supportedMimeTypes: supportedMimeTypes, mediaPlayer: "AVPlayer"))
    }

    struct SessionReport: Encodable {
        let currentTime: Double
        let timeListened: Double
        let duration: Double
    }

    /// Where playback is now and how many seconds were listened since the last report.
    public func syncSession(id: String, currentTime: Double, timeListened: Double, duration: Double) async throws {
        try await send("POST", "api/session/\(id)/sync", body: SessionReport(currentTime: currentTime, timeListened: timeListened, duration: duration))
    }

    /// The last report; the session is over after this (its `sync` answers 404).
    public func closeSession(id: String, currentTime: Double, timeListened: Double, duration: Double) async throws {
        try await send("POST", "api/session/\(id)/close", body: SessionReport(currentTime: currentTime, timeListened: timeListened, duration: duration))
    }

    /// Listening the server didn't see, one answer per session.
    public func sendLocalSessions(_ sessions: [LocalSession], device: DeviceInfo) async throws -> [LocalSessionResult] {
        struct Body: Encodable { let sessions: [LocalSession]; let deviceInfo: DeviceInfo }
        struct Answer: Decodable { let results: [LocalSessionResult] }
        let answer: Answer = try await call("POST", "api/session/local-all", body: Body(sessions: sessions, deviceInfo: device))
        return answer.results
    }
}
