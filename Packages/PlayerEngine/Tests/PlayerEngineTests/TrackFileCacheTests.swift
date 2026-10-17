import Foundation
import Testing

@testable import PlayerCore
@testable import PlayerCore

@Suite("TrackFileCache")
struct TrackFileCacheTests {
    private func fixtureData(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test("the extension comes from the file's own bytes", arguments: [
        ("test-tone.mp3", "mp3"), ("test-tone.flac", "flac"), ("test-tone.m4a", "m4a"),
    ])
    func extensionFromMagic(fixture: String, expected: String) throws {
        #expect(TrackFileCache.fileExtension(prefix: try fixtureData(fixture)) == expected)
    }

    @Test("unknown bytes give no extension, so the content type is consulted")
    func unknownBytes() {
        #expect(TrackFileCache.fileExtension(prefix: Data("hello".utf8)) == nil)
        #expect(TrackFileCache.fileExtension(mimeType: "audio/x-flac") == "flac")
    }

    @Test("a mislabelled download is still saved as what it really is")
    func mislabelledDownload() async throws {
        let audio = try fixtureData("test-tone.m4a")
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: audio, headers: ["Content-Type": "audio/mpeg"])
        }
        let cache = TrackFileCache(
            remoteURL: { _ in URL(string: "https://music.example.com/rest/stream.view?id=1")! },
            session: mock.urlSession,
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString)")
        )
        let url = try await cache.localURL(trackId: "server/1")
        #expect(url.pathExtension == "m4a")
        #expect(await cache.existingLocalURL(trackId: "server/1")?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath())
        #expect(await mock.requestLog().count == 1)

        // A second request is a cache hit, not a second download.
        _ = try await cache.localURL(trackId: "server/1")
        #expect(await mock.requestLog().count == 1)
    }

    @Test("a downloaded copy is preferred over the network")
    func prefersDownloadedCopy() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 500, body: Data()) }
        let downloaded = URL(fileURLWithPath: "/tmp/downloaded.flac")
        let cache = TrackFileCache(remoteURL: { _ in URL(string: "https://x.example.com")! }, session: mock.urlSession)
        await cache.setLocalFileLookup { $0 == "t1" ? downloaded : nil }
        #expect(try await cache.localURL(trackId: "t1") == downloaded)
        #expect(await mock.requestLog().isEmpty)
    }
}

@Suite("TrackFileCache — size cap")
struct TrackFileCacheCapTests {
    @Test("over the cap, the files not used for longest go first")
    func evictsOldest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cache-cap-\(UUID().uuidString)", isDirectory: true)
        let cache = TrackFileCache(remoteURL: { _ in URL(string: "https://example.com/x")! }, cacheDirectory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, age) in [("old.mp3", 300.0), ("middle.mp3", 200.0), ("new.mp3", 100.0)] {
            let url = directory.appendingPathComponent(name)
            try Data(count: 1000).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        #expect(await cache.totalBytes() == 3000)
        await cache.enforce(capBytes: 2500)
        let left = Set((try FileManager.default.contentsOfDirectory(atPath: directory.path)))
        #expect(left == ["middle.mp3", "new.mp3"])
    }
}
