import BookLibrary
import Foundation
import PlayerCore
import SpokenEngine
import Testing
@testable import OwnAudioBooks

/// When positions reach the server, and that none is lost on the way: offline, with a dead
/// server, with a kill between two checkpoints.
@MainActor
@Suite("Progress reporting")
struct ProgressReporterTests {
    private let server = UUID()
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("progress-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entry(_ positionMs: Int64, at seconds: TimeInterval, book: String = "b1", session: String? = "s1", listened: Int64 = 10_000) -> PendingProgress.Entry {
        PendingProgress.Entry(
            id: UUID().uuidString, serverId: server, bookId: book, sessionId: session, positionMs: positionMs, listenedMs: listened,
            durationMs: 3_600_000, finished: false, at: start.addingTimeInterval(seconds), closes: false
        )
    }

    // MARK: Cadence

    @Test("while playing, a report at the first tick and then once a minute")
    func periodicCadence() {
        let reporter = ProgressReporter(pending: PendingProgress(directory: directory()))
        var due: [Int] = []
        for second in stride(from: 10, through: 190, by: 10) {
            if reporter.record(entry(Int64(second) * 1000, at: TimeInterval(second)), reason: .periodic, now: start.addingTimeInterval(TimeInterval(second))) {
                due.append(second)
            }
        }
        #expect(due == [10, 70, 130, 190])
        #expect(reporter.pending.all().count == 1, "one entry per book and session, however many ticks")
        #expect(reporter.pending.all().first?.positionMs == 190_000)
        #expect(reporter.pending.all().first?.listenedMs == Int64(19 * 10_000), "the listening adds up")
    }

    @Test("pause, seek, chapter, stop, the end and going away are sent at once", arguments: [
        SpokenEngine.TickReason.pause, .seek, .chapter, .stop, .finished, .teardown,
    ])
    func eventsAreImmediate(reason: SpokenEngine.TickReason) {
        let reporter = ProgressReporter(pending: PendingProgress(directory: directory()))
        #expect(reporter.record(entry(10_000, at: 10), reason: .periodic, now: start.addingTimeInterval(10)))
        #expect(!reporter.record(entry(20_000, at: 20), reason: .periodic, now: start.addingTimeInterval(20)))
        #expect(reporter.record(entry(21_000, at: 21), reason: reason, now: start.addingTimeInterval(21)))
        // The minute counts again from that report.
        #expect(!reporter.record(entry(30_000, at: 30), reason: .periodic, now: start.addingTimeInterval(30)))
        #expect(reporter.record(entry(81_000, at: 81), reason: .periodic, now: start.addingTimeInterval(81)))
    }

    @Test("a book change is a stop of the old book: sent at once")
    func bookChange() {
        // SpokenEngine.load reports the book it lets go of with `.stop`.
        #expect(ProgressReporter.sendsNow(.stop, lastCheckpointAt: start, now: start.addingTimeInterval(1), interval: 60))
        #expect(!ProgressReporter.sendsNow(.periodic, lastCheckpointAt: start, now: start.addingTimeInterval(59), interval: 60))
        #expect(ProgressReporter.sendsNow(.periodic, lastCheckpointAt: nil, now: start, interval: 60))
    }

    // MARK: Sending

    @Test("what the server takes leaves the queue, with its answer passed on")
    func sent() async {
        let reporter = ProgressReporter(pending: PendingProgress(directory: directory()))
        var sent: [Int64] = []
        var answers = 0
        reporter.send = { entry in
            sent.append(entry.positionMs)
            return ListeningProgress(positionMs: entry.positionMs, finished: false, updatedAt: entry.at)
        }
        reporter.onAnswer = { _, answer in if answer != nil { answers += 1 } }
        reporter.record(entry(10_000, at: 10, book: "b1"), reason: .pause)
        reporter.record(entry(5_000, at: 5, book: "b2"), reason: .pause)
        await reporter.flush(isOffline: false)
        #expect(sent == [5_000, 10_000], "oldest first")
        #expect(answers == 2)
        #expect(reporter.pending.all().isEmpty)
    }

