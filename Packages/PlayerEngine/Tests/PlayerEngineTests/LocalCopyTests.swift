import Foundation
import Testing

@testable import PlayerCore
@testable import SpokenEngine

/// O1: a part plays from a copy on the phone whenever there is one — asked for on a seek into
/// another part, used when a download finishes mid-book, and a part with no copy and no link
/// asks the app instead of failing in the player.
@Suite("Local copies", .serialized)
@MainActor
struct LocalCopyTests {
    final class Asked: @unchecked Sendable { var ids: [String] = [] }

    struct NoNetwork: LocalizedError {
        var errorDescription: String? { "This part is not on this iPhone." }
    }

    private func engine() -> SpokenEngine {
        let engine = SpokenEngine(nowPlaying: NowPlayingController(), resumeStore: InMemoryResumeStore())
        engine.tickIntervalSecs = 0.5
        return engine
    }

    /// The first part on the phone, the second only as a link that leads nowhere.
    private func halfStreamedBook() -> SpokenBook {
        SpokenBook(id: "book1", title: "T", author: nil, parts: [
            SpokenPart(id: "p1", url: fixture("test-part-2s.m4a"), durationMs: 2000),
            SpokenPart(id: "p2", url: URL(string: "https://example.invalid/p2.m4b")!, durationMs: 6000),
        ], chapters: [])
    }

    @Test("a seek into another part asks the locator and plays from the copy it names")
    func seekIntoDownloadedPart() async {
        let engine = engine()
        let asked = Asked()
        engine.partLocator = { _, partId in
            asked.ids.append(partId)
            return partId == "p2" ? fixture("test-book.m4b") : nil
        }
        engine.load(halfStreamedBook(), at: 0, autoplay: false)
        engine.seek(to: 3000)
        #expect(await wait(until: { engine.loadedURL?.isFileURL == true && engine.loadedURL?.lastPathComponent == "test-book.m4b" }))
        #expect(asked.ids == ["p2"])
        engine.play()
        #expect(await wait(until: { engine.positionMs > 3300 }), "plays on inside the located copy")
        #expect(engine.errorMessage == nil)
        engine.stop()
    }

    @Test("a download that finishes while an earlier part plays is used when its turn comes")
    func downloadFinishesForLaterPart() async {
        let engine = engine()
        engine.load(halfStreamedBook(), at: 500, autoplay: true)
        #expect(await wait(until: { engine.isPlaying && engine.positionMs > 550 }))
        #expect(engine.positionMs < 2000, "still in the first part")
        engine.useLocalCopy(partId: "p2", at: fixture("test-book.m4b"))
        #expect(engine.book?.timeline.parts[1].url.isFileURL == true)
        #expect(await wait(until: { engine.positionMs > 2400 }, seconds: 10), "the second part plays from the new copy")
        #expect(engine.errorMessage == nil && engine.isPlaying)
        engine.stop()
    }

    @Test("a download of the part playing now is switched to at the next pause, not mid-sentence")
    func downloadFinishesForCurrentPart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("copies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let streamed = directory.appendingPathComponent("streamed.m4b")
        let downloaded = directory.appendingPathComponent("downloaded.m4b")
        try FileManager.default.copyItem(at: fixture("test-book.m4b"), to: streamed)
        try FileManager.default.copyItem(at: fixture("test-book.m4b"), to: downloaded)
        let engine = engine()
        let book = SpokenBook(id: "book1", title: "T", author: nil, parts: [SpokenPart(id: "p1", url: streamed, durationMs: 6000)], chapters: [])
        engine.load(book, at: 1000, autoplay: true)
        #expect(await wait(until: { engine.isPlaying && engine.positionMs > 1100 }))
        engine.useLocalCopy(partId: "p1", at: downloaded)
        #expect(engine.loadedURL == streamed, "still the item it was playing")
        #expect(await wait(until: { engine.positionMs > 1500 }), "and it keeps playing")
        engine.pause()
        let paused = engine.positionMs
        #expect(engine.loadedURL == downloaded, "switched while quiet")
        engine.play()
        #expect(await wait(until: { engine.positionMs > paused + 200 }), "plays on from the same place")
        #expect(engine.errorMessage == nil)
        engine.stop()
    }

    @Test("a part with no copy and no link asks the app; with no network its reason is shown, no crash")
    func unresolvedPart() async {
        let engine = engine()
        let book = SpokenBook(id: "book1", title: "T", author: nil, parts: [
            SpokenPart(id: "p1", url: fixture("test-part-2s.m4a"), durationMs: 2000),
            .unresolved(id: "p2", durationMs: 6000),
        ], chapters: [])
        let refreshed = Asked()
        engine.partRefresher = { _, partId in
            refreshed.ids.append(partId)
            throw NoNetwork()
        }
        engine.load(book, at: 1500, autoplay: true)
        #expect(await wait(until: { engine.errorMessage != nil }, seconds: 10), "reaching the missing part stops with a message")
        #expect(engine.errorMessage == "This part is not on this iPhone.")
        #expect(refreshed.ids == ["p2"] && !engine.isPlaying)
        #expect(engine.positionMs == 2000, "waits at the start of the missing part")

        // The download arrives: the part plays from it.
        engine.useLocalCopy(partId: "p2", at: fixture("test-book.m4b"))
        engine.play()
        #expect(await wait(until: { engine.positionMs > 2300 }), "plays once the copy is there")
        engine.stop()
    }

    @Test("a file that can't be played asks for one fresh link, then shows the error instead of asking again and again")
    func oneFreshLinkPerFailure() async {
        let engine = engine()
        let asked = Asked()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).mp3")
        engine.partRefresher = { _, partId in
            asked.ids.append(partId)
            return missing
        }
        engine.load(SpokenBook(id: "ep1", title: "T", author: nil, parts: [SpokenPart(id: "audio", url: missing, durationMs: 3000)], chapters: []), at: 0, autoplay: true)
        #expect(await wait(until: { engine.errorMessage != nil }, seconds: 8), "the failure is shown")
        try? await Task.sleep(for: .seconds(2))
        #expect(asked.ids.count == 1, "asked \(asked.ids.count) times")
        #expect(!engine.isPlaying)
        engine.stop()
    }
}
