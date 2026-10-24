import BookLibrary
import Foundation
import Observation

/// Narrations started from this phone: each job's id is kept on disk the moment the server
/// answers, so a kill or a relaunch finds it again; while the app is in front, every running
/// job is asked about, every few seconds at first and less often while nothing moves. A finished job's book arrives through the normal
/// catalogue sync; the row says so and can be dropped.
@Observable
@MainActor
final class NarrationManager {
    struct Entry: Codable, Equatable, Identifiable {
        let id: String
        let serverId: UUID
        var title: String
        let startedAt: Date
        var stage: String
        var stages: [String]
        var error: String?
        var bookId: String?
        var chaptersDone: Int
        var chaptersTotal: Int
        var quotedPriceCents: Int
        var currency: String

        var isTerminal: Bool { stage == "complete" || stage == "failed" }
    }

    private(set) var entries: [String: Entry] = [:]
    var narratorProvider: ((UUID) -> (any BookNarrator)?)?
    /// Called once a job completes, so the library can pick the book up.
    var onCompleted: ((Entry) -> Void)?

    private let fileURL: URL
    private var polling: Task<Void, Never>?

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = base.appendingPathComponent("narrations.json")
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) { entries = saved }
    }

    var active: [Entry] { entries.values.sorted { $0.startedAt > $1.startedAt } }
    var hasRunning: Bool { entries.values.contains { !$0.isTerminal } }
    var isPolling: Bool { polling != nil }

    func add(_ job: NarrationJob, serverId: UUID) {
        entries[job.id] = Entry(
            id: job.id, serverId: serverId, title: job.title, startedAt: Date(), stage: job.stage, stages: job.stages, error: job.error,
            bookId: job.bookId, chaptersDone: job.chapters.filter { $0.status == "complete" }.count, chaptersTotal: job.chapters.count,
            quotedPriceCents: job.quotedPriceCents, currency: job.currency
        )
        save()
        startPolling()
    }

    func forget(_ id: String) {
        entries[id] = nil
        save()
    }

    static let firstDelay: Duration = .seconds(4)
    static let longestDelay: Duration = .seconds(60)

    /// Four seconds after a change, half as often again after each answer that brought none,
    /// up to a minute: a job takes minutes to hours, and a phone pays for a tight loop in
    /// battery and data.
    static func nextDelay(after delay: Duration, changed: Bool) -> Duration {
        changed ? firstDelay : min(delay * 2, longestDelay)
    }

    /// Polls while something runs on a server that is still set up; stops when none is.
    func startPolling() {
        guard polling == nil, hasRunning else { return }
        polling = Task { [weak self] in
            var delay = Self.firstDelay
            while let self, !Task.isCancelled, self.hasRunning {
                guard let changed = await self.pollOnce() else { break }
                delay = Self.nextDelay(after: delay, changed: changed)
                try? await Task.sleep(for: delay)
            }
            self?.polling = nil
        }
    }

    func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    /// Asks about every running job once. Whether anything changed; nil when no running job's
    /// server is set up any more, so there is nobody to ask.
    private func pollOnce() async -> Bool? {
        var changed = false
        var asked = false
        for entry in entries.values where !entry.isTerminal {
            guard let narrator = narratorProvider?(entry.serverId) else { continue }
            asked = true
            guard let job = try? await narrator.narration(id: entry.id) else { continue }
            var updated = entry
            updated.title = job.title
            updated.stage = job.stage
            updated.stages = job.stages
            updated.error = job.error
            updated.bookId = job.bookId
            updated.chaptersDone = job.chapters.filter { $0.status == "complete" }.count
            updated.chaptersTotal = job.chapters.count
            guard updated != entry else { continue }
            changed = true
            let completed = updated.stage == "complete" && entry.stage != "complete"
            entries[entry.id] = updated
            if completed { onCompleted?(updated) }
        }
        if changed { save() }
        return asked ? changed : nil
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
