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
    /// The cover written for the current book, once there is one; asked for again on every
    /// sync until then, since the loader may not have it when the activity starts.
    private var coverFile: String?
    private var fetchingCover = false

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
            isPlaying: model.engine.isPlaying, rate: model.engine.rate, at: Date(), coverFile: activityBookId == spoken.id ? coverFile : nil
        )
        if activityBookId != spoken.id {
            Task { await start(book: book, serverId: serverId, composite: spoken.id, state: state) }
            return
        }
        if coverFile == nil { fetchCover(book: book, serverId: serverId, composite: spoken.id) }
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
        coverFile = nil
        let attributes = BookActivityAttributes(bookId: composite, title: book.title, author: book.authorLine)
        do {
            activity = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil))
            lastSentAt = Date()
            lastState = state
            log.info("started for \(book.title, privacy: .public)")
        } catch {
            log.error("could not start: \(String(describing: error), privacy: .public)")
            activityBookId = nil
            return
        }
        fetchCover(book: book, serverId: serverId, composite: composite)
    }

    /// The cover as a small JPEG in the App Group, readable before the phone's first unlock
    /// wears off; the next sync carries its name.
    private func fetchCover(book: Book, serverId: UUID, composite: String) {
        guard !fetchingCover, coverFile == nil else { return }
        fetchingCover = true
        Task { [weak self] in
            defer { self?.fetchingCover = false }
            guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BookActivityAttributes.appGroup),
                  let image = await self?.model?.coverImage(book, serverId: serverId, size: 160), let data = image.jpegData(compressionQuality: 0.75)
            else {
                log.info("no cover for the activity yet")
                return
            }
            let name = "cover-" + composite.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }.map(String.init).joined() + ".jpg"
            do {
                try data.write(to: group.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                log.error("could not write the cover: \(String(describing: error), privacy: .public)")
                return
            }
            guard let self, self.activityBookId == composite else { return }
            self.coverFile = name
            self.sync(force: true)
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
