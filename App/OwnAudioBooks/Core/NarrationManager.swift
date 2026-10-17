import BookLibrary
import Foundation
import Observation

/// Narrations started from this phone: each job's id is kept on disk the moment the server
/// answers, so a kill or a relaunch finds it again; while the app is in front, every running
/// job is asked about every few seconds. A finished job's book arrives through the normal
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

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = base.appendingPathComponent("narrations.json")
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) { entries = saved }
    }

    var active: [Entry] { entries.values.sorted { $0.startedAt > $1.startedAt } }
    var hasRunning: Bool { entries.values.contains { !$0.isTerminal } }

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

    /// Polls every four seconds while something runs: a job takes minutes to hours, and a
    /// phone pays for a tighter loop in battery and data.
    func startPolling() {
        guard polling == nil, hasRunning else { return }
        polling = Task { [weak self] in
            while let self, !Task.isCancelled, self.hasRunning {
                await self.pollOnce()
                try? await Task.sleep(for: .seconds(4))
            }
            self?.polling = nil
        }
    }

    func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    private func pollOnce() async {
        for entry in entries.values where !entry.isTerminal {
            guard let narrator = narratorProvider?(entry.serverId), let job = try? await narrator.narration(id: entry.id) else { continue }
            var updated = entry
            updated.title = job.title
            updated.stage = job.stage
            updated.stages = job.stages
            updated.error = job.error
            updated.bookId = job.bookId
            updated.chaptersDone = job.chapters.filter { $0.status == "complete" }.count
            updated.chaptersTotal = job.chapters.count
            let completed = updated.stage == "complete" && entry.stage != "complete"
            entries[entry.id] = updated
            if completed { onCompleted?(updated) }
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
