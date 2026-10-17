import Foundation

// The records of own.audio's `/api/v2`. Field names follow the API (snake_case on the wire,
// decoded to camelCase); durations and positions are milliseconds; ids are UUID strings.
// Unknown fields are ignored, as the API's additive rule expects of clients.

/// `GET /.well-known/own-audio`: what a server is, before signing in.
public struct Discovery: Decodable, Sendable, Equatable {
    public struct API: Decodable, Sendable, Equatable {
        public let version: Int
        public let path: String
        public let revision: Int
        /// `stable`, or `draft` while the version may still change.
        public let status: String
    }

    public struct Auth: Decodable, Sendable, Equatable {
        public let password: Bool
        public let providers: [String]
        public let deviceGrant: Bool
        public let totp: Bool
        public let passwordReset: Bool
    }

    public struct Address: Decodable, Sendable, Equatable {
        public let url: String
        /// `public`, `lan` or `vpn`.
        public let scope: String
    }

    public struct Limits: Decodable, Sendable, Equatable {
        public let listLimitDefault: Int
        public let listLimitMax: Int
        public let uploadMaxBytes: Int64?
        public let batchMax: Int?
    }

    /// What the server has switched on: `narration`, `billing`, `identify_library`, … A module
    /// with settings of its own (`auth`) comes as an object and counts as on.
    public struct Modules: Decodable, Sendable, Equatable {
        public let enabled: Set<String>

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            var on: Set<String> = []
            for key in container.allKeys {
                if let flag = try? container.decode(Bool.self, forKey: key) {
                    if flag { on.insert(key.stringValue) }
                } else {
                    on.insert(key.stringValue)
                }
            }
            enabled = on
        }

        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
    }

    public let id: String?
    public let name: String
    public let edition: String
    public let version: String
    public let api: [API]
    public let auth: Auth
    public let addresses: [Address]
    public let limits: Limits
    /// Absent on servers older than the module list.
    public let modules: Modules?

    public func has(module: String) -> Bool { modules?.enabled.contains(module) ?? false }

    /// The `/api/v2` this server speaks, if it speaks one.
    public var v2: API? { api.first { $0.version == 2 } }
}

/// The OAuth token response.
public struct Tokens: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    /// When the access token stops working; refreshed a little before.
    public let expiresAt: Date
    public let scope: String

    public init(accessToken: String, refreshToken: String, expiresAt: Date, scope: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }
}

struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Double
    let scope: String

    func tokens(now: Date = Date()) -> Tokens {
        Tokens(accessToken: accessToken, refreshToken: refreshToken, expiresAt: now.addingTimeInterval(expiresIn), scope: scope)
    }
}

/// An error answer: RFC 9457 problem details, with OAuth's fields on the token endpoint.
public struct Problem: Decodable, Sendable, Equatable, Error {
    public let status: Int
    /// Stable, to switch on: `not_found`, `invalid_grant`, `mfa_required`, …
    public let code: String
    public let detail: String?
    /// The two-factor challenge, when `code` is `mfa_required`.
    public let mfaToken: String?
    public let mfaMethods: [String]?
}

/// A page of a list; `next` is absent on the last one.
public struct Page<Item: Decodable & Sendable>: Decodable, Sendable {
    public let items: [Item]
    public let next: String?
    public let included: Included?
}

/// Records a list or record refers to, sent once (`include=`).
public struct Included: Decodable, Sendable {
    public let contributors: [Contributor]?
    public let albums: [Album]?
    public let releaseGroups: [ReleaseGroup]?
    public let genres: [Genre]?
}

public struct Contributor: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let sortName: String?
    public let kind: String
    public let musicbrainzArtistId: String?
    /// A signed link; add `&w=` with 64, 128, 256, 512 or 1024 for a size.
    public let image: String?
    public let roles: [String]?
}

/// Who did what on an item, in order.
public struct Credit: Decodable, Sendable, Equatable {
    public let contributorId: String
    /// `artist`, `featured`, `author`, `narrator`, `host`…
    public let role: String
    public let position: Int
    public let creditedAs: String?
    /// What follows this name in the full credit line: "; ", " feat. ", or nothing.
    public let joinPhrase: String
}

public struct Album: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let credits: [Credit]
    public let releaseGroupId: String?
    public let releaseDate: String?
    public let isCompilation: Bool
    public let trackCount: Int
    public let durationMs: Int64
    public let discCount: Int
    public let image: String?
    public let createdAt: Date
}

