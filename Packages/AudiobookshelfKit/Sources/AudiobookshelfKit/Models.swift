import Foundation

// Audiobookshelf's records as a client sees them (2.x, shapes checked against 2.37.1). The API
// is camelCase; durations and positions are seconds as floating point; timestamps are
// milliseconds since 1970. Unknown fields are ignored, and fields whose type has varied between
// server versions (`ino`, `id`) decode from a number or a string.

/// `GET /status`: what a server is, before signing in.
public struct ServerStatus: Decodable, Sendable, Equatable {
    public let app: String
    public let serverVersion: String
    public let isInit: Bool
    public let language: String?
    /// `local`, `openid`.
    public let authMethods: [String]
    public let authFormData: AuthForm?

    public struct AuthForm: Decodable, Sendable, Equatable {
        public let authLoginCustomMessage: String?
        public let authOpenIDButtonText: String?
        public let authOpenIDAutoLaunch: Bool?
    }

    public var version: ServerVersion { ServerVersion(serverVersion) }
}

/// `2.37.1` as something that compares.
public struct ServerVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let parts: [Int]
    public init(_ text: String) {
        parts = text.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
    public static func < (a: ServerVersion, b: ServerVersion) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        for i in 0..<n {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }
    /// `2.26` and `2.26.0` are the same version.
    public static func == (a: ServerVersion, b: ServerVersion) -> Bool { !(a < b) && !(b < a) }
    public var description: String { parts.map(String.init).joined(separator: ".") }
    /// The first version with one-hour JWT access tokens and rotating refresh tokens.
    public static let rotatingTokens = ServerVersion("2.26.0")
}

/// The tokens of one signed-in account.
public struct Tokens: Codable, Sendable, Equatable {
    public let accessToken: String
    /// `nil` on a server older than 2.26: its one token never expires.
    public let refreshToken: String?
    /// When the access token stops working; refreshed a little before. `.distantFuture` for a
    /// token with no expiry.
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// The `exp` claim of a JWT access token, read without checking the signature (the server
    /// does that); `nil` when the token is not a JWT with one.
    public static func expiry(ofJWT token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

/// What `POST /login` and `POST /api/authorize` answer: the account with its progress and
/// bookmarks, the tokens, the server's settings.
public struct SignIn: Sendable, Equatable {
    public let user: User
    public let tokens: Tokens
    public let defaultLibraryId: String?
    public let serverVersion: ServerVersion?
}

struct SignInAnswer: Decodable {
    let user: User
    let userDefaultLibraryId: String?
    let serverSettings: ServerSettings?

    struct ServerSettings: Decodable {
        let version: String?
    }

    func signIn() throws -> SignIn {
        let tokens: Tokens
        if let access = user.accessToken, !access.isEmpty {
            tokens = Tokens(accessToken: access, refreshToken: user.refreshToken, expiresAt: Tokens.expiry(ofJWT: access) ?? .distantFuture)
        } else if let legacy = user.token, !legacy.isEmpty {
            tokens = Tokens(accessToken: legacy, refreshToken: nil, expiresAt: .distantFuture)
        } else {
            throw AudiobookshelfError.decoding
        }
        return SignIn(user: user, tokens: tokens, defaultLibraryId: userDefaultLibraryId, serverVersion: serverSettings?.version.map(ServerVersion.init))
    }
}

public struct User: Decodable, Sendable, Equatable {
    public let id: String
    public let username: String
    /// `root`, `admin`, `user`, `guest`.
    public let type: String
    public let email: String?
    let token: String?
    let accessToken: String?
    let refreshToken: String?
    public let mediaProgress: [MediaProgress]
    public let bookmarks: [Bookmark]
    public let permissions: Permissions
    /// Empty when the account reaches every library.
    public let librariesAccessible: [String]
    public let lastSeen: Int64?

    enum CodingKeys: String, CodingKey {
        case id, username, type, email, token, accessToken, refreshToken, mediaProgress, bookmarks, permissions, librariesAccessible, lastSeen
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        username = try c.decode(String.self, forKey: .username)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "user"
        email = try c.decodeIfPresent(String.self, forKey: .email)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        accessToken = try c.decodeIfPresent(String.self, forKey: .accessToken)
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        mediaProgress = try c.decodeIfPresent([MediaProgress].self, forKey: .mediaProgress) ?? []
        bookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        permissions = try c.decodeIfPresent(Permissions.self, forKey: .permissions) ?? Permissions()
        librariesAccessible = try c.decodeIfPresent([String].self, forKey: .librariesAccessible) ?? []
        lastSeen = try c.decodeIfPresent(Int64.self, forKey: .lastSeen)
    }
}

public struct Permissions: Decodable, Sendable, Equatable {
    public var download = true
    public var update = false
    public var delete = false
    public var upload = false
    public var accessAllLibraries = true
    public var accessExplicitContent = true

    public init() {}

    enum CodingKeys: String, CodingKey { case download, update, delete, upload, accessAllLibraries, accessExplicitContent }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        download = try c.decodeIfPresent(Bool.self, forKey: .download) ?? true
        update = try c.decodeIfPresent(Bool.self, forKey: .update) ?? false
        delete = try c.decodeIfPresent(Bool.self, forKey: .delete) ?? false
        upload = try c.decodeIfPresent(Bool.self, forKey: .upload) ?? false
        accessAllLibraries = try c.decodeIfPresent(Bool.self, forKey: .accessAllLibraries) ?? true
        accessExplicitContent = try c.decodeIfPresent(Bool.self, forKey: .accessExplicitContent) ?? true
    }
}

/// One user's position in one item; positions in seconds across the whole book.
public struct MediaProgress: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let libraryItemId: String
    public let episodeId: String?
    public let duration: Double
    /// 0–1.
    public let progress: Double
    public let currentTime: Double
    public let isFinished: Bool
    public let hideFromContinueListening: Bool
    /// Milliseconds since 1970.
    public let lastUpdate: Int64
    public let startedAt: Int64?
    public let finishedAt: Int64?

