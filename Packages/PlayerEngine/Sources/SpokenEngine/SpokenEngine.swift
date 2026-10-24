import AVFoundation
import Foundation
import Observation
import OSLog
import PlayerCore

/// A player for one book at a time: an `AVPlayer` over the book's files as one timeline, loaded
/// one part at a time, with speed, chapters, skips, smart rewind and the sleep timer. Books
/// need none of the music engine's gapless scheduling; they need pitch-corrected speed, byte
/// ranges and HLS, which `AVPlayer` has.
///
/// The engine speaks **book time** (milliseconds from the start of the book) everywhere; the
/// part and the offset in it are an implementation detail. It knows nothing about servers: the
/// app resolves links, and `partRefresher` is how the engine asks for a new one when a link
/// has failed or is about to run out.
@Observable
@MainActor
public final class SpokenEngine {
    /// Why a position was reported.
    public enum TickReason: Sendable {
        case periodic, pause, seek, chapter, stop, finished, teardown
    }

    /// Where the listener is, for the app to save locally first and then send.
    public struct Position: Sendable, Equatable {
        public let bookId: String
        public let positionMs: Int64
        public let partId: String
        public let partOffsetMs: Int64
        /// Wall-clock milliseconds listened since the last report.
        public let listenedMs: Int64
        public let finished: Bool
        public let at: Date
        public let reason: TickReason
    }

    public private(set) var book: SpokenBook?
    public private(set) var isPlaying = false
    public private(set) var isLoading = false
    /// Playing, but the player is waiting for the network to catch up: shown as loading.
    public private(set) var isBuffering = false
    public private(set) var positionMs: Int64 = 0
    public private(set) var errorMessage: String?
    /// 0.5 to 3.0, pitch-corrected.
    public private(set) var rate: Float = 1.0
    public var skipForwardSecs: Double = 30
    public var skipBackwardSecs: Double = 15
    public var smartRewind = SmartRewind()
    /// Pause when the current chapter ends (the sleep timer's third mode).
    public private(set) var stopsAtEndOfChapter = false
    public let sleepTimer: SleepTimer

    public var durationMs: Int64 { book?.timeline.durationMs ?? 0 }
    public var currentChapter: SpokenChapter? { book?.timeline.chapter(at: positionMs) }
    public var hasChapters: Bool { !(book?.timeline.chapters.isEmpty ?? true) }

    /// Every position worth saving: every `tickIntervalSecs` of listening, and on pause, seek,
    /// chapter change, stop and the end of the book.
    public var onPosition: ((Position) -> Void)?
    public var onFinished: ((String) -> Void)?
    /// A new link for a part whose one failed or is about to run out.
    public var partRefresher: (@Sendable (_ bookId: String, _ partId: String) async throws -> URL)?
    /// A copy of a part already on the phone (the app's listening cache), asked for before each
    /// part is loaded; nil means stream it.
    public var partLocator: (@Sendable (_ bookId: String, _ partId: String) async -> URL?)?
    /// How much of a streamed file the player keeps fetched ahead. Three minutes: a stall on a
    /// slow server passes unheard, and the memory is a few megabytes of compressed speech.
    public var forwardBufferSecs: Double = 180
    public var artworkProvider: (@Sendable (_ bookId: String) async -> NowPlayingImage?)?
    public var tickIntervalSecs: TimeInterval = 10

    private let player = AVPlayer()
    private let nowPlaying: NowPlayingController
    private let resumeStore: ResumeStore?
    private var currentIndex: Int?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var pausedAt: Date?
    private var playingSince: Date?
    private var listenedSinceTickMs: Int64 = 0
    private var lastTickAt = Date()
    private var refreshing = false
    /// The link or file the current item was made from. When the timeline names another one
    /// (a download finished meanwhile), the item is made again at the next pause or seek.
    private(set) var loadedURL: URL?
    /// Moving to another part waits for the app's locator; meanwhile the old item's time and
    /// end mean nothing, and only the last of several quick moves is loaded.
    private var switchingPart = false
    private var loadGeneration = 0
    private var artwork: NowPlayingImage?
    private let log = Logger(subsystem: "audio.own.player", category: "spoken")

