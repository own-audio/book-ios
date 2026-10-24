import BookLibrary
import Foundation
import PlayerCore
import SpokenEngine

/// When positions go to the server, and how. Every position the engine reports is recorded in
/// `PendingProgress` first (one file); it is sent at once when something happened — pause,
/// seek, chapter, stop, a book change, the end, going to the background — and while a book just
/// plays, at most every `interval`. Between two reports the phone's radio can sleep, and a
/// position is still never lost: what was not sent stays on disk for the next try.
@MainActor
final class ProgressReporter {
    /// Thrown by `send` when the entry's server isn't set up right now: the entry stays queued.
    struct NoServer: Error {}

    /// While playing, a report at most this often. Audiobookshelf's own apps sync their play
    /// sessions about as often.
    var interval: TimeInterval = 60
    let pending: PendingProgress
    /// Sends one entry; the server's answer, if it gives one.
    var send: (PendingProgress.Entry) async throws -> ListeningProgress? = { _ in throw NoServer() }
    var onAnswer: (PendingProgress.Entry, ListeningProgress?) -> Void = { _, _ in }
    var onSignInRefused: (UUID) -> Void = { _ in }

    /// The last checkpoint: when a position was last due. Kept whether the report reached the
    /// server or not, so a dead server or no network is tried again only at the next one, and
    /// the stores beside the queue are written at the same pace offline as online.
    private(set) var lastCheckpointAt: Date?
    private var flushing = false
    private var flushAgain = false

    init(pending: PendingProgress) {
        self.pending = pending
    }

    /// Whether a position for this reason goes to the server now rather than waiting.
    static func sendsNow(_ reason: SpokenEngine.TickReason, lastCheckpointAt: Date?, now: Date, interval: TimeInterval) -> Bool {
        switch reason {
        case .periodic:
            guard let lastCheckpointAt else { return true }
            return now.timeIntervalSince(lastCheckpointAt) >= interval
        case .pause, .seek, .chapter, .stop, .finished, .teardown:
            return true
        }
    }

    /// Records the position on disk and says whether it is a checkpoint: due to be saved
    /// everywhere and sent now.
    @discardableResult
    func record(_ entry: PendingProgress.Entry, reason: SpokenEngine.TickReason, now: Date = Date()) -> Bool {
        pending.record(entry)
        guard Self.sendsNow(reason, lastCheckpointAt: lastCheckpointAt, now: now, interval: interval) else { return false }
        lastCheckpointAt = now
        return true
    }

    /// Sends what is on disk, oldest first; what the server refuses for good is dropped, what
    /// could not reach it stays for the next try. Offline, nothing is tried.
    func flush(isOffline: Bool) async {
        guard !isOffline else { return }
        // A report due while another is on its way (a pause during a slow request) goes right
        // after it, not at the next tick.
        guard !flushing else { flushAgain = true; return }
        flushing = true
        defer { flushing = false }
        repeat {
            flushAgain = false
            guard await sendQueued() else { return }
        } while flushAgain
    }

    /// One pass over the queue; false when the server could not be reached.
    private func sendQueued() async -> Bool {
        for entry in pending.all().sorted(by: { $0.at < $1.at }) {
            do {
                let answer = try await send(entry)
                pending.markSent(entry)
                onAnswer(entry, answer)
            } catch is NoServer {
                continue
            } catch SourceError.network, SourceError.offline {
                return false
            } catch SourceError.notFound {
                // The session is over or the book is gone: the position goes without a session.
                pending.remove(id: entry.id)
                if entry.sessionId != nil {
                    pending.record(.init(
                        id: UUID().uuidString, serverId: entry.serverId, bookId: entry.bookId, sessionId: nil, positionMs: entry.positionMs,
                        listenedMs: entry.listenedMs, durationMs: entry.durationMs, finished: entry.finished, at: entry.at, closes: false
                    ))
                }
            } catch SourceError.signInRejected {
                onSignInRefused(entry.serverId)
                return false
            } catch {
                pending.remove(id: entry.id)
            }
        }
        return true
    }

    /// Positions queued on disk that are newer than what the other stores saved: the app was
    /// killed between two checkpoints. The newest per book, by composite id.
    static func newerThanSaved(_ entries: [PendingProgress.Entry], saved: (String) -> KnownPositions.Entry?) -> [String: PendingProgress.Entry] {
        var out: [String: PendingProgress.Entry] = [:]
        for entry in entries {
            let composite = BookID.make(serverId: entry.serverId, bookId: entry.bookId)
            if let known = saved(composite), known.at >= entry.at { continue }
            if let seen = out[composite], seen.at >= entry.at { continue }
            out[composite] = entry
        }
        return out
    }
}

/// The engine saves its resume point on every tick. This keeps the newest in memory and writes
/// it through only at a checkpoint (`commit`), so a playing tick costs one file write, not two;
/// a kill between checkpoints is covered by `PendingProgress`, which is replayed at launch.
final class CheckpointedResumeStore: ResumeStore, @unchecked Sendable {
    private let inner: any ResumeStore
    private let lock = NSLock()
    private var unsaved: [String: (trackId: String, positionSecs: Double)] = [:]

    init(_ inner: any ResumeStore) {
        self.inner = inner
    }

    func saveResume(containerId: String, trackId: String, positionSecs: Double) {
        lock.lock()
        defer { lock.unlock() }
        unsaved[containerId] = (trackId, positionSecs)
    }

    func loadResume(containerId: String) -> (trackId: String, positionSecs: Double)? {
        lock.lock()
        defer { lock.unlock() }
        return unsaved[containerId] ?? inner.loadResume(containerId: containerId)
    }

    func clearResume(containerId: String) {
        lock.lock()
        defer { lock.unlock() }
        unsaved[containerId] = nil
        inner.clearResume(containerId: containerId)
    }

    /// Writes what was saved since the last checkpoint.
    func commit() {
        lock.lock()
        defer { lock.unlock() }
        for (id, value) in unsaved { inner.saveResume(containerId: id, trackId: value.trackId, positionSecs: value.positionSecs) }
        unsaved = [:]
    }
}
