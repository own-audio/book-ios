import Foundation

/// The `ResumeStore` for real use: one small JSON blob in `UserDefaults`, one entry per
/// container ever played, so a database would buy nothing.
public final class UserDefaultsResumeStore: ResumeStore, @unchecked Sendable {
    private struct Entry: Codable {
        let trackId: String
        let positionSecs: Double
    }

    private let key: String
    private let defaults: UserDefaults
    /// Guards the read-modify-write, exactly as `UserDefaultsLocalPlaybackProgressStore` does:
    /// this is written from the engine's playing tick, and the protocol's `Sendable` requirement
    /// has to be true rather than merely assumed.
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "player.resume") {
        self.defaults = defaults
        self.key = key
    }

    public func saveResume(containerId: String, trackId: String, positionSecs: Double) {
        lock.lock()
        defer { lock.unlock() }
        var all = allEntries()
        all[containerId] = Entry(trackId: trackId, positionSecs: positionSecs)
        persist(all)
    }

    public func loadResume(containerId: String) -> (trackId: String, positionSecs: Double)? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = allEntries()[containerId] else { return nil }
        return (entry.trackId, entry.positionSecs)
    }

    public func clearResume(containerId: String) {
        lock.lock()
        defer { lock.unlock() }
        var all = allEntries()
        all[containerId] = nil
        persist(all)
    }

    private func allEntries() -> [String: Entry] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private func persist(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}