    public var updatedAt: Date { Date(timeIntervalSince1970: Double(lastUpdate) / 1000) }
}

/// A bookmark is keyed by its time: there is no id, and changing the time means delete + create.
public struct Bookmark: Decodable, Sendable, Equatable {
    public let libraryItemId: String
    public let time: Double
    public let title: String
    public let createdAt: Int64

    public init(libraryItemId: String, time: Double, title: String, createdAt: Int64) {
        self.libraryItemId = libraryItemId
        self.time = time
        self.title = title
        self.createdAt = createdAt
    }
}

public struct Library: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// `book` or `podcast`.
    public let mediaType: String
    public let displayOrder: Int?
    public let icon: String?
}

struct LibrariesAnswer: Decodable {
    let libraries: [Library]
}

/// A page of a library's items, series or collections.
public struct Page<T: Decodable & Sendable>: Decodable, Sendable {
    public let results: [T]
    public let total: Int
    public let limit: Int
    public let page: Int

    public var hasMore: Bool { limit > 0 && (page + 1) * limit < total }
}

/// A library item: a book (this app shows no podcasts). Lists carry the strings
/// (`authorName`, `seriesName`); the detail (`expanded=1`) carries the linked records,
/// files, tracks and chapters.
public struct LibraryItem: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let ino: String?
    public let libraryId: String
    public let path: String?
    public let addedAt: Int64
    public let updatedAt: Int64
    public let isMissing: Bool
    public let isInvalid: Bool
    public let mediaType: String
    public let media: BookMedia
    /// On a list filtered or sorted by a series.
    public let sequence: String?
    /// On a detail asked for with `include=progress`.
    public let userMediaProgress: MediaProgress?

    enum CodingKeys: String, CodingKey {
        case id, ino, libraryId, path, addedAt, updatedAt, isMissing, isInvalid, mediaType, media, sequence, userMediaProgress
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ino = try c.decodeIfPresent(FlexibleID.self, forKey: .ino)?.value
        libraryId = try c.decode(String.self, forKey: .libraryId)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        addedAt = try c.decodeIfPresent(Int64.self, forKey: .addedAt) ?? 0
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
        isMissing = try c.decodeIfPresent(Bool.self, forKey: .isMissing) ?? false
        isInvalid = try c.decodeIfPresent(Bool.self, forKey: .isInvalid) ?? false
        mediaType = try c.decodeIfPresent(String.self, forKey: .mediaType) ?? "book"
        media = try c.decode(BookMedia.self, forKey: .media)
        sequence = try c.decodeIfPresent(FlexibleID.self, forKey: .sequence)?.value
        userMediaProgress = try c.decodeIfPresent(MediaProgress.self, forKey: .userMediaProgress)
    }
}

