import Foundation
import Testing

@testable import OwnAudioKit

/// Runs against a real own.audio server (1.0.0-beta.7 or later). Stubbed tests only prove we
/// parse JSON we wrote ourselves; this proves the server sends what the models expect.
///
/// Skipped unless configured:
///
/// ```
/// OWNAUDIO_HOST=https://music.example.com OWNAUDIO_EMAIL=someone@example.com \
///   OWNAUDIO_ACCOUNT_PASSWORD=… swift test --filter LiveServer
/// ```
@Suite("Live server", .enabled(if: LiveConfig.current != nil))
struct LiveServerTests {
    private func signedIn() async throws -> OwnAudioClient {
        let config = try #require(LiveConfig.current)
        let tokens = try await OwnAudioClient.signIn(host: config.host, email: config.email, password: config.password, device: .init(name: "OwnAudioKit live test"))
        return OwnAudioClient(host: config.host, tokens: TokenSession(tokens))
    }

    @Test("discovery, then sign-in, then the account")
    func signInAndMe() async throws {
        let config = try #require(LiveConfig.current)
        let discovery = try await OwnAudioClient.discover(host: config.host)
        #expect(discovery.v2 != nil)
        let client = try await signedIn()
        let me = try await client.me()
        #expect(me.email.lowercased() == config.email.lowercased())
        await client.signOut()
    }

    @Test("a wrong password is invalid_grant")
    func wrongPassword() async throws {
        let config = try #require(LiveConfig.current)
        do {
            _ = try await OwnAudioClient.signIn(host: config.host, email: config.email, password: config.password + "-wrong", device: .init(name: "x"))
            Issue.record("expected invalid_grant")
        } catch OwnAudioError.problem(let p) {
            #expect(p.code == "invalid_grant" || p.code == "account_locked")
        }
    }

    @Test("a pushed change comes back as a library event, then is undone")
    func pushAndEvents() async throws {
        let client = try await signedIn()
        let track = try #require(try await client.tracks(limit: 1).items.first)
        let favourites = try await client.all { try await client.favourites(.track, cursor: $0) }
        let was = favourites.contains { $0.id == track.id }
        let first = Task { () -> LiveEvent? in
            for try await event in client.events() { return event }
            return nil
        }
        // The stream starts from the newest change when it connects.
        try await Task.sleep(for: .seconds(2))
        let results = try await client.push([.favourite(.track, id: track.id, !was, at: Date(), clientId: "live-\(UUID())")])
        #expect(results.map(\.status) == ["ok"])
        let deadline = Task {
            try await Task.sleep(for: .seconds(20))
            first.cancel()
        }
        let event = try await first.value
        deadline.cancel()
        #expect(event?.type == "library")
        _ = try await client.push([.favourite(.track, id: track.id, was, at: Date(), clientId: "live-\(UUID())")])
        await client.signOut()
    }

    @Test("the catalogue and its records decode")
    func catalogue() async throws {
        let client = try await signedIn()
        let tracks = try await client.tracks(include: ["albums", "contributors"], limit: 20)
        let albums = try await client.albums(include: ["contributors"], limit: 20)
        _ = try await client.artists(limit: 20)
        _ = try await client.genres()
        if let first = tracks.items.first {
            let one = try await client.track(id: first.id)
            #expect(one.record.id == first.id)
        }
        if let album = albums.items.first {
            let one = try await client.album(id: album.id)
            #expect(one.record.id == album.id)
        }
        await client.signOut()
    }

    @Test("a favourite round trip, and the change feed sees it")
    func favouriteAndChanges() async throws {
        let client = try await signedIn()
        guard let book = try await client.books(limit: 1).items.first else { return }
        let start = try await client.changes(since: nil)
        try await client.setFavourite(.book, id: book.id, true)
        var seen: [Change] = []
        var cursor: String? = start.cursor
        for _ in 0..<5 {
            let page = try await client.changes(since: cursor)
            seen += page.changes
            cursor = page.cursor
            if !page.hasMore { break }
        }
        #expect(seen.contains { $0.kind == "favourite.book" && $0.id == book.id && $0.op == "upsert" })
        try await client.setFavourite(.book, id: book.id, false)
        await client.signOut()
    }

    @Test("playback info hands out a signed link that plays")
    func playback() async throws {
        let client = try await signedIn()
        guard let track = try await client.tracks(limit: 1).items.first else { return }
        let info = try await client.playbackInfo(trackId: track.id, capabilities: PlaybackCapabilities())
        #expect(info.decision == "direct")
        var request = URLRequest(url: info.url)
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect([200, 206].contains((response as? HTTPURLResponse)?.statusCode ?? 0))
        await client.signOut()
    }

    @Test("a snapshot streams begin, records, end")
    func snapshot() async throws {
        let client = try await signedIn()
        var begin = 0, end = 0, records = 0
        try await client.snapshot(kinds: ["genre", "favourite"]) { line in
            switch line {
            case .begin: begin += 1
            case .record: records += 1
            case .end: end += 1
            }
        }
        #expect(begin == 1 && end == 1 && records >= 0)
        await client.signOut()
    }
}

struct LiveConfig {
    let host: URL
    let email: String
    let password: String

    static var current: LiveConfig? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["OWNAUDIO_HOST"], let host = URL(string: raw),
              let email = env["OWNAUDIO_EMAIL"], let password = env["OWNAUDIO_ACCOUNT_PASSWORD"] else { return nil }
        return LiveConfig(host: host, email: email, password: password)
    }
}
