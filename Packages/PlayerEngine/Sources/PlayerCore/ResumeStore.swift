import Foundation

/// Remembers where listening stopped inside an album, playlist, artist or genre, so pressing
/// Play on it again picks up there rather than at track 1.
///
/// Stores *which* track of a container was current, and the position in it. Subsonic servers
/// don't record that, and it works offline.
///
/// Keyed by a container id the app chooses ("album:…", "playlist:…").
public protocol ResumeStore: Sendable {
    func saveResume(containerId: String, trackId: String, positionSecs: Double)
    /// `nil` when this container has never been played, which callers treat as "start at the
    /// first track, position 0".
    func loadResume(containerId: String) -> (trackId: String, positionSecs: Double)?
    /// Called when a container plays to its end — the next Play should start over rather than
    /// resume onto the last second of the final track.
    func clearResume(containerId: String)
}

/// An in-memory implementation, for tests and previews. The real one is the app target's
/// `UserDefaultsResumeStore`, next to `UserDefaultsLocalPlaybackProgressStore` for the same
/// reason: `UserDefaults` isn't `Sendable`, so the concrete store needs its own lock to honestly
/// make the promise this protocol requires.
public final class InMemoryResumeStore: ResumeStore, @unchecked Sendable {
    private var entries: [String: (trackId: String, positionSecs: Double)] = [:]
    private let lock = NSLock()

    public init() {}

    public func saveResume(containerId: String, trackId: String, positionSecs: Double) {
        lock.lock()
        defer { lock.unlock() }
        entries[containerId] = (trackId, positionSecs)
    }

    public func loadResume(containerId: String) -> (trackId: String, positionSecs: Double)? {
        lock.lock()
        defer { lock.unlock() }
        return entries[containerId]
    }

    public func clearResume(containerId: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[containerId] = nil
    }
}