public struct ReleaseGroup: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let kind: String
    public let firstReleaseDate: String?
    public let albumIds: [String]?
}

public struct Genre: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
}

public struct Track: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let albumId: String?
    public let recordingId: String?
    public let credits: [Credit]
    public let genreIds: [String]
    public let discNumber: Int?
    public let trackNumber: Int?
    public let durationMs: Int64?
    /// `private` or `family`.
    public let visibility: String
    public let ownerId: String
    public let contentType: String?
    public let sizeBytes: Int64?
    public let image: String?
    public let createdAt: Date
    public let updatedAt: Date
}

/// A record with the records it refers to (`GET /albums/{id}?include=…`).
public struct WithIncluded<Record: Decodable & Sendable>: Decodable, Sendable {
    public let record: Record
    public let included: Included?

    public init(record: Record, included: Included?) {
        self.record = record
        self.included = included
    }

    public init(from decoder: Decoder) throws {
        record = try Record(from: decoder)
        let container = try decoder.container(keyedBy: Key.self)
        included = try container.decodeIfPresent(Included.self, forKey: .included)
    }

    enum Key: String, CodingKey { case included }
}

// MARK: - The listener's own state

public enum ItemKind: String, Sendable, Codable {
    case track, album, contributor, book, episode
}

public struct Favourite: Decodable, Sendable, Equatable {
    public let kind: String
    public let id: String
    public let createdAt: Date
}

public struct Rating: Decodable, Sendable, Equatable {
    public let kind: String
    public let id: String
    public let rating: Int
    public let updatedAt: Date
}

public struct Progress: Decodable, Sendable, Equatable {
    public struct Device: Decodable, Sendable, Equatable {
        public let deviceId: String
        public let deviceName: String?
        public let deviceKind: String
        public let positionMs: Int64
        public let finished: Bool
        public let at: Date
        public let current: Bool
    }

    public let kind: String
    public let id: String
    public let positionMs: Int64
    public let finished: Bool
    public let updatedAt: Date
    public let fileId: String?
    public let filePositionMs: Int64?
    public let devices: [Device]?
}

public struct ProgressAnswer: Decodable, Sendable, Equatable {
    public let progress: Progress
    /// False when a newer position was already stored.
    public let applied: Bool
}

/// A play, reported when it ended. `clientId` makes sending it twice harmless.
public struct Play: Encodable, Sendable, Equatable {
    public let clientId: String
    public let kind: ItemKind
    public let id: String
    public let startedAt: Date
    public let endedAt: Date
    public let listenedMs: Int64
    public let deviceKind: String?
    public let endedReason: String?

    public init(clientId: String, kind: ItemKind, id: String, startedAt: Date, endedAt: Date, listenedMs: Int64, deviceKind: String? = "ios", endedReason: String? = nil) {
        self.clientId = clientId
        self.kind = kind
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.listenedMs = listenedMs
        self.deviceKind = deviceKind
        self.endedReason = endedReason
    }
}

/// One item's answer in a batch: `ok`, `duplicate`, `stale`, or an error code.
public struct ItemResult: Decodable, Sendable, Equatable {
    public let clientId: String
    public let status: String
}

// MARK: - Playback

public struct PlaybackCapabilities: Encodable, Sendable, Equatable {
    /// Content types played as they are; empty for "anything".
    public var direct: [String]
    /// Formats the server may make instead, in order: `aac`, `mp3`.
    public var transcode: [String]
    public var maxBitrateKbps: Int?

    public init(direct: [String] = [], transcode: [String] = ["aac", "mp3"], maxBitrateKbps: Int? = nil) {
        self.direct = direct
        self.transcode = transcode
        self.maxBitrateKbps = maxBitrateKbps
    }
}

public struct PlaybackInfo: Decodable, Sendable, Equatable {
    /// `direct` (the original) or `transcode`.
    public let decision: String
    /// Signed: plays without a header until `expiresAt`.
    public let url: URL
    public let expiresAt: Date
    public let contentType: String?
    public let bitrateKbps: Int?
    public let reasons: [String]
}

// MARK: - Sync

/// One entry of `GET /sync/changes`: the record now, or its removal.
public struct Change: Decodable, Sendable {
    /// `track`, `album`, `contributor`, …, `favourite.track`, `progress.book`, `bookmark`.
    public let kind: String
    public let id: String
    /// `upsert` or `delete`.
    public let op: String
    /// The record, still as JSON: decode it by `kind` (`decode(_:)`).
    public let record: JSONValue?