    @Test("offline, nothing is tried and everything stays on disk")
    func offline() async {
        let dir = directory()
        let reporter = ProgressReporter(pending: PendingProgress(directory: dir))
        var tries = 0
        reporter.send = { _ in tries += 1; return nil }
        for second in stride(from: 10, through: 300, by: 10) {
            if reporter.record(entry(Int64(second) * 1000, at: TimeInterval(second)), reason: .periodic, now: start.addingTimeInterval(TimeInterval(second))) {
                await reporter.flush(isOffline: true)
            }
        }
        #expect(tries == 0)
        let onDisk = PendingProgress(directory: dir).all()
        #expect(onDisk.count == 1)
        #expect(onDisk.first?.positionMs == 300_000)
        #expect(onDisk.first?.listenedMs == Int64(30 * 10_000))
    }

    @Test("a dead server is tried once a minute, not every tick, and the position stays")
    func deadServer() async {
        let dir = directory()
        let reporter = ProgressReporter(pending: PendingProgress(directory: dir))
        var tries = 0
        reporter.send = { _ in tries += 1; throw SourceError.network }
        for second in stride(from: 10, through: 180, by: 10) {
            if reporter.record(entry(Int64(second) * 1000, at: TimeInterval(second)), reason: .periodic, now: start.addingTimeInterval(TimeInterval(second))) {
                await reporter.flush(isOffline: false)
            }
        }
        #expect(tries == 3, "at 10, 70 and 130 s")
        #expect(PendingProgress(directory: dir).all().first?.positionMs == 180_000)
    }

    @Test("an unreachable server stops the pass: later entries wait too")
    func unreachableStopsThePass() async {
        let reporter = ProgressReporter(pending: PendingProgress(directory: directory()))
        var tries = 0
        reporter.send = { _ in tries += 1; throw SourceError.offline }
        reporter.record(entry(1_000, at: 1, book: "b1"), reason: .pause)
        reporter.record(entry(2_000, at: 2, book: "b2"), reason: .pause)
        await reporter.flush(isOffline: false)
        #expect(tries == 1)
        #expect(reporter.pending.all().count == 2)
    }

    @Test("a refused sign-in is reported and the position kept")
    func refused() async {
        let reporter = ProgressReporter(pending: PendingProgress(directory: directory()))
        var refused: [UUID] = []
        reporter.send = { _ in throw SourceError.signInRejected }
        reporter.onSignInRefused = { refused.append($0) }
        reporter.record(entry(1_000, at: 1), reason: .pause)
        await reporter.flush(isOffline: false)
        #expect(refused == [server])
        #expect(reporter.pending.all().count == 1)
    }

    @Test("a server that is not set up keeps its entries; the others are sent")
    func noServer() async {
        let other = UUID()
        let reporter = ProgressReporter(pending: PendingProgress(directory: directory()))
        reporter.send = { entry in
            if entry.serverId == other { throw ProgressReporter.NoServer() }
            return nil
        }
        var gone = entry(1_000, at: 1)
        gone = PendingProgress.Entry(id: gone.id, serverId: other, bookId: "x", sessionId: nil, positionMs: 1_000, listenedMs: 0, durationMs: 1, finished: false, at: gone.at, closes: false)
        reporter.record(gone, reason: .pause)
        reporter.record(entry(2_000, at: 2), reason: .pause)
        await reporter.flush(isOffline: false)
        #expect(reporter.pending.all().map(\.serverId) == [other])
    }