public struct BookMedia: Decodable, Sendable, Equatable {
    public let id: String?
    public let metadata: BookMetadata
    public let coverPath: String?
    public let tags: [String]
    public let numTracks: Int?
    public let numChapters: Int?
    /// Seconds.
    public let duration: Double
    public let size: Int64?
    /// Only with `expanded=1`.
    public let chapters: [Chapter]?
    public let tracks: [AudioTrack]?
    public let audioFiles: [AudioFile]?

    enum CodingKeys: String, CodingKey { case id, metadata, coverPath, tags, numTracks, numChapters, duration, size, chapters, tracks, audioFiles }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        metadata = try c.decode(BookMetadata.self, forKey: .metadata)
        coverPath = try c.decodeIfPresent(String.self, forKey: .coverPath)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        numTracks = try c.decodeIfPresent(Int.self, forKey: .numTracks)
        numChapters = try c.decodeIfPresent(Int.self, forKey: .numChapters)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        chapters = try c.decodeIfPresent([Chapter].self, forKey: .chapters)
        tracks = try c.decodeIfPresent([AudioTrack].self, forKey: .tracks)
        audioFiles = try c.decodeIfPresent([AudioFile].self, forKey: .audioFiles)
    }
}

/// The strings come on lists (`authorName`, `narratorName`, `seriesName` like "Name #1"); the
/// records (`authors`, `narrators`, `series`) on a detail.
public struct BookMetadata: Decodable, Sendable, Equatable {
    public let title: String?
    public let subtitle: String?
    public let authorName: String?
    public let narratorName: String?
    public let seriesName: String?
    public let authors: [Author]?
    public let narrators: [String]?
    public let series: [SeriesEntry]?
    public let genres: [String]
    public let publishedYear: String?
    public let publisher: String?
    public let description: String?
    public let isbn: String?
    public let asin: String?
    public let language: String?
    public let explicit: Bool
    public let abridged: Bool

    enum CodingKeys: String, CodingKey {
        case title, subtitle, authorName, narratorName, seriesName, authors, narrators, series, genres, publishedYear, publisher, description, isbn, asin, language, explicit, abridged
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        authorName = try c.decodeIfPresent(String.self, forKey: .authorName)
        narratorName = try c.decodeIfPresent(String.self, forKey: .narratorName)
        seriesName = try c.decodeIfPresent(String.self, forKey: .seriesName)
        authors = try c.decodeIfPresent([Author].self, forKey: .authors)
        narrators = try c.decodeIfPresent([String].self, forKey: .narrators)
        series = try c.decodeIfPresent([SeriesEntry].self, forKey: .series)
        genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
        publishedYear = try c.decodeIfPresent(FlexibleID.self, forKey: .publishedYear)?.value
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        isbn = try c.decodeIfPresent(String.self, forKey: .isbn)
        asin = try c.decodeIfPresent(String.self, forKey: .asin)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        explicit = try c.decodeIfPresent(Bool.self, forKey: .explicit) ?? false
        abridged = try c.decodeIfPresent(Bool.self, forKey: .abridged) ?? false
    }
}

public struct Author: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    public let imagePath: String?
    public let numBooks: Int?
}

/// A book's place in a series; `sequence` is a string such as "1.5" or "1-3".
public struct SeriesEntry: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let sequence: String?

    enum CodingKeys: String, CodingKey { case id, name, sequence }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sequence = try c.decodeIfPresent(FlexibleID.self, forKey: .sequence)?.value
    }
}

/// From `GET /api/libraries/{id}/series`: the series with its books, each carrying `sequence`.
public struct Series: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let nameIgnorePrefix: String?
    public let description: String?
    public let addedAt: Int64?
    public let books: [LibraryItem]
}

/// Narrators have no ids on the server; `id` is a base64 form of the name, good for one call.
public struct Narrator: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let numBooks: Int?
}

public struct Collection: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let libraryId: String
    public let name: String
    public let description: String?
    public let books: [LibraryItem]
}

/// A chapter, in seconds across the whole book.
public struct Chapter: Decodable, Sendable, Equatable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let title: String

    public init(id: Int, start: Double, end: Double, title: String) {
        self.id = id
        self.start = start
        self.end = end
        self.title = title
    }
}

