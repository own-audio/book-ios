import Foundation
import Testing

@testable import AudiobookshelfKit

/// Against a real Audiobookshelf, with a throwaway user (the tests play, write progress and
/// bookmarks, and leave the account as they found it). Skipped unless the environment names
/// one:
///
/// AUDIOBOOKSHELF_HOST=http://nas.local:13378 AUDIOBOOKSHELF_USERNAME=booktest \
///   AUDIOBOOKSHELF_PASSWORD=… swift test --filter LiveServer
@Suite("Live server", .serialized, .enabled(if: LiveConfig.current != nil))
struct LiveServerTests {
    private func signedIn() async throws -> (AudiobookshelfClient, SignIn) {
        let config = try #require(LiveConfig.current)
        let signIn = try await AudiobookshelfClient.signIn(host: config.host, username: config.username, password: config.password)
        return (AudiobookshelfClient(host: config.host, tokens: TokenSession(signIn.tokens)), signIn)
    }

    private func firstBook(_ client: AudiobookshelfClient) async throws -> (library: Library, item: LibraryItem) {
        let library = try #require(try await client.bookLibraries().first)
        let page = try await client.items(libraryId: library.id, limit: 1, sort: .duration)
        return (library, try #require(page.results.first))
    }

    @Test("status, then sign-in with rotating tokens, then authorize and me")
    func signInAndAccount() async throws {
        let config = try #require(LiveConfig.current)
        let status = try await AudiobookshelfClient.status(host: config.host)
        #expect(status.app == "audiobookshelf")
        let (client, signIn) = try await signedIn()
        if status.version >= .rotatingTokens {
            #expect(signIn.tokens.refreshToken != nil)
            #expect(signIn.tokens.expiresAt < Date().addingTimeInterval(2 * 3600))
        }
        let again = try await client.authorize()
        #expect(again.user.id == signIn.user.id)
        let me = try await client.me()
        #expect(me.username == config.username)
        await client.signOut()
    }

    @Test("a wrong password is refused")
    func wrongPassword() async throws {
        let config = try #require(LiveConfig.current)
        await #expect(throws: AudiobookshelfError.invalidCredentials) {
            _ = try await AudiobookshelfClient.signIn(host: config.host, username: config.username, password: "not-" + config.password)
        }
    }

    @Test("a refresh rotates the tokens and the new ones work")
    func refreshRotates() async throws {
        let (client, signIn) = try await signedIn()
        guard let refresh = signIn.tokens.refreshToken else { return }
        let fresh = try await client.tokens.refresh(using: client.refresher())
        #expect(fresh.refreshToken != refresh)
        #expect(fresh.accessToken != signIn.tokens.accessToken)
        _ = try await client.bookLibraries()
        await client.signOut()
    }

    @Test("the library: items page, a detail with tracks, series, authors, narrators, shelves, search, a cover")
    func library() async throws {
        let (client, _) = try await signedIn()
        let (library, row) = try await firstBook(client)
        let detail = try await client.item(id: row.id)
        #expect(detail.id == row.id)
        let tracks = try #require(detail.media.tracks)
        #expect(!tracks.isEmpty && tracks.allSatisfy { $0.duration > 0 })
        #expect(abs(tracks.map(\.duration).reduce(0, +) - detail.media.duration) < 2)
        let all = try await client.items(libraryId: library.id, limit: 5, sort: .added, descending: true)
        #expect(all.total > 0)
        _ = try await client.series(libraryId: library.id, limit: 3)
        _ = try await client.authors(libraryId: library.id)
        _ = try await client.narrators(libraryId: library.id)
        _ = try await client.collections(libraryId: library.id)
        let shelves = try await client.personalized(libraryId: library.id)
        #expect(shelves.contains { $0.id == "recently-added" })
        let hit = try await client.search(libraryId: library.id, String((row.media.metadata.title ?? "a").prefix(4)))
        #expect(!hit.book.isEmpty)
        let inProgress = try await client.items(libraryId: library.id, limit: 1, filter: .progress(.notStarted))
        #expect(inProgress.total >= 0)
        let token = try await client.freshToken()
        let (bytes, response) = try await URLSession.shared.data(from: client.coverURL(itemId: row.id, width: 64, token: token))
        #expect((response as? HTTPURLResponse)?.statusCode == 200 && bytes.count > 100)
        let first = try #require(tracks.first)
        var ranged = URLRequest(url: client.mediaURL(contentUrl: first.contentUrl, token: token))
        ranged.setValue("bytes=0-99", forHTTPHeaderField: "Range")
        let (chunk, rangedResponse) = try await URLSession.shared.data(for: ranged)
        #expect((rangedResponse as? HTTPURLResponse)?.statusCode == 206 && chunk.count == 100)
        await client.signOut()
    }