    @Test("a play session the server no longer knows: the position goes again without it")
    func sessionGone() async {
        let reporter = ProgressReporter(pending: PendingProgress(directory: directory()))
        var sessions: [String?] = []
        reporter.send = { entry in
            sessions.append(entry.sessionId)
            if entry.sessionId != nil { throw SourceError.notFound }
            return nil
        }
        reporter.record(entry(7_000, at: 7, session: "old"), reason: .pause)
        await reporter.flush(isOffline: false)
        #expect(sessions == ["old"])
        #expect(reporter.pending.all().map(\.sessionId) == [nil])
        #expect(reporter.pending.all().first?.positionMs == 7_000)
        await reporter.flush(isOffline: false)
        #expect(reporter.pending.all().isEmpty)
    }

    @Test("a pause while a report is on its way is sent right after it, not lost")
    func pauseDuringSlowReport() async {
        let reporter = ProgressReporter(pending: PendingProgress(directory: directory()))
        var sent: [(Int64, Int64)] = []
        var paused = false
        reporter.send = { entry in
            sent.append((entry.positionMs, entry.listenedMs))
            if !paused {
                // The listener pauses while the first report is still out.
                paused = true
                reporter.record(self.entry(15_000, at: 15, listened: 5_000), reason: .pause)
                await reporter.flush(isOffline: false)
            }
            return nil
        }
        reporter.record(entry(10_000, at: 10), reason: .periodic, now: start.addingTimeInterval(10))
        await reporter.flush(isOffline: false)
        #expect(sent.map(\.0) == [10_000, 15_000])
        #expect(sent.map(\.1) == [10_000, 5_000], "the listening already sent is not sent twice")
        #expect(reporter.pending.all().isEmpty)
    }

    // MARK: A kill between two checkpoints

    @Test("positions queued after the last checkpoint are found at the next launch")
    func recoveryAfterKill() {
        let dir = directory()
        let known = KnownPositions(directory: dir)
        let composite = BookID.make(serverId: server, bookId: "b1")
        known.set(composite, .init(positionMs: 60_000, finished: false, at: start.addingTimeInterval(60)))
        let pending = PendingProgress(directory: dir)
        pending.record(entry(90_000, at: 90))
        // Another book, saved at its last checkpoint: nothing to recover.
        let other = BookID.make(serverId: server, bookId: "b2")
        known.set(other, .init(positionMs: 5_000, finished: false, at: start.addingTimeInterval(5)))
        pending.record(entry(5_000, at: 5, book: "b2"))

        // The app is killed here; at launch the files are read again.
        let reloaded = KnownPositions(directory: dir)
        let recovered = ProgressReporter.newerThanSaved(PendingProgress(directory: dir).all()) { reloaded[$0] }
        #expect(Array(recovered.keys) == [composite])
        #expect(recovered[composite]?.positionMs == 90_000)
    }

    @Test("a book never checkpointed is recovered too; the newest of its sessions wins")
    func recoveryNewestSession() {
        let pending = PendingProgress(directory: directory())
        pending.record(entry(30_000, at: 30, session: "a"))
        pending.record(entry(40_000, at: 40, session: "b"))
        let recovered = ProgressReporter.newerThanSaved(pending.all()) { _ in nil }
        #expect(recovered.values.map(\.positionMs) == [40_000])
    }

    // MARK: The resume point

    @Test("the engine's resume point is kept in memory until a checkpoint writes it")
    func resumeCheckpoint() {
        let inner = InMemoryResumeStore()
        let store = CheckpointedResumeStore(inner)
        store.saveResume(containerId: "c", trackId: "t1", positionSecs: 10)
        store.saveResume(containerId: "c", trackId: "t1", positionSecs: 20)
        #expect(inner.loadResume(containerId: "c") == nil, "nothing written between checkpoints")
        #expect(store.loadResume(containerId: "c")?.positionSecs == 20, "but read back at once")
        store.commit()
        #expect(inner.loadResume(containerId: "c")?.positionSecs == 20)
        store.saveResume(containerId: "c", trackId: "t2", positionSecs: 30)
        store.clearResume(containerId: "c")
        store.commit()
        #expect(store.loadResume(containerId: "c") == nil)
        #expect(inner.loadResume(containerId: "c") == nil)
    }
}