/// One playable file of a book, in order; `startOffset` is where it begins in book time.
public struct AudioTrack: Decodable, Sendable, Equatable {
    public let index: Int
    public let startOffset: Double
    public let duration: Double
    public let title: String?
    /// `/api/items/{id}/file/{ino}`, or an HLS playlist in a transcoding session.
    public let contentUrl: String
    public let mimeType: String?
    public let ino: String?
    public let codec: String?
    public let bitRate: Int?

    enum CodingKeys: String, CodingKey { case index, startOffset, duration, title, contentUrl, mimeType, ino, codec, bitRate }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        startOffset = try c.decodeIfPresent(Double.self, forKey: .startOffset) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title)
        contentUrl = try c.decode(String.self, forKey: .contentUrl)
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
        ino = try c.decodeIfPresent(FlexibleID.self, forKey: .ino)?.value
        codec = try c.decodeIfPresent(String.self, forKey: .codec)
        bitRate = try c.decodeIfPresent(Int.self, forKey: .bitRate)
    }
}

public struct AudioFile: Decodable, Sendable, Equatable {
    public let ino: String?
    public let index: Int?
    public let duration: Double?
    public let mimeType: String?
    public let metadata: Metadata?

    public struct Metadata: Decodable, Sendable, Equatable {
        public let filename: String?
        public let ext: String?
        public let size: Int64?
    }

    enum CodingKeys: String, CodingKey { case ino, index, duration, mimeType, metadata }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ino = try c.decodeIfPresent(FlexibleID.self, forKey: .ino)?.value
        index = try c.decodeIfPresent(Int.self, forKey: .index)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
        metadata = try c.decodeIfPresent(Metadata.self, forKey: .metadata)
    }
}

/// A home-screen shelf from `GET /api/libraries/{id}/personalized`: `continue-listening`,
/// `recently-added`, `discover`, `listen-again`, `newest-authors`, `continue-series`…
public struct Shelf: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    /// `book`, `series`, `authors`, `episode`.
    public let type: String
    public let books: [LibraryItem]
    public let series: [Series]
    public let authors: [Author]

    enum CodingKeys: String, CodingKey { case id, label, type, entities }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "book"
        switch type {
        case "series": series = (try? c.decode([Series].self, forKey: .entities)) ?? []; books = []; authors = []
        case "authors": authors = (try? c.decode([Author].self, forKey: .entities)) ?? []; books = []; series = []
        case "book": books = (try? c.decode([LibraryItem].self, forKey: .entities)) ?? []; series = []; authors = []
        default: books = []; series = []; authors = []
        }
    }
}

/// `GET /api/libraries/{id}/search`.
public struct SearchAnswer: Decodable, Sendable {
    public struct BookHit: Decodable, Sendable {
        public let libraryItem: LibraryItem
        public let matchKey: String?
        public let matchText: String?
    }
    public struct SeriesHit: Decodable, Sendable {
        public let series: Series
        public let books: [LibraryItem]
    }
    public struct NameHit: Decodable, Sendable {
        public let name: String
        public let numBooks: Int?
    }
    public let book: [BookHit]
    public let series: [SeriesHit]
    public let authors: [Author]
    public let narrators: [NameHit]

    enum CodingKeys: String, CodingKey { case book, series, authors, narrators }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        book = try c.decodeIfPresent([BookHit].self, forKey: .book) ?? []
        series = (try? c.decodeIfPresent([SeriesHit].self, forKey: .series)) ?? []
        authors = (try? c.decodeIfPresent([Author].self, forKey: .authors)) ?? []
        narrators = (try? c.decodeIfPresent([NameHit].self, forKey: .narrators)) ?? []
    }
}

/// What this device is, in play sessions.
public struct DeviceInfo: Codable, Sendable, Equatable {
    public var deviceId: String
    public var clientName: String
    public var clientVersion: String
    public var manufacturer: String
    public var model: String
    public var sdkVersion: String?

    public init(deviceId: String, clientName: String, clientVersion: String, manufacturer: String = "Apple", model: String = "iPhone", sdkVersion: String? = nil) {
        self.deviceId = deviceId
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.manufacturer = manufacturer
        self.model = model
        self.sdkVersion = sdkVersion
    }
}

