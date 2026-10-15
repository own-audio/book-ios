import Foundation

// The operations the app uses, one function each. Lists are cursor-paged: pass `next` from
// the previous page as `cursor`, until it is nil.

extension OwnAudioClient {
    // MARK: - Catalogue

    public func artists(query: String? = nil, cursor: String? = nil, limit: Int = 100) async throws -> Page<Contributor> {
        try await get("artists", query: ["q": query, "cursor": cursor, "limit": String(limit)])
    }

    public func contributor(id: String) async throws -> Contributor {
        try await get("contributors/\(id)")
    }

    /// `sort`: `title` or `added` (newest first).
    public func albums(
        contributorId: String? = nil, genreId: String? = nil, releaseGroupId: String? = nil, query: String? = nil,
        sort: String? = nil, include: [String] = [], cursor: String? = nil, limit: Int = 100
    ) async throws -> Page<Album> {
        try await get("albums", query: [
            "contributor_id": contributorId, "genre_id": genreId, "release_group_id": releaseGroupId, "q": query,
            "sort": sort, "include": include.isEmpty ? nil : include.joined(separator: ","),
            "cursor": cursor, "limit": String(limit),
        ])
    }

    public func album(id: String, include: [String] = ["contributors"]) async throws -> WithIncluded<Album> {
        try await get("albums/\(id)", query: ["include": include.isEmpty ? nil : include.joined(separator: ",")])
    }

    /// With `albumId` in disc and track order; otherwise `sort` `title` or `added`.
    public func tracks(
        albumId: String? = nil, contributorId: String? = nil, genreId: String? = nil, query: String? = nil,
        sort: String? = nil, include: [String] = [], cursor: String? = nil, limit: Int = 100
    ) async throws -> Page<Track> {
        try await get("tracks", query: [
            "album_id": albumId, "contributor_id": contributorId, "genre_id": genreId, "q": query, "sort": sort,
            "include": include.isEmpty ? nil : include.joined(separator: ","), "cursor": cursor, "limit": String(limit),
        ])
    }

    public func track(id: String, include: [String] = ["albums", "contributors"]) async throws -> WithIncluded<Track> {
        try await get("tracks/\(id)", query: ["include": include.isEmpty ? nil : include.joined(separator: ",")])
    }

    public func genres(cursor: String? = nil, limit: Int = 500) async throws -> Page<Genre> {
        try await get("genres", query: ["cursor": cursor, "limit": String(limit)])
    }

    /// Every page of a list, one after another.
    public func all<Item>(_ page: (String?) async throws -> Page<Item>) async throws -> [Item] {
        var items: [Item] = []
        var cursor: String?
        repeat {
            let p = try await page(cursor)
            items += p.items
            cursor = p.next
        } while cursor != nil
        return items
    }

    // MARK: - The listener's own state

    public func setFavourite(_ kind: ItemKind, id: String, _ on: Bool) async throws {
        try await send(on ? "PUT" : "DELETE", "me/favourites/\(kind.rawValue)/\(id)", body: Optional<Empty>.none)
    }

    public func favourites(_ kind: ItemKind, cursor: String? = nil, limit: Int = 500) async throws -> Page<Favourite> {
        try await get("me/favourites", query: ["kind": kind.rawValue, "cursor": cursor, "limit": String(limit)])
    }

    /// 1 to 5; 0 takes the rating away.
    public func setRating(_ kind: ItemKind, id: String, _ rating: Int) async throws {
        struct Body: Encodable { let rating: Int }
        try await send("PUT", "me/ratings/\(kind.rawValue)/\(id)", body: Body(rating: rating))
    }

    public func ratings(_ kind: ItemKind, cursor: String? = nil, limit: Int = 500) async throws -> Page<Rating> {
        try await get("me/ratings", query: ["kind": kind.rawValue, "cursor": cursor, "limit": String(limit)])
    }

    /// Where the listener is; `at` is when they were there, for a position saved offline.
    public func saveProgress(_ kind: ItemKind, id: String, positionMs: Int64, finished: Bool = false, at: Date? = nil) async throws -> ProgressAnswer {
        struct Body: Encodable { let positionMs: Int64; let finished: Bool; let at: Date? }
        return try await call("PUT", "me/progress/\(kind.rawValue)/\(id)", body: Body(positionMs: positionMs, finished: finished, at: at))
    }

    /// Plays, each answered on its own; sending one twice counts it once.
    public func reportPlays(_ plays: [Play]) async throws -> [ItemResult] {
        struct Body: Encodable { let plays: [Play] }
        return try await call("POST", "me/plays", body: Body(plays: plays))
    }

    // MARK: - Playback

