import Foundation

/// One device signed in to the account (`GET /me/sessions`). Signing it out ends its refresh
/// token and its access tokens at once.
public struct Session: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let deviceKind: String
    public let deviceName: String?
    public let signedInAt: Date
    public let lastUsedAt: Date?
    public let expiresAt: Date
    /// The device making the request.
    public let current: Bool
}

extension OwnAudioClient {
    /// The devices signed in to this account, this one marked.
    public func sessions() async throws -> [Session] {
        try await get("me/sessions")
    }

    /// Signs one device out, at once.
    public func revokeSession(id: String) async throws {
        try await send("DELETE", "me/sessions/\(id)", body: Optional<Empty>.none)
    }

    /// Sign out everywhere, this device included: the tokens are gone after this, so the
    /// caller signs in again.
    public func revokeAllSessions() async throws {
        try await send("DELETE", "me/sessions", body: Optional<Empty>.none)
        await tokens.signedOut()
    }
}