    @Test("progress and a bookmark, written and read back, then cleared")
    func progressAndBookmark() async throws {
        let (client, _) = try await signedIn()
        let (_, row) = try await firstBook(client)
        try await client.updateProgress(itemId: row.id, .init(currentTime: 42.5, duration: row.media.duration, isFinished: false))
        let read = try #require(try await client.progress(itemId: row.id))
        #expect(abs(read.currentTime - 42.5) < 0.01 && !read.isFinished)
        let made = try await client.createBookmark(itemId: row.id, time: 33, title: "live test")
        #expect(made.title == "live test")
        #expect(try await client.updateBookmark(itemId: row.id, time: 33, title: "renamed").title == "renamed")
        #expect(try await client.me().bookmarks.contains { $0.libraryItemId == row.id && $0.time == 33 })
        try await client.deleteBookmark(itemId: row.id, time: 33)
        #expect(try await client.me().bookmarks.contains { $0.libraryItemId == row.id && $0.time == 33 } == false)
        try await client.deleteProgress(progressId: read.id)
        #expect(try await client.progress(itemId: row.id) == nil)
        await client.signOut()
    }

    @Test("a play session reports and closes, then a local session moves the position")
    func sessions() async throws {
        let (client, signIn) = try await signedIn()
        let (library, row) = try await firstBook(client)
        let device = DeviceInfo(deviceId: "live-tests", clientName: "own.audio Books", clientVersion: "0.1.0")
        let session = try await client.play(itemId: row.id, device: device)
        #expect(session.libraryItemId == row.id && !session.audioTracks.isEmpty)
        try await client.syncSession(id: session.id, currentTime: 20, timeListened: 5, duration: session.duration)
        #expect(abs(((try await client.progress(itemId: row.id))?.currentTime ?? 0) - 20) < 0.01)
        try await client.closeSession(id: session.id, currentTime: 25, timeListened: 5, duration: session.duration)
        await #expect(throws: AudiobookshelfError.self) {
            try await client.syncSession(id: session.id, currentTime: 26, timeListened: 1, duration: session.duration)
        }
        let local = LocalSession(id: "local_" + UUID().uuidString.prefix(8), userId: signIn.user.id, libraryId: library.id, libraryItemId: row.id, displayTitle: session.displayTitle, displayAuthor: session.displayAuthor, duration: session.duration, deviceInfo: device, timeListening: 10, startTime: 25, currentTime: 35, startedAt: Date().addingTimeInterval(-15), updatedAt: Date())
        let results = try await client.sendLocalSessions([local], device: device)
        #expect(results.first?.success == true)
        #expect(abs(((try await client.progress(itemId: row.id))?.currentTime ?? 0) - 35) < 0.01)
        if let p = try await client.progress(itemId: row.id) { try await client.deleteProgress(progressId: p.id) }
        await client.signOut()
    }

    @Test("a forced transcode is one HLS track the player can fetch")
    func transcode() async throws {
        let (client, _) = try await signedIn()
        let (_, row) = try await firstBook(client)
        let device = DeviceInfo(deviceId: "live-tests", clientName: "own.audio Books", clientVersion: "0.1.0")
        let session = try await client.play(itemId: row.id, device: device, supportedMimeTypes: ["audio/mpeg"], forceTranscode: true)
        #expect(session.isHLS && session.audioTracks.count == 1)
        try await Task.sleep(for: .seconds(3))
        let (data, response) = try await URLSession.shared.data(from: client.mediaURL(contentUrl: session.audioTracks[0].contentUrl, token: try await client.freshToken()))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data.prefix(7), as: UTF8.self) == "#EXTM3U")
        try await client.closeSession(id: session.id, currentTime: 0, timeListened: 0, duration: session.duration)
        if let p = try await client.progress(itemId: row.id) { try await client.deleteProgress(progressId: p.id) }
        await client.signOut()
    }
}

struct LiveConfig {
    let host: URL
    let username: String
    let password: String

    static var current: LiveConfig? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["AUDIOBOOKSHELF_HOST"], let host = URL(string: raw),
              let username = env["AUDIOBOOKSHELF_USERNAME"], let password = env["AUDIOBOOKSHELF_PASSWORD"] else { return nil }
        return LiveConfig(host: host, username: username, password: password)
    }
}
