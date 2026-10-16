import ActivityKit
import BookLibrary
import Foundation
import Observation
import OSLog
import SpokenEngine
import UIKit

private let log = Logger(subsystem: "audio.own.bookplayer", category: "liveActivity")

/// Keeps one Live Activity in step with the player: started when a book loads, moved with the
/// position (at most every 15 s while playing, at once on play, pause, chapter or speed), ended
/// when the player lets the book go. The cover goes into the App Group as a small JPEG, since
/// the activity's own state may only carry a few kilobytes.
@MainActor
final class LiveActivityController {
    private weak var model: AppModel?
    private var activity: Activity<BookActivityAttributes>?
    private var activityBookId: String?
    private var lastSentAt = Date.distantPast
    private var lastState: BookActivityAttributes.ContentState?

    init(model: AppModel) {
        self.model = model
        PlaybackControlIntent.handler = { [weak model] action in
            guard let model else { return }
            switch action {
            case .toggle: model.engine.togglePlayPause()
            case .back: model.engine.skipBackward()
            case .forward: model.engine.skipForward()
            }
        }
        observe()
    }

    /// Re-registers for the next change of what the activity shows, as `@Observable` wants.
    private func observe() {
        guard let model else { return }
        withObservationTracking {
            _ = model.engine.book?.id
            _ = model.engine.isPlaying
            _ = model.engine.rate
            _ = model.engine.currentChapter?.startMs
        } onChange: {
            Task { @MainActor [weak self] in
                self?.sync(force: true)
                self?.observe()
            }
        }
    }

    /// Called on the player's position ticks; the throttle keeps the system's budget.
    func tick() {
        sync(force: false)
    }

    private func sync(force: Bool) {
        guard let model else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { log.debug("live activities are off"); return }
        guard let spoken = model.engine.book, let book = model.nowPlayingBook, let serverId = model.nowPlayingServerId else {
            end()
            return
        }
        let state = BookActivityAttributes.ContentState(
            chapter: model.engine.currentChapter?.title, positionMs: model.engine.positionMs, durationMs: model.engine.durationMs,
            isPlaying: model.engine.isPlaying, rate: model.engine.rate, at: Date()
        )
        if activityBookId != spoken.id {
            Task { await start(book: book, serverId: serverId, composite: spoken.id, state: state) }
            return
        }
        guard let activity else { return }
        if !force, state.isPlaying == lastState?.isPlaying, Date().timeIntervalSince(lastSentAt) < 15 { return }
        lastSentAt = Date()
        lastState = state
        // ActivityKit's handle isn't Sendable; its calls are safe from any task.
        nonisolated(unsafe) let handle = activity
        Task { await handle.update(ActivityContent(state: state, staleDate: nil)) }
    }

    private func start(book: Book, serverId: UUID, composite: String, state: BookActivityAttributes.ContentState) async {
        await endCurrent()
        activityBookId = composite
        var coverFile: String?
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BookActivityAttributes.appGroup),
           let image = await model?.coverImage(book, serverId: serverId, size: 160), let data = image.jpegData(compressionQuality: 0.75) {
            let name = "cover-" + composite.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }.map(String.init).joined() + ".jpg"
            try? data.write(to: group.appendingPathComponent(name), options: .atomic)
            coverFile = name
        }
        // The book may have changed while the cover was being made.
        guard activityBookId == composite else { return }
        let attributes = BookActivityAttributes(bookId: composite, title: book.title, author: book.authorLine, coverFile: coverFile)
        do {
            activity = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil))
            lastSentAt = Date()
            lastState = state
            log.info("started for \(book.title, privacy: .public)")
        } catch {
            log.error("could not start: \(String(describing: error), privacy: .public)")
            activityBookId = nil
        }
    }

    private func end() {
        guard activity != nil else { return }
        Task { await endCurrent() }
    }

    private func endCurrent() async {
        if let activity {
            nonisolated(unsafe) let handle = activity
            await handle.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        activityBookId = nil
        lastState = nil
    }
}
