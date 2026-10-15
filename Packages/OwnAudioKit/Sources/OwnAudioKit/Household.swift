import Foundation

// The household (the API calls it the family): who is in it, inviting and joining, and what
// each member shares with the others.

/// The caller's household.
public struct Family: Decodable, Sendable, Equatable {
    public struct Me: Decodable, Sendable, Equatable {
        public let userId: String
        /// `admin` or `member`.
        public let role: String
    }

    public let id: String
    public let name: String
    /// A signed link to its picture.
    public let image: String?
    public let me: Me
}

/// Someone in the household, as others see them.
public struct Member: Decodable, Sendable, Equatable, Identifiable {
    public var id: String { userId }
    public let userId: String
    public let displayName: String
    /// What the household calls them, when it differs ("Mum").
    public let label: String?
    /// `admin` or `member`.
    public let role: String?
    /// Invited by an admin, not signed in yet.
    public let pending: Bool?
    /// A signed link to their picture.
    public let image: String?

    /// The name to show: the household's own word for them first.
    public var name: String { label.flatMap { $0.isEmpty ? nil : $0 } ?? displayName }
}

/// An invitation: a code (and a link with it) that lets an account join the household.
public struct Invite: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    /// `email`, `link` or `claim`.
    public let kind: String
    public let code: String
    public let role: String
    public let maxUses: Int
    public let useCount: Int
    public let expiresAt: String
    public let joinUrl: String?
}

extension OwnAudioClient {
    public func family() async throws -> Family {
        try await get("family")
    }

    public func members() async throws -> [Member] {
        try await get("family/members")
    }

    /// Admins only.
    public func invites() async throws -> [Invite] {
        try await get("family/invites")
    }

    /// A code to hand on, good for `maxUses` accounts. Admins only.
    public func createInvite(maxUses: Int = 1) async throws -> Invite {
        struct Body: Encodable { let kind: String; let maxUses: Int }
        return try await call("POST", "family/invites", body: Body(kind: "link", maxUses: maxUses))
    }

    public func deleteInvite(id: String) async throws {
        try await send("DELETE", "family/invites/\(id)", body: Optional<Empty>.none)
    }

    /// Joins the household the code belongs to.
    public func join(code: String) async throws -> Family {
        struct Body: Encodable { let code: String }
        return try await call("POST", "family/join", body: Body(code: code))
    }

    /// One of the caller's own tracks: `family` shares it with the household, `private` keeps
    /// it to the caller.
    public func setVisibility(trackId: String, _ visibility: String) async throws {
        struct Body: Codable { let visibility: String }
        let _: Body = try await call("PUT", "tracks/\(trackId)/visibility", body: Body(visibility: visibility))
    }
}

/// What the family keeps on the server, in bytes.
public struct FamilyStorage: Decodable, Sendable, Equatable {
    public let totalBytes: Int64
    public let musicBytes: Int64
    public let audiobooksBytes: Int64
    public let podcastsBytes: Int64
    public let otherBytes: Int64
}

/// The family's prepaid credit, on a hosted server that charges for storage. Amounts are in
/// millionths of the currency.
public struct FamilyBilling: Decodable, Sendable, Equatable {
    public struct Pricing: Decodable, Sendable, Equatable {
        public let currency: String
        public let pricePerGbMonthMicro: Int64
    }

    public let balanceMicro: Int64
    /// The balance less what running jobs have reserved.
    public let availableMicro: Int64
    public let estimatedMonthlyCostMicro: Int64
    public let daysRemaining: Int64?
    public let depleted: Bool
    public let pricing: Pricing
}

extension OwnAudioClient {
    public func familyStorage() async throws -> FamilyStorage {
        try await get("family/storage")
    }

    /// Only where the server charges (the hosted service); elsewhere a 404 or 501.
    public func familyBilling() async throws -> FamilyBilling {
        try await get("family/billing")
    }
}

extension OwnAudioClient {
    /// A family or member picture. The API names them by a path on the server (`/api/v1/…`)
    /// that wants the access token rather than a signed link; a full link is fetched as it is.
    public func picture(_ path: String) async throws -> Data {
        let key = "\(cacheIdentity ?? host.absoluteString)|picture|\(path)"
        if isOffline() {
            guard let saved = cache?.data(forKey: key) else { throw OwnAudioError.offline }
            return saved
        }
        var request: URLRequest
        if let absolute = URL(string: path), absolute.scheme != nil {
            request = URLRequest(url: absolute)
        } else {
            guard let url = URL(string: path, relativeTo: host)?.absoluteURL else { throw OwnAudioError.network }
            request = URLRequest(url: url)
            request.setValue("Bearer \(try await tokens.accessToken(using: refresher()))", forHTTPHeaderField: "Authorization")
        }
        do {
            let data = try await Self.data(request, session: session)
            cache?.store(data, forKey: key)
            return data
        } catch OwnAudioError.network {
            if let saved = cache?.data(forKey: key) { return saved }
            throw OwnAudioError.network
        }
    }
}