/// `POST /api/items/{id}/play`: how to play, and the session that progress reports go to. A new
/// session for the same book closes the open one, so an app keeps one per book.
public struct PlaybackSession: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let libraryItemId: String
    public let episodeId: String?
    /// 0 direct play, 1 direct stream, 2 transcode (HLS), 3 local.
    public let playMethod: Int
    public let duration: Double
    public let currentTime: Double
    public let startTime: Double
    public let chapters: [Chapter]
    public let audioTracks: [AudioTrack]
    public let displayTitle: String?
    public let displayAuthor: String?
    public let coverPath: String?
    public let serverVersion: String?
    public let date: String?
    public let dayOfWeek: String?
    public let startedAt: Int64?
    public let updatedAt: Int64?

    public var isHLS: Bool { playMethod == 2 }

    enum CodingKeys: String, CodingKey {
        case id, libraryItemId, episodeId, playMethod, duration, currentTime, startTime, chapters, audioTracks, displayTitle, displayAuthor, coverPath, serverVersion, date, dayOfWeek, startedAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        libraryItemId = try c.decode(String.self, forKey: .libraryItemId)
        episodeId = try c.decodeIfPresent(String.self, forKey: .episodeId)
        playMethod = try c.decodeIfPresent(Int.self, forKey: .playMethod) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        currentTime = try c.decodeIfPresent(Double.self, forKey: .currentTime) ?? 0
        startTime = try c.decodeIfPresent(Double.self, forKey: .startTime) ?? 0
        chapters = try c.decodeIfPresent([Chapter].self, forKey: .chapters) ?? []
        audioTracks = try c.decodeIfPresent([AudioTrack].self, forKey: .audioTracks) ?? []
        displayTitle = try c.decodeIfPresent(String.self, forKey: .displayTitle)
        displayAuthor = try c.decodeIfPresent(String.self, forKey: .displayAuthor)
        coverPath = try c.decodeIfPresent(String.self, forKey: .coverPath)
        serverVersion = try c.decodeIfPresent(String.self, forKey: .serverVersion)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        dayOfWeek = try c.decodeIfPresent(String.self, forKey: .dayOfWeek)
        startedAt = try c.decodeIfPresent(Int64.self, forKey: .startedAt)
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt)
    }
}

/// A session built on the phone for listening the server didn't see (offline or from a
/// download), sent with `POST /api/session/local-all`. The server moves the progress when the
/// session is newer than what it has.
public struct LocalSession: Encodable, Sendable, Equatable {
    public var id: String
    public var userId: String
    public var libraryId: String
    public var libraryItemId: String
    public var episodeId: String?
    public var mediaType = "book"
    public var displayTitle: String?
    public var displayAuthor: String?
    public var duration: Double
    public var playMethod = 3
    public var mediaPlayer = "AVPlayer"
    public var deviceInfo: DeviceInfo
    public var date: String
    public var dayOfWeek: String
    /// Seconds actually listened.
    public var timeListening: Double
    public var startTime: Double
    public var currentTime: Double
    public var startedAt: Int64
    public var updatedAt: Int64

    public init(id: String, userId: String, libraryId: String, libraryItemId: String, displayTitle: String?, displayAuthor: String?, duration: Double, deviceInfo: DeviceInfo, timeListening: Double, startTime: Double, currentTime: Double, startedAt: Date, updatedAt: Date) {
        self.id = id
        self.userId = userId
        self.libraryId = libraryId
        self.libraryItemId = libraryItemId
        self.displayTitle = displayTitle
        self.displayAuthor = displayAuthor
        self.duration = duration
        self.deviceInfo = deviceInfo
        self.timeListening = timeListening
        self.startTime = startTime
        self.currentTime = currentTime
        self.startedAt = Int64(startedAt.timeIntervalSince1970 * 1000)
        self.updatedAt = Int64(updatedAt.timeIntervalSince1970 * 1000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        date = f.string(from: startedAt)
        f.dateFormat = "EEEE"
        dayOfWeek = f.string(from: startedAt)
    }
}

public struct LocalSessionResult: Decodable, Sendable, Equatable {
    public let id: String
    public let success: Bool
    public let progressSynced: Bool?
}

/// An id or `ino` that one server version sends as a number and another as a string.
struct FlexibleID: Decodable {
    let value: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int64.self) { value = String(i) }
        else if let d = try? c.decode(Double.self) { value = d == d.rounded() ? String(Int64(d)) : String(d) }
        else { throw DecodingError.typeMismatch(String.self, .init(codingPath: decoder.codingPath, debugDescription: "neither a string nor a number")) }
    }
}
