import Foundation
import Testing

@testable import PlayerCore
@testable import SpokenEngine

@Suite("Signal wait")
struct SignalWaitTests {
    @Test("lost while playing: paused and waiting; the window's bytes back: plays on")
    func windowComesBack() {
        var wait = SignalWait()
        #expect(wait.handle(.lost(.hold, wasPlaying: true)) == .pause)
        #expect(wait.isWaiting && wait.resumes)
        #expect(wait.handle(.lost(.hold, wasPlaying: false)) == .none, "lost again changes nothing")
        #expect(wait.handle(.fed) == .resume)
        #expect(!wait.isWaiting)
        #expect(wait.handle(.fed) == .none, "fed with nothing waiting")
    }

    @Test("the network returns: the window plays on at once; a reload is tried now")
    func networkReturns() {
        var window = SignalWait()
        _ = window.handle(.lost(.hold, wasPlaying: true))
        #expect(window.handle(.networkReturned) == .resume && !window.isWaiting)
        var reload = SignalWait()
        _ = reload.handle(.lost(.reload, wasPlaying: true))
        #expect(reload.handle(.networkReturned) == .reloadNow && reload.isWaiting, "waiting until the reload works")
        #expect(reload.handle(.reloaded) == .none && !reload.isWaiting)
    }

    @Test("paused by the listener while waiting: the signal returning does not play")
    func listenerPaused() {
        var wait = SignalWait()
        _ = wait.handle(.lost(.hold, wasPlaying: true))
        _ = wait.handle(.userPaused)
        #expect(!wait.resumes)
        #expect(wait.handle(.networkReturned) == .nudgeWindow, "only fetches, no playing")
        var reload = SignalWait()
        _ = reload.handle(.lost(.reload, wasPlaying: true))
        _ = reload.handle(.userPaused)
        #expect(reload.handle(.networkReturned) == .reloadNow && !reload.resumes, "loaded again, paused")
    }

    @Test("not playing when lost: waiting, but nothing to pause or resume")
    func lostWhilePaused() {
        var wait = SignalWait()
        #expect(wait.handle(.lost(.reload, wasPlaying: false)) == .none)
        #expect(wait.isWaiting && !wait.resumes)
    }

    @Test("play while waiting: a reload is tried now; the window plays what it can")
    func listenerPlays() {
        var reload = SignalWait()
        _ = reload.handle(.lost(.reload, wasPlaying: false))
        #expect(reload.handle(.userPlayed) == .reloadNow && reload.resumes)
        var window = SignalWait()
        _ = window.handle(.lost(.hold, wasPlaying: true))
        #expect(window.handle(.userPlayed) == .nudgeWindow && !window.isWaiting)
    }

    @Test("the item failing while the window waits makes it a reload; a reset ends it all")
    func escalation() {
        var wait = SignalWait()
        _ = wait.handle(.lost(.hold, wasPlaying: true))
        _ = wait.handle(.lost(.reload, wasPlaying: false))
        #expect(wait.way == .reload && wait.resumes, "still plays on when it comes back")
        _ = wait.handle(.reset)
        #expect(!wait.isWaiting && !wait.resumes)
    }
}

/// O3: the window runs out with no network — the engine waits, then plays on by itself.
@Suite("Riding out a gap", .serialized)
@MainActor
struct SignalGapTests {
    final class Seen: @unchecked Sendable {
        var positions: [SpokenEngine.Position] = []
        var refreshes = 0
    }

    struct NoSignal: NetworkUnavailable {}