    public init(nowPlaying: NowPlayingController, resumeStore: ResumeStore? = nil) {
        self.nowPlaying = nowPlaying
        self.resumeStore = resumeStore
        sleepTimer = SleepTimer()
        player.automaticallyWaitsToMinimizeStalling = true
        sleepTimer.onExpire = { [weak self] in self?.pause() }
        nowPlaying.onPlay = { [weak self] in self?.play() }
        nowPlaying.onPause = { [weak self] in self?.pause() }
        nowPlaying.onSeek = { [weak self] seconds in self?.seek(to: Int64(seconds * 1000)) }
        nowPlaying.onSkipForward = { [weak self] seconds in self?.skip(bySeconds: seconds) }
        nowPlaying.onSkipBackward = { [weak self] seconds in self?.skip(bySeconds: -seconds) }
        nowPlaying.onNextTrack = { [weak self] in self?.nextChapter() }
        nowPlaying.onPreviousTrack = { [weak self] in self?.previousChapter() }
        observeTime()
        observeAudioSession()
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate && player.reasonForWaitingToPlay == .toMinimizeStalls
            Task { @MainActor [weak self] in
                guard let self, self.isBuffering != waiting else { return }
                self.isBuffering = waiting
                if waiting { self.log.info("buffering at \(self.positionMs, privacy: .public) ms") }
            }
        }
    }

    // MARK: - Loading and playing

    /// Loads `book` at `positionMs` (the last position the app knows), and plays if asked.
    public func load(_ book: SpokenBook, at positionMs: Int64, autoplay: Bool) {
        if self.book != nil { flushListening(reason: .stop) }
        self.book = book
        errorMessage = nil
        pausedAt = nil
        stopsAtEndOfChapter = false
        self.positionMs = book.timeline.clamp(positionMs)
        loadGeneration += 1
        switchingPart = false
        artwork = nil
        if let provider = artworkProvider {
            let id = book.id
            Task { [weak self] in
                let image = await provider(id)
                guard let self, self.book?.id == id else { return }
                self.artwork = image
                self.updateNowPlaying()
            }
        }
        loadPart(at: self.positionMs, thenPlay: autoplay)
    }

    public func play() {
        guard book != nil else { return }
        if let pausedAt {
            let rewind = smartRewind.rewindMs(pausedFor: Date().timeIntervalSince(pausedAt))
            if rewind > 0 { seek(to: positionMs - rewind, report: false) }
            self.pausedAt = nil
        }
        nowPlaying.useSpokenAudioSession()
        nowPlaying.activateSession()
        player.playImmediately(atRate: rate)
        isPlaying = true
        playingSince = Date()
        lastTickAt = Date()
        updateNowPlaying()
    }

    public func pause() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        pausedAt = Date()
        flushListening(reason: .pause)
        // A copy that arrived while this part played is used from here on, while it is quiet.
        if let book, let index = currentIndex, !switchingPart, loadedURL != book.timeline.parts[index].url {
            loadPart(at: positionMs, thenPlay: false)
        }
        updateNowPlaying()
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Ends playback of the book: the position is reported once more (unless the caller is
    /// about to forget it) and the lock screen cleared.
    public func stop(reporting: Bool = true) {
        guard book != nil else { return }
        if isPlaying { player.pause(); isPlaying = false }
        if reporting { flushListening(reason: .stop) }
        player.replaceCurrentItem(with: nil)
        book = nil
        isBuffering = false
        currentIndex = nil
        loadedURL = nil
        switchingPart = false
        loadGeneration += 1
        pausedAt = nil
        sleepTimer.cancel()
        stopsAtEndOfChapter = false
        nowPlaying.clear()
    }

    /// Going to the background or being killed: the position is saved; audio keeps playing.
    public func saveForTeardown() {
        guard book != nil else { return }
        flushListening(reason: .teardown)
    }

    // MARK: - Moving

    public func seek(to target: Int64) {
        seek(to: target, report: true)
    }

    private func seek(to target: Int64, report: Bool) {
        guard let book, let (index, offset) = book.timeline.locate(target) else { return }
        let clamped = book.timeline.clamp(target)
        let chapterBefore = book.timeline.chapterIndex(at: positionMs)
        positionMs = clamped
        if index == currentIndex, !switchingPart, player.currentItem != nil, loadedURL == book.timeline.parts[index].url {
            player.seek(to: CMTime(value: offset, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            switchPart(to: index)
        }
        if report { flushListening(reason: book.timeline.chapterIndex(at: clamped) != chapterBefore ? .chapter : .seek) }
        updateNowPlaying()
    }

    public func skipForward() { skip(bySeconds: skipForwardSecs) }
    public func skipBackward() { skip(bySeconds: -skipBackwardSecs) }

    public func skip(bySeconds seconds: Double) {
        guard let book else { return }
        seek(to: book.timeline.skipped(from: positionMs, bySeconds: seconds))
    }

    public func nextChapter() {
        guard let book else { return }
        seek(to: book.timeline.nextChapterStart(from: positionMs) ?? book.timeline.durationMs)
    }

    public func previousChapter() {
        guard let book else { return }
        seek(to: book.timeline.previousChapterStart(from: positionMs))
    }

    public func setRate(_ newRate: Float) {
        rate = min(3.0, max(0.5, (newRate * 20).rounded() / 20))
        if isPlaying { player.rate = rate }
        updateNowPlaying()
    }

    /// The sleep timer's chapter mode; the other two modes are the timer's own.
    public func stopAtEndOfChapter(_ on: Bool) {
        stopsAtEndOfChapter = on
        if on { sleepTimer.cancel() }
    }

    // MARK: - Parts

    /// A local copy of a part arrived (a download finished): the timeline names it from now on.
    /// A part still to come plays from it; the part playing now switches at the next pause or
    /// seek, never mid-sentence.
    public func useLocalCopy(partId: String, at url: URL) {
        guard let book, let index = book.timeline.index(ofPart: partId), book.timeline.parts[index].url != url else { return }
        self.book = book.replacing(partId: partId, with: url)
        if index == currentIndex, !isPlaying, !switchingPart, !refreshing {
            loadPart(at: positionMs, thenPlay: false)
        }
    }

    /// Another part (a seek, or the one before ended): the app's locator is asked for a copy on
    /// the phone first. `currentIndex` moves at once, so a report made meanwhile names the
    /// right part.
    private func switchPart(to index: Int) {
        loadGeneration += 1
        let generation = loadGeneration
        currentIndex = index
        switchingPart = true
        player.pause()
        prepare(partIndex: index) { [weak self] in
            guard let self, self.loadGeneration == generation, self.book != nil else { return }
            self.switchingPart = false
            self.loadPart(at: self.positionMs, thenPlay: self.isPlaying)
        }
    }

    private func loadPart(at bookPositionMs: Int64, thenPlay: Bool) {
        guard let book, let (index, offset) = book.timeline.locate(bookPositionMs) else { return }
        let part = book.timeline.parts[index]
        currentIndex = index
        isLoading = true
        errorMessage = nil
        loadedURL = part.url
        if part.isUnresolved {
            // Nothing to play from yet: straight to the app for a link.
            player.replaceCurrentItem(with: nil)
            Task { await recover(from: "This part is not on this device.", thenPlay: thenPlay) }
            return
        }
        let asset = AVURLAsset(url: part.url)
        let item = AVPlayerItem(asset: asset)
        // Speech keeps its pitch at any speed; the other algorithms are for music.
        item.audioTimePitchAlgorithm = .timeDomain
        // A file streams well ahead of the listener; an HLS transcode is made as it goes and
        // asking for much more only makes the server work for nothing.
        item.preferredForwardBufferDuration = part.url.isFileURL ? 0 : (part.isHLS ? 60 : forwardBufferSecs)
        observe(item)
        player.replaceCurrentItem(with: item)
        if offset > 0 {
            player.seek(to: CMTime(value: offset, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if thenPlay {
            player.playImmediately(atRate: rate)
            if !isPlaying {
                isPlaying = true
                playingSince = Date()
                lastTickAt = Date()
            }
        }
        updateNowPlaying()
    }

    private func observe(_ item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.partEnded() }
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item, !self.switchingPart else { return }
                switch status {
                case .readyToPlay: self.isLoading = false
                case .failed: await self.recover(from: message ?? "The file could not be played.")
                default: break
                }
            }
        }
    }

    /// The part played to its end: the next one, or the book is finished.
    private func partEnded() {
        guard let book, let index = currentIndex, !switchingPart else { return }
        if index + 1 < book.timeline.parts.count {
            positionMs = book.timeline.starts[index + 1]
            if sleepTimer.consumeEndOfItem() {
                // "End of item" for a book is the book, not the file; the timer stays armed.
                sleepTimer.startUntilEndOfItem()
            }
            switchPart(to: index + 1)
        } else {
            positionMs = book.timeline.durationMs
            isPlaying = false
            player.pause()
            flushListening(reason: .finished, finished: true)
            _ = sleepTimer.consumeEndOfItem()
            resumeStore?.clearResume(containerId: book.id)
            updateNowPlaying()
            onFinished?(book.id)
        }
    }

    /// A link that failed: one fresh link from the app, the same position again; otherwise the
    /// error is shown — the app's own words when it gave a reason (no network, say).
    private func recover(from message: String, thenPlay: Bool? = nil) async {
        guard let book, let index = currentIndex, let partRefresher, !refreshing else {
            isLoading = false
            isPlaying = false
            errorMessage = message
            log.error("part failed: \(message, privacy: .public)")
            updateNowPlaying()
            return
        }
        refreshing = true
        defer { refreshing = false }
        let part = book.timeline.parts[index]
        do {
            let url = try await partRefresher(book.id, part.id)
            guard self.book?.id == book.id else { return }
            self.book = self.book?.replacing(partId: part.id, with: url)
            loadPart(at: positionMs, thenPlay: thenPlay ?? isPlaying)
        } catch {
            isLoading = false
            isPlaying = false
            errorMessage = (error as? LocalizedError)?.errorDescription ?? message
            log.error("part failed and no fresh link came: \(message, privacy: .public)")
            updateNowPlaying()
        }
    }

    /// Before a part is loaded: a copy on the phone if the app has one, else a fresh link when
    /// the one it has is about to run out; `then` runs either way.
    private func prepare(partIndex: Int, then: @escaping @MainActor () -> Void) {
        guard let book, partIndex < book.timeline.parts.count else { then(); return }
        let part = book.timeline.parts[partIndex]
        guard !part.url.isFileURL, partLocator != nil || (book.linksExpireAt.map { $0.timeIntervalSinceNow < 120 } ?? false) else {
            then()
            return
        }
        let locator = partLocator
        let refresher = partRefresher
        let expiring = book.linksExpireAt.map { $0.timeIntervalSinceNow < 120 } ?? false
        Task { [weak self] in
            var replacement: URL?
            if let locator { replacement = await locator(book.id, part.id) }
            if replacement == nil, expiring, let refresher { replacement = try? await refresher(book.id, part.id) }
            if let replacement, let self, self.book?.id == book.id {
                self.book = self.book?.replacing(partId: part.id, with: replacement)
            }
            then()
        }
    }

    // MARK: - Time

    private func observeTime() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.timeAdvanced(to: time) }
        }
    }

    private func timeAdvanced(to time: CMTime) {
        guard let book, let index = currentIndex, time.isNumeric, isPlaying, !switchingPart else { return }
        let offset = Int64((time.seconds * 1000).rounded())
        let before = positionMs
        positionMs = book.timeline.position(partIndex: index, offsetMs: offset)
        if stopsAtEndOfChapter {
            let end = book.timeline.endOfChapter(at: before)
            if positionMs >= end - 250 {
                stopsAtEndOfChapter = false
                pause()
                return
            }
        }
        if book.timeline.chapterIndex(at: before) != book.timeline.chapterIndex(at: positionMs) {
            flushListening(reason: .chapter)
            updateNowPlaying()
        } else if Date().timeIntervalSince(lastTickAt) >= tickIntervalSecs {
            flushListening(reason: .periodic)
        }
    }

    /// Reports the position with the listening since the last report, and remembers it locally.
    private func flushListening(reason: TickReason, finished: Bool = false) {
        guard let book, let index = currentIndex else { return }
        if let since = playingSince {
            listenedSinceTickMs += Int64(Date().timeIntervalSince(since) * 1000)
            playingSince = isPlaying ? Date() : nil
        }
        let part = book.timeline.parts[index]
        let position = Position(
            bookId: book.id, positionMs: positionMs, partId: part.id, partOffsetMs: positionMs - book.timeline.starts[index],
            listenedMs: listenedSinceTickMs, finished: finished, at: Date(), reason: reason
        )
        listenedSinceTickMs = 0
        lastTickAt = Date()
        resumeStore?.saveResume(containerId: book.id, trackId: part.id, positionSecs: Double(positionMs) / 1000)
        onPosition?(position)
    }

    // MARK: - Lock screen

    private func updateNowPlaying() {
        guard let book else { return }
        nowPlaying.configureSkips(forwardSecs: skipForwardSecs, backwardSecs: skipBackwardSecs)
        nowPlaying.update(
            title: book.title, artist: book.author, album: currentChapter?.title,
            duration: Double(book.timeline.durationMs) / 1000, elapsedTime: Double(positionMs) / 1000,
            rate: isPlaying ? rate : 0, artwork: artwork,
            hasNextTrack: hasChapters && book.timeline.nextChapterStart(from: positionMs) != nil,
            hasPreviousTrack: hasChapters
        )
    }

    // MARK: - Interruptions

    private func observeAudioSession() {
        #if os(iOS)
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let resumes = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .began: self.pause()
                case .ended: if resumes { self.play() }
                @unknown default: break
                }
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            // Headphones unplugged: nobody wants the book out loud.
            MainActor.assumeIsolated { self?.pause() }
        }
        #endif
    }
}