    public func decode<T: Decodable>(_ type: T.Type) throws -> T? {
        guard let record else { return nil }
        return try JSONDecoder.ownAudio.decode(T.self, from: JSONEncoder().encode(record))
    }
}

public struct ChangesAnswer: Decodable, Sendable {
    public let changes: [Change]
    public let cursor: String
    public let hasMore: Bool
    /// Drop the copy and take a new snapshot.
    public let reset: Bool
}

/// One line of `GET /sync/snapshot`.
public enum SnapshotLine: Sendable {
    case begin(cursor: String)
    case record(kind: String, id: String, record: JSONValue)
    case end(cursor: String)
}

/// One change made offline, for `POST /sync/push`. `clientId` comes back in its result, and
/// makes a play sent twice count once.
public struct OfflineChange: Encodable, Sendable, Equatable {
    public let clientId: String
    public let op: String
    public let kind: ItemKind
    public let id: String
    /// When it happened, by the device's clock (the server never lets it be in the future).
    public let at: Date?
    public var rating: Int?
    public var startedAt: Date?
    public var endedAt: Date?
    public var listenedMs: Int64?
    public var deviceKind: String?
    public var positionMs: Int64?
    public var finished: Bool?

    init(clientId: String, op: String, kind: ItemKind, id: String, at: Date?) {
        self.clientId = clientId
        self.op = op
        self.kind = kind
        self.id = id
        self.at = at
    }

    public static func favourite(_ kind: ItemKind, id: String, _ on: Bool, at: Date, clientId: String) -> Self {
        .init(clientId: clientId, op: on ? "favourite" : "unfavourite", kind: kind, id: id, at: at)
    }

    /// 1 to 5; 0 takes the rating away.
    public static func rating(_ kind: ItemKind, id: String, _ rating: Int, at: Date, clientId: String) -> Self {
        var change = Self(clientId: clientId, op: "rate", kind: kind, id: id, at: at)
        change.rating = rating
        return change
    }

    public static func play(_ play: Play) -> Self {
        var change = Self(clientId: play.clientId, op: "play", kind: play.kind, id: play.id, at: play.endedAt)
        change.startedAt = play.startedAt
        change.endedAt = play.endedAt
        change.listenedMs = play.listenedMs
        change.deviceKind = play.deviceKind
        return change
    }
}

/// An event of `GET /events`.
public struct LiveEvent: Sendable, Equatable {
    /// `library`: something the account sees changed; read the change feed.
    public let type: String
    /// For resuming with `Last-Event-ID`.
    public let id: String?
    public let data: String
}

/// Reads a `text/event-stream` (the HTML standard's rules, without `retry`): fields until a
/// blank line, then the event. Fed bytes rather than lines, because Foundation's line reader
/// leaves out the blank lines that end each event.
struct EventStreamParser {
    private var line: [UInt8] = []
    private var lastWasCR = false
    private var type = ""
    private var id: String?
    private var data: [String] = []

    mutating func feed(_ byte: UInt8) -> LiveEvent? {
        switch byte {
        case 0x0A where lastWasCR:
            lastWasCR = false
            return nil
        case 0x0A, 0x0D:
            lastWasCR = byte == 0x0D
            defer { line.removeAll(keepingCapacity: true) }
            return feed(line: String(decoding: line, as: UTF8.self))
        default:
            lastWasCR = false
            line.append(byte)
            return nil
        }
    }

    mutating func feed(line: String) -> LiveEvent? {
        if line.isEmpty {
            defer { type = ""; data = [] }
            guard !data.isEmpty else { return nil }
            return LiveEvent(type: type.isEmpty ? "message" : type, id: id, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring, value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            let rest = line[line.index(after: colon)...]
            value = rest.hasPrefix(" ") ? rest.dropFirst() : rest
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": type = String(value)
        case "data": data.append(String(value))
        case "id": id = String(value)
        default: break
        }
        return nil
    }
}

/// Any JSON, kept as it came, for records decoded later by their kind.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

extension JSONDecoder {
    /// The API's conventions: snake_case keys, RFC 3339 times with or without fractions.
    public static var ownAudio: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = Self.fractional.date(from: text) ?? Self.whole.date(from: text) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an RFC 3339 time: \(text)"))
        }
        return d
    }

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

extension JSONEncoder {
    static var ownAudio: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        // The server keys idempotent requests on the body's bytes; unsorted, the keys come out
        // in a different order from one encode to the next and a retry is refused.
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
