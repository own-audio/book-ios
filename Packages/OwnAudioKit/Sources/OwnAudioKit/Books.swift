import Foundation

// Books on `/api/v2`: the records and the calls the book app uses. Lists carry the book
// without its files, chapters and series; `GET /books/{id}` and the sync feed's records carry
// all three.

public struct Book: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let credits: [Credit]
    public let description: String?
    /// Whole seconds on the server, so this is a multiple of 1000.
    public let durationMs: Int64?
    public let isbn: String?
    public let publisher: String?
    public let publishedYear: Int?
    /// `private` or `family`.
    public let visibility: String
    public let ownerId: String
    public let source: String?
    /// A signed link; add `&w=` with 64, 128, 256, 512 or 1024 for a size.
    public let image: String?
    public let createdAt: Date
    public let updatedAt: Date
    /// In playing order; only on the detail and in the feed.
    public let files: [BookFile]?
    /// Across the whole book, in order; empty when the server knows none.
    public let chapters: [BookChapter]?
    public let series: [BookSeriesEntry]?
}

public struct BookFile: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let position: Int
    public let title: String?
    public let durationMs: Int64?
    public let sizeBytes: Int64?
    public let contentType: String?
}

/// A chapter mark: where it starts in book time; it ends where the next one starts.
public struct BookChapter: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let position: Int
    public let title: String?
    public let startMs: Int64
    public let fileId: String?
}

/// A book's place in a series; `position` may be fractional (1.5).
public struct BookSeriesEntry: Decodable, Sendable, Equatable {
    public let seriesId: String
    public let name: String
    public let position: Double?
}

public struct Bookmark: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public let itemId: String
    public let positionMs: Int64
    public let fileId: String?
    public let filePositionMs: Int64?
    public let label: String?
    public let hasAudioNote: Bool?
    public let createdAt: Date
}

extension OwnAudioClient {
    // MARK: - Books

    /// `sort`: `title` or `added` (newest first); `query` matches the title.
    public func books(contributorId: String? = nil, query: String? = nil, sort: String? = nil, include: [String] = [], cursor: String? = nil, limit: Int = 100) async throws -> Page<Book> {
        try await get("books", query: [
            "contributor_id": contributorId, "q": query, "sort": sort,
            "include": include.isEmpty ? nil : include.joined(separator: ","), "cursor": cursor, "limit": String(limit),
        ])
    }

    /// With files, chapters, series and the credited contributors.
    public func book(id: String) async throws -> WithIncluded<Book> {
        try await get("books/\(id)", query: ["include": "contributors"])
    }

    public func authors(query: String? = nil, cursor: String? = nil, limit: Int = 100) async throws -> Page<Contributor> {
        try await get("authors", query: ["q": query, "cursor": cursor, "limit": String(limit)])
    }

    public func narrators(query: String? = nil, cursor: String? = nil, limit: Int = 100) async throws -> Page<Contributor> {
        try await get("narrators", query: ["q": query, "cursor": cursor, "limit": String(limit)])
    }

    /// Shares one of the caller's own books with the household (`family`) or keeps it to
    /// themselves (`private`).
    public func setVisibility(bookId: String, _ visibility: String) async throws {
        struct Body: Encodable { let visibility: String }
        try await send("PUT", "books/\(bookId)/visibility", body: Body(visibility: visibility))
    }

    // MARK: - Progress

    /// Every position of a kind, the most recently changed first: "continue listening".
    public func progressList(_ kind: ItemKind, cursor: String? = nil, limit: Int = 100) async throws -> Page<Progress> {
        try await get("me/progress", query: ["kind": kind.rawValue, "cursor": cursor, "limit": String(limit)])
    }

    /// With the position of every device; nil when the item was never started.
    public func progress(_ kind: ItemKind, id: String) async throws -> Progress? {
        do {
            return try await get("me/progress/\(kind.rawValue)/\(id)")
        } catch OwnAudioError.problem(let p) where p.status == 404 {
            return nil
        }
    }

    /// A position named by the file and the offset in it, for a book whose files the device
    /// knows; the server works out the book time.
    public func saveProgress(_ kind: ItemKind, id: String, fileId: String, filePositionMs: Int64, finished: Bool = false, at: Date? = nil) async throws -> ProgressAnswer {
        struct Body: Encodable { let fileId: String; let filePositionMs: Int64; let finished: Bool; let at: Date? }
        return try await call("PUT", "me/progress/\(kind.rawValue)/\(id)", body: Body(fileId: fileId, filePositionMs: filePositionMs, finished: finished, at: at))
    }

    /// Forgets the position on every device.
    public func deleteProgress(_ kind: ItemKind, id: String) async throws {
        try await send("DELETE", "me/progress/\(kind.rawValue)/\(id)", body: Optional<Empty>.none)
    }

    // MARK: - Bookmarks

    public func bookmarks(_ kind: ItemKind? = nil, itemId: String? = nil, cursor: String? = nil, limit: Int = 500) async throws -> Page<Bookmark> {
        try await get("me/bookmarks", query: ["kind": kind?.rawValue, "item_id": itemId, "cursor": cursor, "limit": String(limit)])
    }

    public func createBookmark(_ kind: ItemKind, itemId: String, positionMs: Int64, label: String?) async throws -> Bookmark {
        struct Body: Encodable { let kind: ItemKind; let itemId: String; let positionMs: Int64; let label: String? }
        return try await call("POST", "me/bookmarks", body: Body(kind: kind, itemId: itemId, positionMs: positionMs, label: label))
    }

    /// A new label (empty clears it) and/or a new position.
    public func updateBookmark(id: String, label: String?? = nil, positionMs: Int64? = nil) async throws -> Bookmark {
        struct Body: Encodable {
            let label: String??
            let positionMs: Int64?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: Key.self)
                if let label { try c.encode(label, forKey: .label) }
                if let positionMs { try c.encode(positionMs, forKey: .positionMs) }
            }
            enum Key: String, CodingKey { case label, positionMs }
        }
        return try await call("PATCH", "me/bookmarks/\(id)", body: Body(label: label, positionMs: positionMs))
    }

    public func deleteBookmark(id: String) async throws {
        try await send("DELETE", "me/bookmarks/\(id)", body: Optional<Empty>.none)
    }

    // MARK: - Playback

    /// How to play one file of a book (`book_file`) or an episode: the original or a stream the
    /// server makes, and a signed link.
    public func playbackInfo(kind: String, id: String, capabilities: PlaybackCapabilities, startMs: Int64? = nil) async throws -> PlaybackInfo {
        struct Body: Encodable { let kind: String; let id: String; let capabilities: PlaybackCapabilities; let startMs: Int64? }
        return try await call("POST", "playback-info", body: Body(kind: kind, id: id, capabilities: capabilities, startMs: startMs))
    }
}

extension OfflineChange {
    /// A position reached offline; `at` is the device's clock then, which decides against a
    /// position from another device.
    public static func progress(_ kind: ItemKind, id: String, positionMs: Int64, finished: Bool, at: Date, clientId: String) -> Self {
        var change = Self(clientId: clientId, op: "progress", kind: kind, id: id, at: at)
        change.positionMs = positionMs
        change.finished = finished
        return change
    }
}
