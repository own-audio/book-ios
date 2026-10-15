import Foundation

/// Every position the engine reports is written here before anything is sent, and removed
/// once the server has it. A dead server, a lost network or a killed app leaves the position
/// on disk, to be sent at the next start. One file, a few entries at most.
final class PendingProgress: @unchecked Sendable {
    struct Entry: Codable, Sendable, Equatable, Identifiable {
        let id: String
        let serverId: UUID
        let bookId: String
        let sessionId: String?
        var positionMs: Int64
        var listenedMs: Int64
        let durationMs: Int64
        var finished: Bool
        var at: Date
        var closes: Bool
    }

    private let file: URL
    private let lock = NSLock()

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        file = base.appendingPathComponent("pending-progress.json")
    }

    func all() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return read()
    }

    /// One entry per book and session: a newer position replaces the older one, and the
    /// listened time adds up, so a server that was down for an hour gets one report, not 360.
    func record(_ entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        var entries = read()
        if let index = entries.firstIndex(where: { $0.serverId == entry.serverId && $0.bookId == entry.bookId && $0.sessionId == entry.sessionId }) {
            var merged = entries[index]
            merged.positionMs = entry.positionMs
            merged.listenedMs += entry.listenedMs
            merged.finished = entry.finished
            merged.at = entry.at
            merged.closes = merged.closes || entry.closes
            entries[index] = merged
        } else {
            entries.append(entry)
        }
        write(entries)
    }

    func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        write(read().filter { $0.id != id })
    }

    /// Everything queued for one book, when its position is being forgotten.
    func remove(serverId: UUID, bookId: String) {
        lock.lock()
        defer { lock.unlock() }
        write(read().filter { !($0.serverId == serverId && $0.bookId == bookId) })
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: file)
    }

    private func read() -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func write(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