    private func setUp(_ server: RangeServer, seen: Seen) async -> SpokenEngine {
        let session = await MockURLProtocol.makeStubbedSession { request in try server.respond(request) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gap-\(UUID().uuidString)", isDirectory: true)
        let window = StreamWindow(directory: folder, session: session.urlSession, servingChunkBytes: 4096, prefetchChunkBytes: 4096)
        let engine = SpokenEngine(nowPlaying: NowPlayingController(), resumeStore: InMemoryResumeStore())
        engine.window = window
        engine.forwardBufferSecs = 1
        engine.tickIntervalSecs = 0.5
        engine.smartRewind = SmartRewind(isEnabled: false)
        engine.onPosition = { seen.positions.append($0) }
        return engine
    }

    private func book() -> SpokenBook {
        SpokenBook(id: "book1", title: "T", author: nil, parts: [
            SpokenPart(id: "p1", url: URL(string: "https://server.example/files/book.m4b?token=t")!, durationMs: 6000, streamsByRange: true),
        ], chapters: [])
    }

    private func gap(failure: URLError.Code) async throws {
        let server = RangeServer()
        try server.add("/files/book.m4b", fixture: "test-book.m4b", type: "audio/mp4")
        server.failure = failure
        // The head and a few seconds of audio, then nothing.
        server.cutAfter = 4
        let seen = Seen()
        let engine = await setUp(server, seen: seen)
        engine.load(book(), at: 0, autoplay: true)
        #expect(await wait(until: { engine.isWaitingForSignal }, seconds: 20), "the window runs out: waiting")
        #expect(engine.errorMessage == nil, "waiting, not failed")
        #expect(engine.book?.timeline.parts.isEmpty == false, "the book and its item are held")
        let stoppedAt = engine.positionMs
        // How far it got before the bytes ran out depends on how much the player wants buffered
        // before it starts, which varies with the load on the machine.
        #expect(stoppedAt < 6000, "stopped inside the book: \(stoppedAt) \(server.ranges)")
        #expect(seen.positions.last?.reason == .pause && abs((seen.positions.last?.positionMs ?? -1) - stoppedAt) < 600, "the position is reported, for the disk first")

        // Two seconds of waiting are not listening.
        try await Task.sleep(for: .seconds(2))
        server.cutAfter = nil
        server.offline = false
        engine.networkChanged(isConnected: true)
        #expect(await wait(until: { engine.isPlaying && engine.positionMs > stoppedAt + 500 }, seconds: 15), "plays on by itself")
        #expect(!engine.isWaitingForSignal && engine.errorMessage == nil)
        engine.pause()
        // Listening reported after the wait began: the replay since the signal came back only.
        let waitBegan = seen.positions.firstIndex { $0.reason == .pause } ?? 0
        let listened = seen.positions[(waitBegan + 1)...].reduce(0) { $0 + $1.listenedMs }
        #expect(listened < 2000, "the wait was not counted: \(listened) ms")
        engine.stop()
    }

    @Test("no network: paused with no signal, then on by itself when it returns")
    func noNetwork() async throws {
        try await gap(failure: .notConnectedToInternet)
    }

    @Test("a dead server: the same wait, the position kept")
    func deadServer() async throws {
        try await gap(failure: .cannotConnectToHost)
    }

    @Test("paused by the listener during the wait: the signal returning does not start it")
    func listenerPausedDuringWait() async throws {
        let server = RangeServer()
        try server.add("/files/book.m4b", fixture: "test-book.m4b", type: "audio/mp4")
        server.cutAfter = 2
        let engine = await setUp(server, seen: Seen())
        engine.load(book(), at: 0, autoplay: true)
        #expect(await wait(until: { engine.isWaitingForSignal }, seconds: 20))
        engine.pause()
        server.cutAfter = nil
        server.offline = false
        engine.networkChanged(isConnected: true)
        try await Task.sleep(for: .seconds(2))
        #expect(!engine.isPlaying, "stays paused")
        engine.play()
        #expect(await wait(until: { engine.isPlaying && !engine.isWaitingForSignal }))
        engine.stop()
    }

    @Test("a part not on the phone with no network waits, and is tried again 2 s later by itself")
    func reloadBacksOff() async {
        let seen = Seen()
        let engine = SpokenEngine(nowPlaying: NowPlayingController(), resumeStore: InMemoryResumeStore())
        engine.partRefresher = { _, _ in
            seen.refreshes += 1
            if seen.refreshes == 1 { throw NoSignal() }
            return fixture("test-book.m4b")
        }
        let missing = SpokenBook(id: "book1", title: "T", author: nil, parts: [.unresolved(id: "p1", durationMs: 6000)], chapters: [])
        engine.load(missing, at: 1000, autoplay: true)
        #expect(await wait(until: { engine.isWaitingForSignal }), "no error, a wait")
        #expect(engine.errorMessage == nil && !engine.isPlaying)
        #expect(await wait(until: { engine.isPlaying && engine.positionMs > 1200 }, seconds: 8), "the retry after 2 s brings it, and it plays")
        #expect(seen.refreshes == 2 && !engine.isWaitingForSignal)
        engine.stop()
    }
}
