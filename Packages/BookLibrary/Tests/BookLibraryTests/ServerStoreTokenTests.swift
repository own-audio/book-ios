import AudiobookshelfKit
import Foundation
import OwnAudioKit
import Testing

@testable import BookLibrary

@Suite("Saved tokens", .serialized)
struct ServerStoreTokenTests {
    private func withStore(_ body: (ServerStore) async throws -> Void) async throws {
        let store = ServerStore(service: "audio.own.bookplayer.tests.\(UUID().uuidString)")
        defer { Task { await store.clear() } }
        try await body(store)
    }

    @Test("saving a record loaded before a refresh keeps the rotated own.audio tokens")
    func ownAudioKeepsRotated() async throws {
        try await withStore { store in
            let first = OwnAudioKit.Tokens(accessToken: "a1", refreshToken: "first", expiresAt: Date(), scope: "")
            let second = OwnAudioKit.Tokens(accessToken: "a2", refreshToken: "second", expiresAt: Date(), scope: "")
            let loaded = ServerRecord(displayName: "own.audio", kind: .ownAudio, host: URL(string: "https://books.example.com")!,
                                      auth: .ownAudio(username: "a@example.com", tokens: first))
            try await store.add(loaded)
            await store.updateTokens(serverId: loaded.id, ownAudio: second)

            var moved = loaded
            moved.connection = .fixed(URL(string: "http://192.168.1.20:8080")!)
            let saved = try await store.update(moved)

            #expect(saved.auth == .ownAudio(username: "a@example.com", tokens: second))
            #expect(await store.loadAll().first == saved)
        }
    }

    @Test("the same for Audiobookshelf, and signing in again replaces them")
    func audiobookshelf() async throws {
        try await withStore { store in
            let first = AudiobookshelfKit.Tokens(accessToken: "a1", refreshToken: "first", expiresAt: Date())
            let second = AudiobookshelfKit.Tokens(accessToken: "a2", refreshToken: "second", expiresAt: Date())
            let fresh = AudiobookshelfKit.Tokens(accessToken: "a3", refreshToken: "fresh", expiresAt: Date())
            let loaded = ServerRecord(displayName: "ABS", kind: .audiobookshelf, host: URL(string: "https://abs.example.com")!,
                                      auth: .audiobookshelf(username: "kim", tokens: first))
            try await store.add(loaded)
            await store.updateTokens(serverId: loaded.id, audiobookshelf: second)
            #expect(try await store.update(loaded).auth == .audiobookshelf(username: "kim", tokens: second))

            var signedIn = loaded
            signedIn.auth = .audiobookshelf(username: "kim", tokens: fresh)
            try await store.update(signedIn, signIn: true)
            #expect(await store.loadAll().first?.auth == signedIn.auth)
        }
    }
}
