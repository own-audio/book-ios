import Foundation
import Observation

/// A client-side sleep timer: a countdown, or "stop at the end of this track".
///
/// Countdown driving is split from real-time waiting: `tick(bySecs:)` is called directly by
/// tests, and the `Task.sleep` loop below calls it once a second in production.
@Observable
@MainActor
public final class SleepTimer {
    public enum Preset: CaseIterable, Sendable, Identifiable {
        case fiveMinutes, fifteenMinutes, thirtyMinutes, fortyFiveMinutes, sixtyMinutes

        public var id: Self { self }

        public var label: String {
            switch self {
            case .fiveMinutes: loc("5 minutes")
            case .fifteenMinutes: loc("15 minutes")
            case .thirtyMinutes: loc("30 minutes")
            case .fortyFiveMinutes: loc("45 minutes")
            case .sixtyMinutes: loc("60 minutes")
            }
        }

        public var secs: Double {
            switch self {
            case .fiveMinutes: 5 * 60
            case .fifteenMinutes: 15 * 60
            case .thirtyMinutes: 30 * 60
            case .fortyFiveMinutes: 45 * 60
            case .sixtyMinutes: 60 * 60
            }
        }
    }

    public private(set) var remainingSecs: Double?

    /// Armed to stop when whatever is playing reaches its own end, rather than after a
    /// duration. Deliberately *not* implemented as "duration minus position" seconds: that
    /// number is wrong the moment the listener scrubs, pauses, or changes speed — at 1.5×, half
    /// an hour of episode left is twenty minutes of wall clock — and it would race the queue's
    /// auto-advance at exactly the moment it matters. So there is no countdown here at all; the
    /// engine tells this type when the item actually ended.
    public private(set) var stopsAtEndOfItem = false

    public var isActive: Bool { remainingSecs != nil || stopsAtEndOfItem }

    /// Fired once when the countdown reaches zero — the caller (`PlaybackEngine`) pauses
    /// playback from here rather than this type reaching into playback state itself.
    public var onExpire: (() -> Void)?

    private var tickTask: Task<Void, Never>?

    public init() {}

    public func start(preset: Preset) {
        start(secs: preset.secs)
    }

    public func start(secs: Double) {
        stopsAtEndOfItem = false
        remainingSecs = max(secs, 0)
        startTicking()
    }

    /// The two modes are exclusive: picking one replaces the other.
    public func startUntilEndOfItem() {
        tickTask?.cancel()
        tickTask = nil
        remainingSecs = nil
        stopsAtEndOfItem = true
    }

    /// Whether this finish is the one the timer was waiting for, disarming it if so. Called by
    /// `PlaybackEngine` when everything loaded has played out; a `true` answer is the engine's
    /// signal to stop there rather than start whatever is queued next.
    func consumeEndOfItem() -> Bool {
        guard stopsAtEndOfItem else { return false }
        stopsAtEndOfItem = false
        return true
    }

    /// "+10 min" style extension while already counting down; a no-op once it's expired.
    public func extend(bySecs: Double) {
        guard let remaining = remainingSecs else { return }
        remainingSecs = remaining + bySecs
    }

    public func cancel() {
        tickTask?.cancel()
        tickTask = nil
        remainingSecs = nil
        stopsAtEndOfItem = false
    }

    func tick(bySecs: Double = 1) {
        guard let remaining = remainingSecs else { return }
        let next = remaining - bySecs
        if next <= 0 {
            tickTask?.cancel()
            tickTask = nil
            remainingSecs = nil
            onExpire?()
        } else {
            remainingSecs = next
        }
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.tick()
            }
        }
    }
}
