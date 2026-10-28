import Foundation
import Testing

@testable import OwnAudioKit

@Suite("Account")
struct AccountTests {
    private let host = URL(string: "https://books.example.com")!

    private func client(_ mock: MockURLProtocol.StubbedSession, tokens: TokenSession) -> OwnAudioClient {
        OwnAudioClient(host: host, tokens: tokens, session: mock.urlSession)
    }

    private func tokens() -> TokenSession {
        TokenSession(Tokens(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600), scope: ""))
    }

    @Test("the statistics are asked of /api/v1 with the range and the phone's offset, and decode")
    func stats() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            switch request.url?.path {
            case "/api/v1/stats/me":
                return .init(statusCode: 200, body: Data(#"{"range":"30d","total_seconds":5400,"by_kind":[{"media_kind":"audiobook","seconds":5400,"sessions":3}],"by_day":[{"day":"2026-10-27","seconds":5400}],"top_items":[{"media_kind":"audiobook","item_id":"b1","title":null,"seconds":5400,"sessions":3}],"streak_days":2,"completed_items":1,"stats_visibility":"private"}"#.utf8))
            case "/api/v1/stats/family":
                return .init(statusCode: 200, body: Data(#"[{"user_id":"u1","display_name":"Anna","display_label":null,"total_seconds":null,"by_kind":null,"hidden":true}]"#.utf8))
            default:
                return .init(statusCode: 404, body: Data())
            }
        }
        let client = client(mock, tokens: tokens())
        let stats = try await client.listeningStats(.month, timeZone: TimeZone(secondsFromGMT: 3600)!)
        #expect(stats.totalSeconds == 5400 && stats.streakDays == 2 && stats.completedItems == 1)
        #expect(stats.topItems.first?.title == nil)
        #expect(stats.statsVisibility == "private")
        let query = await mock.firstQuery()
        #expect(query.first { $0.name == "range" }?.value == "30d")
        #expect(query.first { $0.name == "tz_offset_minutes" }?.value == "60")
        let family = try await client.familyListening(.all)
        #expect(family.first?.name == "Anna" && family.first?.totalSeconds == nil)
    }

    @Test("an older server without the visibility field still decodes")
    func oldServer() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Data(#"{"range":"7d","total_seconds":0,"by_kind":[],"by_day":[],"top_items":[],"streak_days":0,"completed_items":0}"#.utf8))
        }
        let stats = try await client(mock, tokens: tokens()).listeningStats(.week)
        #expect(stats.statsVisibility == nil)
    }

    @Test("deleting the account is DELETE /api/v1/users/me and signs out; the last admin gets 400")
    func delete() async throws {
        let ok = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 204, body: Data()) }
        let session = tokens()
        try await client(ok, tokens: session).deleteAccount()
        #expect(await session.current == nil)
        #expect(await ok.requestLog().map { "\($0.httpMethod!) \($0.url!.path)" } == ["DELETE /api/v1/users/me"])

        let refused = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 400, body: Data(#"{"error":"last admin"}"#.utf8)) }
        let kept = tokens()
        await #expect(throws: OwnAudioError.http(400)) { try await client(refused, tokens: kept).deleteAccount() }
        #expect(await kept.current != nil)
    }
}
