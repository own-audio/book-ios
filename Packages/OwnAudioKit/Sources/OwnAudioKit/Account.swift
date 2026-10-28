import Foundation

// The account itself and its listening statistics. Only `/api/v1` has these; the same access
// token works there. Copied by hand from own.audio Music, with the names kept.

/// One listener's statistics for a range (`GET /stats/me`).
public struct ListeningStats: Decodable, Sendable, Equatable {
    public let range: String
    public let totalSeconds: Int
    public let byKind: [KindTotal]
    public let byDay: [DayTotal]
    public let topItems: [TopItem]
    /// Days in a row, up to today, with any listening.
    public let streakDays: Int
    /// Audiobooks finished, ever.
    public let completedItems: Int
    /// Whether the family's admin may see these: `private` or `family_admin`. Absent from
    /// servers before 1.0.0-beta.49, where the app doesn't offer the switch.
    public let statsVisibility: String?

    public struct KindTotal: Decodable, Sendable, Equatable {
        /// `music`, `audiobook` or `podcast`.
        public let mediaKind: String
        public let seconds: Int
        public let sessions: Int
    }

    public struct DayTotal: Decodable, Sendable, Equatable {
        /// `YYYY-MM-DD` in the phone's time zone.
        public let day: String
        public let seconds: Int
    }

    public struct TopItem: Decodable, Sendable, Equatable {
        public let mediaKind: String
        public let itemId: String
        /// nil when the item has been deleted.
        public let title: String?
        public let seconds: Int
        public let sessions: Int
    }
}

/// One family member in the family admin's overview (`GET /stats/family`).
public struct MemberListening: Decodable, Sendable, Equatable, Identifiable {
    public let userId: String
    public let displayName: String
    public let displayLabel: String?
    /// nil when the member keeps their statistics private.
    public let totalSeconds: Int?
    public let byKind: [ListeningStats.KindTotal]?
    public let hidden: Bool

    public var id: String { userId }
    public var name: String { displayLabel ?? displayName }
}

public enum StatsRange: String, CaseIterable, Sendable {
    case week = "7d", month = "30d", year = "365d", all
}

extension OwnAudioClient {
    /// Deletes the account and everything it owns on the server, at once; the tokens are gone
    /// after this. Throws `.http(400)` for the server's last admin, who can't leave it without one.
    public func deleteAccount() async throws {
        _ = try await raw("DELETE", "users/me", query: [:], body: Optional<Empty>.none, idempotencyKey: nil, api: "api/v1")
        await tokens.signedOut()
    }

    public func listeningStats(_ range: StatsRange, timeZone: TimeZone = .current) async throws -> ListeningStats {
        try await getV1("stats/me", query: Self.statsQuery(range, timeZone))
    }

    /// The family admin's overview; `.http(403)` for anyone else.
    public func familyListening(_ range: StatsRange, timeZone: TimeZone = .current) async throws -> [MemberListening] {
        try await getV1("stats/family", query: Self.statsQuery(range, timeZone))
    }

    /// Lets the family's admin see this listener's statistics, or not.
    public func setStatsShared(withFamilyAdmin shared: Bool) async throws {
        struct Body: Encodable { let statsVisibility: String }
        _ = try await raw("PUT", "stats/me/visibility", query: [:], body: Body(statsVisibility: shared ? "family_admin" : "private"), idempotencyKey: nil, api: "api/v1")
    }

    static func statsQuery(_ range: StatsRange, _ timeZone: TimeZone) -> [String: String?] {
        ["range": range.rawValue, "tz_offset_minutes": String(timeZone.secondsFromGMT() / 60)]
    }
}