    /// How to play a track: the original or a stream the server makes, and a signed link.
    public func playbackInfo(trackId: String, capabilities: PlaybackCapabilities, startMs: Int64? = nil) async throws -> PlaybackInfo {
        struct Body: Encodable { let kind: String; let id: String; let capabilities: PlaybackCapabilities; let startMs: Int64? }
        return try await call("POST", "playback-info", body: Body(kind: "track", id: trackId, capabilities: capabilities, startMs: startMs))
    }

    // MARK: - Sync

    /// What changed since `cursor`; with no cursor, a cursor for "from now on".
    public func changes(since cursor: String?, limit: Int = 500) async throws -> ChangesAnswer {
        try await get("sync/changes", query: ["cursor": cursor, "limit": String(limit)])
    }

    /// Everything the account can see, line by line; `kinds` limits it (`track`, `album`,
    /// `contributor`, `genre`, `favourite`, `rating`, …). Resume a broken one with `after`
    /// (the last line's `kind:id`) and the `begin` line's cursor.
    public func snapshot(kinds: [String] = [], after: String? = nil, cursor: String? = nil, _ each: (SnapshotLine) async throws -> Void) async throws {
        let refresher: @Sendable (String) async throws -> Tokens = { [host, session] refresh in
            try await OwnAudioClient.refresh(host: host, refreshToken: refresh, session: session)
        }
        let token = try await tokens.accessToken(using: refresher)
        var request = URLRequest(url: try url("sync/snapshot", query: [
            "kinds": kinds.isEmpty ? nil : kinds.joined(separator: ","), "after": after, "cursor": cursor,
        ]))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw OwnAudioError.network
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OwnAudioError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        var ended = false
        for try await line in bytes.lines where !line.isEmpty {
            guard let parsed = try Self.snapshotLine(line) else { continue }
            if case .end = parsed { ended = true }
            try await each(parsed)
        }
        // A body cut short has no `end` line: the caller resumes from the last record.
        if !ended { throw OwnAudioError.network }
    }

    /// What the device changed while offline, in the order it happened; up to 500 at a time.
    /// Each is answered on its own, in order: `ok`, `stale` or `duplicate` are done, anything
    /// else is an error code.
    public func push(_ changes: [OfflineChange]) async throws -> [ItemResult] {
        struct Body: Encodable { let changes: [OfflineChange] }
        return try await call("POST", "sync/push", body: Body(changes: changes))
    }

    /// Live updates: a `library` event whenever the account's library or its own state
    /// changed, which says to read `changes(since:)`. Runs until the connection ends; resume
    /// with the last event's id.
    public func events(lastEventId: String? = nil) -> AsyncThrowingStream<LiveEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let refresher: @Sendable (String) async throws -> Tokens = { [host, session] refresh in
                        try await OwnAudioClient.refresh(host: host, refreshToken: refresh, session: session)
                    }
                    var token = try await tokens.accessToken(using: refresher)
                    var retried = false
                    while true {
                        var request = URLRequest(url: try url("events", query: [:]))
                        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        if let lastEventId { request.setValue(lastEventId, forHTTPHeaderField: "Last-Event-ID") }
                        // The server sends a comment every 30 seconds; silence for longer means
                        // the connection is gone.
                        request.timeoutInterval = 75
                        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                        do {
                            (bytes, response) = try await session.bytes(for: request)
                        } catch {
                            throw OwnAudioError.network
                        }
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if status == 401, !retried {
                            retried = true
                            token = try await tokens.refresh(using: refresher).accessToken
                            continue
                        }
                        guard status == 200 else { throw OwnAudioError.http(status) }
                        var parser = EventStreamParser()
                        do {
                            for try await byte in bytes {
                                if let event = parser.feed(byte) { continuation.yield(event) }
                            }
                        } catch {
                            throw OwnAudioError.network
                        }
                        break
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func snapshotLine(_ line: String) throws -> SnapshotLine? {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        switch value["type"]?.string {
        case "begin": return value["cursor"]?.string.map { .begin(cursor: $0) }
        case "end": return value["cursor"]?.string.map { .end(cursor: $0) }
        case "record":
            guard let kind = value["kind"]?.string, let id = value["id"]?.string, let record = value["record"] else { return nil }
            return .record(kind: kind, id: id, record: record)
        default: return nil
        }
    }

    // MARK: - The account

    public struct Me: Decodable, Sendable, Equatable {
        public struct Family: Decodable, Sendable, Equatable {
            public let id: String
            public let role: String
            public let canUpload: Bool
        }
        public let id: String
        public let email: String
        public let displayName: String
        public let family: Family
    }

    public func me() async throws -> Me {
        try await get("me")
    }
}
