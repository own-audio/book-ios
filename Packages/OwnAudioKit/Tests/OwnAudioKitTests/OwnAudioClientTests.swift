import Foundation
import Testing

@testable import OwnAudioKit

@Suite("OwnAudioClient")
struct OwnAudioClientTests {
    private let host = URL(string: "https://music.example.com")!

    private func json(_ text: String, status: Int = 200, type: String = "application/json") -> MockURLProtocol.StubbedResponse {
        .init(statusCode: status, body: Data(text.utf8), headers: ["Content-Type": type])
    }

    private func tokenJSON(access: String = "a1", refresh: String = "r1") -> String {
        #"{"access_token":"\#(access)","token_type":"Bearer","expires_in":3600,"refresh_token":"\#(refresh)","scope":"library:read playback"}"#
    }

    private func form(_ request: URLRequest) -> [String: String] {
        let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        } ?? Data()
        var out: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            if parts.count == 2 { out[parts[0]] = parts[1] }
        }
        return out
    }

    actor Kept: TokenKeeper {
        var saved: [Tokens?] = []
        func save(_ tokens: Tokens?) async { saved.append(tokens) }
    }

    // MARK: - Before signing in

    @Test("discovery finds the v2 API")
    func discovery() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            #expect(request.url?.path == "/.well-known/own-audio")
            return json(#"{"id":"s1","name":"own.audio","edition":"core","version":"1.0.0-beta.7","api":[{"version":1,"path":"/api/v1","revision":8,"status":"stable"},{"version":2,"path":"/api/v2","revision":0,"status":"draft"}],"auth":{"password":true,"providers":["google"],"device_grant":true,"totp":true,"password_reset":false},"modules":{},"addresses":[{"url":"https://music.example.com","scope":"public"}],"limits":{"list_limit_default":100,"list_limit_max":500,"upload_max_bytes":5368709120,"batch_max":500}}"#)
        }
        let d = try await OwnAudioClient.discover(host: host, session: mock.urlSession)
        #expect(d.v2?.path == "/api/v2")
        #expect(d.auth.providers == ["google"])
        #expect(d.limits.listLimitMax == 500)
    }

    @Test("password sign-in is a form, answered with tokens")
    func signIn() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in json(tokenJSON()) }
        let tokens = try await OwnAudioClient.signIn(host: host, email: "a@example.com", password: "p w&", device: .init(name: "Phone"), session: mock.urlSession)
        let sent = await mock.requestLog().first!
        #expect(sent.url?.path == "/api/v2/auth/token")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let fields = form(sent)
        #expect(fields["grant_type"] == "password")
        #expect(fields["username"] == "a@example.com")
        #expect(fields["password"] == "p w&")
        #expect(tokens.accessToken == "a1")
        #expect(abs(tokens.expiresAt.timeIntervalSinceNow - 3600) < 5)
    }

    @Test("two-factor: the first step asks for the code")
    func twoFactor() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            json(#"{"type":"urn:own-audio:problem:mfa_required","title":"Forbidden","status":403,"code":"mfa_required","error":"mfa_required","mfa_token":"m1","mfa_methods":["totp","recovery"]}"#,
                 status: 403, type: "application/problem+json")
        }
        await #expect(throws: OwnAudioError.twoFactorRequired(mfaToken: "m1", methods: ["totp", "recovery"])) {
            _ = try await OwnAudioClient.signIn(host: host, email: "a", password: "b", device: .init(name: "Phone"), session: mock.urlSession)
        }
    }

    @Test("a wrong password is invalid_grant")
    func wrongPassword() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            json(#"{"type":"urn:own-audio:problem:invalid_grant","title":"Bad Request","status":400,"code":"invalid_grant","error":"invalid_grant"}"#, status: 400, type: "application/problem+json")
        }
        do {
            _ = try await OwnAudioClient.signIn(host: host, email: "a", password: "b", device: .init(name: "Phone"), session: mock.urlSession)
            Issue.record("expected an error")
        } catch OwnAudioError.problem(let p) {
            #expect(p.code == "invalid_grant")
        }
    }

    // MARK: - Tokens

    @Test("a 401 is answered with one refresh and one retry; the rotated tokens are kept")
    func refreshOn401() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            if request.url?.path == "/api/v2/auth/token" { return json(tokenJSON(access: "a2", refresh: "r2")) }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer a1" {
                return json(#"{"type":"urn:own-audio:problem:unauthorized","title":"Unauthorized","status":401,"code":"unauthorized"}"#, status: 401)
            }
            return json(#"{"id":"u1","email":"a@example.com","display_name":"A","family":{"id":"f1","role":"admin","can_upload":true}}"#)
        }
        let kept = Kept()
        let session = TokenSession(Tokens(accessToken: "a1", refreshToken: "r1", expiresAt: Date().addingTimeInterval(3000), scope: ""), keeper: kept)
        let client = OwnAudioClient(host: host, tokens: session, session: mock.urlSession)
        let me = try await client.me()
        #expect(me.family.role == "admin")
        #expect(await session.current?.refreshToken == "r2")
        let saved = await kept.saved
        #expect(saved.compactMap { $0?.refreshToken } == ["r2"])
    }

    @Test("requests that find the token expired share one refresh")
    func singleFlightRefresh() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            if request.url?.path == "/api/v2/auth/token" {
                try await Task.sleep(for: .milliseconds(100))
                return json(tokenJSON(access: "a2", refresh: "r2"))
            }
            return json(#"{"items":[]}"#)
        }
        let session = TokenSession(Tokens(accessToken: "a1", refreshToken: "r1", expiresAt: Date().addingTimeInterval(-10), scope: ""))
        let client = OwnAudioClient(host: host, tokens: session, session: mock.urlSession)
        async let one = client.genres()
        async let two = client.genres()
        async let three = client.genres()
        _ = try await (one, two, three)
        let refreshes = await mock.requestLog().filter { $0.url?.path == "/api/v2/auth/token" }
        #expect(refreshes.count == 1)
        let bearers = await mock.requestLog().compactMap { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(bearers.allSatisfy { $0 == "Bearer a2" })
    }

    @Test("a refused refresh signs out")
    func refusedRefresh() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            json(#"{"type":"urn:own-audio:problem:invalid_grant","title":"Bad Request","status":400,"code":"invalid_grant"}"#, status: 400)
        }
        let kept = Kept()
        let session = TokenSession(Tokens(accessToken: "a1", refreshToken: "r1", expiresAt: Date().addingTimeInterval(-10), scope: ""), keeper: kept)
        let client = OwnAudioClient(host: host, tokens: session, session: mock.urlSession)
        await #expect(throws: OwnAudioError.signedOut) { _ = try await client.me() }
        #expect(await session.current == nil)
        let saved = await kept.saved
        #expect(saved.count == 1 && saved.first! == nil)
    }

    // MARK: - Records

    @Test("a page of tracks decodes, times with fractions included")
    func tracksPage() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            #expect(request.url?.query?.contains("include=albums") == true)
            return json(#"{"items":[{"id":"t1","title":"One","album_id":"al1","recording_id":null,"credits":[{"contributor_id":"c1","role":"artist","position":0,"join_phrase":" feat. "},{"contributor_id":"c2","role":"featured","position":1,"join_phrase":""}],"genre_ids":["g1"],"disc_number":1,"track_number":3,"duration_ms":180000,"visibility":"family","owner_id":"u1","source":"upload","content_type":"audio/flac","size_bytes":123,"image":null,"created_at":"2026-10-11T12:00:00.123456Z","updated_at":"2026-10-11T12:00:00Z"}],"next":"abc","included":{"albums":[{"id":"al1","title":"A","credits":[],"release_group_id":"rg1","release_date":null,"country":null,"label":null,"barcode":null,"is_compilation":false,"musicbrainz_release_id":null,"track_count":1,"duration_ms":180000,"disc_count":1,"image":null,"created_at":"2026-10-11T12:00:00Z"}]}}"#)
        }
        let client = OwnAudioClient(host: host, tokens: TokenSession(Tokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture, scope: "")), session: mock.urlSession)
        let page = try await client.tracks(include: ["albums"])
        #expect(page.items.first?.credits.map(\.role) == ["artist", "featured"])
        #expect(page.items.first?.durationMs == 180000)
        #expect(page.next == "abc")
        #expect(page.included?.albums?.first?.releaseGroupId == "rg1")
    }

    @Test("progress goes as snake_case JSON")
    func progressBody() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            json(#"{"progress":{"kind":"track","id":"t1","position_ms":30000,"finished":false,"updated_at":"2026-10-11T12:00:00Z"},"applied":true}"#)
        }
        let client = OwnAudioClient(host: host, tokens: TokenSession(Tokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture, scope: "")), session: mock.urlSession)
        let answer = try await client.saveProgress(.track, id: "t1", positionMs: 30000)
        #expect(answer.applied)
        let sent = await mock.requestLog().first!
        #expect(sent.httpMethod == "PUT")
        #expect(sent.url?.path == "/api/v2/me/progress/track/t1")
    }

    @Test("offline changes go as one push, each change snake_case, answered in order")
    func push() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            json(#"[{"client_id":"f1","status":"ok"},{"client_id":"p1","status":"duplicate"}]"#)
        }
        let client = OwnAudioClient(host: host, tokens: TokenSession(Tokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture, scope: "")), session: mock.urlSession)
        let at = Date(timeIntervalSince1970: 1_791_000_000)
        let results = try await client.push([
            .favourite(.album, id: "al1", false, at: at, clientId: "f1"),
            .play(Play(clientId: "p1", kind: .track, id: "t1", startedAt: at, endedAt: at.addingTimeInterval(200), listenedMs: 190_000)),
        ])
        #expect(results.map(\.status) == ["ok", "duplicate"])
        let sent = await mock.requestLog().first!
        #expect(sent.url?.path == "/api/v2/sync/push")
        let body = try #require(sent.httpBody ?? sent.httpBodyStream.map { stream -> Data in
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            return data
        })
        let changes = try #require((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["changes"] as? [[String: Any]])
        #expect(changes[0]["op"] as? String == "unfavourite" && changes[0]["kind"] as? String == "album")
        #expect(changes[0]["rating"] == nil, "what a change doesn't have is left out")
        #expect(changes[1]["listened_ms"] as? Int == 190_000 && changes[1]["client_id"] as? String == "p1")
    }

    @Test("event stream: fields until a blank line, comments skipped, CRLF too")
    func eventStream() {
        var parser = EventStreamParser()
        let text = ": keep-alive\n\nevent: library\nid: 41\ndata: {\"seq\":41}\n\r\nevent: library\r\nid: 42\r\ndata: a\r\ndata: b\r\n\r\n"
        let events = Array(text.utf8).compactMap { parser.feed($0) }
        #expect(events == [
            LiveEvent(type: "library", id: "41", data: #"{"seq":41}"#),
            LiveEvent(type: "library", id: "42", data: "a\nb"),
        ])
    }

    @Test("events: the stream's library events arrive, with the bearer and Last-Event-ID")
    func events() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            #expect(request.value(forHTTPHeaderField: "Last-Event-ID") == "40")
            return .init(statusCode: 200, body: Data("event: library\nid: 41\ndata: {\"seq\":41}\n\n".utf8), headers: ["Content-Type": "text/event-stream"])
        }
        let client = OwnAudioClient(host: host, tokens: TokenSession(Tokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture, scope: "")), session: mock.urlSession)
        var received: [LiveEvent] = []
        for try await event in client.events(lastEventId: "40") { received.append(event) }
        #expect(received.map(\.id) == ["41"])
        #expect(await mock.requestLog().first?.value(forHTTPHeaderField: "Authorization") == "Bearer a")
    }

    @Test("snapshot lines: begin, record, end")
    func snapshotLines() throws {
        guard case .begin(let c)? = try OwnAudioClient.snapshotLine(#"{"type":"begin","cursor":"c1"}"#) else { Issue.record("begin"); return }
        #expect(c == "c1")
        guard case .record(let kind, let id, let record)? = try OwnAudioClient.snapshotLine(#"{"type":"record","kind":"favourite.track","id":"t1","record":{"kind":"track","id":"t1","created_at":"2026-10-11T12:00:00Z"}}"#) else {
            Issue.record("record"); return
        }
        #expect(kind == "favourite.track" && id == "t1")
        let change = Change(kind: kind, id: id, op: "upsert", record: record)
        #expect(try change.decode(Favourite.self)?.id == "t1")
        guard case .end? = try OwnAudioClient.snapshotLine(#"{"type":"end","cursor":"c1"}"#) else { Issue.record("end"); return }
    }
}
