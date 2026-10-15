import Foundation
import Testing

@testable import OwnAudioKit

@Suite("Sessions")
struct SessionsTests {
    private let host = URL(string: "https://books.example.com")!

    @Test("the device list decodes, one device is signed out by id, everywhere signs this one out too")
    func sessions() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/v2/me/sessions"):
                return .init(statusCode: 200, body: Data(#"[{"id":"d1","device_kind":"ios","device_name":"iPhone","signed_in_at":"2026-10-15T20:00:00Z","last_used_at":"2026-10-15T21:00:00Z","expires_at":"2027-01-13T20:00:00Z","current":true},{"id":"d2","device_kind":"web","device_name":null,"signed_in_at":"2026-10-01T20:00:00Z","last_used_at":null,"expires_at":"2026-12-30T20:00:00Z","current":false}]"#.utf8), headers: ["Content-Type": "application/json"])
            case ("DELETE", "/api/v2/me/sessions/d2"), ("DELETE", "/api/v2/me/sessions"):
                return .init(statusCode: 204, body: Data())
            default:
                return .init(statusCode: 404, body: Data())
            }
        }
        let tokens = TokenSession(Tokens(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600), scope: ""))
        let client = OwnAudioClient(host: host, tokens: tokens, session: mock.urlSession)
        let list = try await client.sessions()
        #expect(list.map(\.id) == ["d1", "d2"])
        #expect(list[0].current && list[0].deviceName == "iPhone")
        #expect(list[1].deviceName == nil && list[1].lastUsedAt == nil)
        try await client.revokeSession(id: "d2")
        try await client.revokeAllSessions()
        #expect(await tokens.current == nil)
        #expect(await mock.requestLog().map { "\($0.httpMethod!) \($0.url!.path)" } == ["GET /api/v2/me/sessions", "DELETE /api/v2/me/sessions/d2", "DELETE /api/v2/me/sessions"])
    }
}
