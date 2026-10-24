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
    public var forwardBufferSecs: Double = 180 { didSet { window?.playerAheadSecs = forwardBufferSecs } }
    /// Keeps the next minutes of a streamed file on disk, so a gap in the signal goes unheard;
    /// nil streams as `AVPlayer` does on its own.
    public var window: StreamWindow? { didSet { connectWindow() } }
    /// While a part streams through the window: how much of what follows the playhead is on
    /// disk, in book time. Nil otherwise.
    public private(set) var savedAheadMs: Int64?
    /// Paused because the network ran out, not by the listener: "No signal — waiting". It
    /// plays on by itself when the signal returns, unless the listener paused meanwhile.
    public private(set) var isWaitingForSignal = false
    public var artworkProvider: (@Sendable (_ bookId: String) async -> NowPlayingImage?)?
    public var tickIntervalSecs: TimeInterval = 10

    private let player = AVPlayer()
    private let nowPlaying: NowPlayingController
    private let resumeStore: ResumeStore?
    private var currentIndex: Int?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var bufferObservation: NSKeyValueObservation?
    /// The item has played everything it had: known at once, while the player's own stall
    /// state can take seconds to follow.
    private var bufferEmpty = false
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
    /// Parts the window could not play (Range ignored, an unknown type): streamed directly.
    private(set) var directOnly: Set<String> = []
    private var signal = SignalWait() {
        didSet { if isWaitingForSignal != signal.isWaiting { isWaitingForSignal = signal.isWaiting } }
    }
    /// The window could not fetch what the player asked for.
    private var windowStarvedNow = false
    /// The player wants to play and has nothing to play (any reason).
    private var isStalled = false
    private var playerWaiting = false
    private var networkUp = true
    private var reloadRetry: Task<Void, Never>?
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
            let stalled = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            let waiting = stalled && player.reasonForWaitingToPlay == .toMinimizeStalls
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.playerWaiting = stalled
                self.updateStalled()
                guard self.isBuffering != waiting else { return }
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
        resetSignal()
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
        if signal.isWaiting {
            let action = signal.handle(.userPlayed)
            if action == .reloadNow {
                apply(action)
                updateNowPlaying()
                return
            }
            windowStarvedNow = false
            window?.networkReturned()
        }
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
        updateStalled()
        updateNowPlaying()
    }

    public func pause() {
        // Paused while waiting for a signal: it stays paused when the signal returns.
        _ = signal.handle(.userPaused)
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        pausedAt = Date()
        flushListening(reason: .pause)
        updateStalled()
        // A copy that arrived while this part played is used from here on, while it is quiet.
        if let index = currentIndex, !switchingPart, hasNewerCopy(index) {
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
        resetSignal()
        window?.update(key: nil, offsetMs: 0, durationMs: 0, next: nil)
        savedAheadMs = nil
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
        if index == currentIndex, !switchingPart, player.currentItem != nil, !hasNewerCopy(index) {
            updateWindow(index: index, offsetMs: offset)
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
        guard index == currentIndex, !isPlaying, !switchingPart, !refreshing else { return }
        // Waiting for a signal for this very part: the copy ends the wait.
        let resumes = signal.isWaiting && signal.resumes
        resetSignal()
        loadPart(at: positionMs, thenPlay: resumes)
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
        let key = windowKey(book.id, part.id)
        let asset: AVURLAsset
        if let window, usesWindow(part, key: key) {
            // The window must know where the player starts before the player asks for bytes.
            updateWindow(index: index, offsetMs: offset)
            let bookId = book.id, partId = part.id
            asset = window.asset(key: key, url: part.url, typeHint: part.contentType) { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.freshLink(bookId: bookId, partId: partId)
            }
        } else {
            window?.update(key: nil, offsetMs: 0, durationMs: 0, next: nil)
            savedAheadMs = nil
            asset = AVURLAsset(url: part.url)
        }
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

    private func updateStalled() {
        let stalled = playerWaiting || (bufferEmpty && isPlaying && !isLoading)
        guard stalled != isStalled else { return }
        isStalled = stalled
        window?.setStalled(stalled)
        checkSignal()
    }

    private func observe(_ item: AVPlayerItem) {
        bufferEmpty = false
        bufferObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            let empty = item.isPlaybackBufferEmpty
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                self.bufferEmpty = empty
                self.updateStalled()
            }
        }
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
                case .readyToPlay:
                    self.isLoading = false
                    self.updateStalled()
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
        } catch where SpokenEngine.isNetworkUnavailable(error) {
            // No network to bring a link: wait for one rather than fail.
            log.info("part failed with no network; waiting for a signal")
            signalLost(.reload, wasPlaying: thenPlay ?? isPlaying)
        } catch {
            isLoading = false
            isPlaying = false
            errorMessage = (error as? LocalizedError)?.errorDescription ?? message
            log.error("part failed and no fresh link came: \(message, privacy: .public)")
            updateNowPlaying()
        }
    }

    // MARK: - The look-ahead window

    private func windowKey(_ bookId: String, _ partId: String) -> String { bookId + "#" + partId }

    private func usesWindow(_ part: SpokenPart, key: String) -> Bool {
        window != nil && part.streamsByRange && !part.url.isFileURL && !part.isUnresolved && !directOnly.contains(key)
    }

    /// The timeline names a file on the phone that the current item was not made from.
    private func hasNewerCopy(_ index: Int) -> Bool {
        guard let book, book.timeline.parts.indices.contains(index) else { return false }
        let url = book.timeline.parts[index].url
        return url.isFileURL && loadedURL != url
    }

    private func connectWindow() {
        window?.playerAheadSecs = forwardBufferSecs
        window?.onUnsupported = { [weak self] key in
            Task { @MainActor [weak self] in self?.windowRefused(key) }
        }
        window?.onStarved = { [weak self] key, starved in
            Task { @MainActor [weak self] in self?.windowStarved(key, starved) }
        }
    }

    private func windowRefused(_ key: String) {
        guard directOnly.insert(key).inserted, let book, let index = currentIndex,
              windowKey(book.id, book.timeline.parts[index].id) == key, !switchingPart else { return }
        loadPart(at: positionMs, thenPlay: isPlaying)
    }

    private func windowStarved(_ key: String, _ starved: Bool) {
        guard let book, let index = currentIndex, windowKey(book.id, book.timeline.parts[index].id) == key else { return }
        log.info("window \(starved ? "starved" : "fed again", privacy: .public) at \(self.positionMs, privacy: .public) ms")
        windowStarvedNow = starved
        if starved {
            checkSignal()
        } else {
            apply(signal.handle(.fed))
        }
    }

    // MARK: - Riding out a gap in the signal

    /// The network as the app sees it. Back: whatever waits for it is tried now.
    public func networkChanged(isConnected: Bool) {
        networkUp = isConnected
        if isConnected {
            window?.networkReturned()
            apply(signal.handle(.networkReturned))
        } else {
            checkSignal()
        }
    }

    /// The player stalls with nothing to play: through the window when the window can't fetch,
    /// otherwise (a stream the player fetches itself) when there is no network. Either way the
    /// item is intact and is held, waiting.
    private func checkSignal() {
        guard isPlaying, isStalled, !switchingPart, let book, let index = currentIndex else { return }
        let part = book.timeline.parts[index]
        guard !part.url.isFileURL else { return }
        if usesWindow(part, key: windowKey(book.id, part.id)) {
            if windowStarvedNow { signalLost(.hold, wasPlaying: true) }
        } else if !networkUp {
            signalLost(.hold, wasPlaying: true)
        }
    }

    private func signalLost(_ way: SignalWait.Way, wasPlaying: Bool) {
        isLoading = false
        errorMessage = nil
        apply(signal.handle(.lost(way, wasPlaying: wasPlaying)))
        if signal.way == .reload {
            // A failed item plays nothing: paused, and loaded again when there is a link.
            if isPlaying {
                player.pause()
                isPlaying = false
                pausedAt = pausedAt ?? Date()
            }
            if reloadRetry == nil { startReloading(now: false) }
        }
        updateNowPlaying()
    }

    private func apply(_ action: SignalWait.Action) {
        switch action {
        case .none:
            break
        case .pause:
            log.info("no signal at \(self.positionMs, privacy: .public) ms: waiting")
            guard isPlaying else { break }
            // The position is saved as at a pause, and the wait is not counted as listening.
            // The item itself is held, not paused: a paused audio app is suspended in the
            // background, and the player plays on by itself once bytes come.
            flushListening(reason: .pause)
            pausedAt = Date()
        case .resume:
            log.info("signal back: playing on at \(self.positionMs, privacy: .public) ms")
            // The window says again if it still can't fetch.
            windowStarvedNow = false
            window?.networkReturned()
            play()
        case .reloadNow:
            startReloading(now: true)
        case .nudgeWindow:
            windowStarvedNow = false
            window?.networkReturned()
        }
        if signal.way != .reload {
            reloadRetry?.cancel()
            reloadRetry = nil
        }
    }

    private func resetSignal() {
        _ = signal.handle(.reset)
        windowStarvedNow = false
        reloadRetry?.cancel()
        reloadRetry = nil
    }

    /// A fresh link and the part again, 2 s doubling to 30 s apart while there is no network.
    private func startReloading(now: Bool) {
        reloadRetry?.cancel()
        reloadRetry = Task { [weak self] in
            var attempt = now ? 0 : 1
            while !Task.isCancelled {
                if attempt > 0 { try? await Task.sleep(for: .seconds(StreamWindow.retryDelay(attempt: attempt))) }
                guard !Task.isCancelled, let self, self.signal.way == .reload else { return }
                if await self.reloadAfterSignalLoss() { return }
                attempt += 1
            }
        }
    }

    /// True when the wait is over, one way or the other.
    private func reloadAfterSignalLoss() async -> Bool {
        guard let book, let index = currentIndex else { return true }
        let part = book.timeline.parts[index]
        let thenPlay = signal.resumes
        var url = part.url
        if !url.isFileURL, let partRefresher {
            do {
                url = try await partRefresher(book.id, part.id)
            } catch where SpokenEngine.isNetworkUnavailable(error) {
                return false
            } catch {
                resetSignal()
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                updateNowPlaying()
                return true
            }
        }
        guard self.book?.id == book.id, currentIndex == index, signal.way == .reload else { return true }
        self.book = self.book?.replacing(partId: part.id, with: url)
        _ = signal.handle(.reloaded)
        reloadRetry = nil
        windowStarvedNow = false
        log.info("signal back: part \(part.id, privacy: .public) loaded again at \(self.positionMs, privacy: .public) ms")
        if thenPlay, let pausedAt {
            positionMs = book.timeline.clamp(positionMs - smartRewind.rewindMs(pausedFor: Date().timeIntervalSince(pausedAt)))
            self.pausedAt = nil
        }
        loadPart(at: positionMs, thenPlay: thenPlay)
        return true
    }

    /// Where the playhead is, for the window's prefetcher; and how much is saved ahead of it.
    private func updateWindow(index: Int, offsetMs: Int64) {
        guard let window, let book, book.timeline.parts.indices.contains(index) else { savedAheadMs = nil; return }
        let part = book.timeline.parts[index]
        let key = windowKey(book.id, part.id)
        guard usesWindow(part, key: key) else {
            savedAheadMs = nil
            return
        }
        var next: (key: String, durationMs: Int64)?
        var nextPart: SpokenPart?
        if index + 1 < book.timeline.parts.count {
            let candidate = book.timeline.parts[index + 1]
            nextPart = candidate
            let nextKey = windowKey(book.id, candidate.id)
            if usesWindow(candidate, key: nextKey) {
                let bookId = book.id, partId = candidate.id
                window.register(key: nextKey, url: candidate.url, typeHint: candidate.contentType) { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.freshLink(bookId: bookId, partId: partId)
                }
                next = (nextKey, candidate.durationMs)
            }
        }
        window.update(key: key, offsetMs: offsetMs, durationMs: part.durationMs, next: next)
        guard let saved = window.savedAhead(key: key, offsetMs: offsetMs, durationMs: part.durationMs) else {
            savedAheadMs = nil
            return
        }
        var total = saved.ms
        if saved.toEnd, let nextPart {
            if nextPart.url.isFileURL {
                total += nextPart.durationMs
            } else if let next, let more = window.savedAhead(key: next.key, offsetMs: 0, durationMs: next.durationMs) {
                total += more.ms
            }
        }
        if savedAheadMs.map({ abs($0 - total) >= 1000 }) ?? true { savedAheadMs = total }
    }

    /// A new link for a part from the app, kept in the timeline; the item playing goes on.
    private func freshLink(bookId: String, partId: String) async throws -> URL {
        guard let partRefresher else { throw URLError(.userAuthenticationRequired) }
        let url = try await partRefresher(bookId, partId)
        if book?.id == bookId { book = book?.replacing(partId: partId, with: url) }
        return url
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
        updateWindow(index: index, offsetMs: offset)
        // A held player that moves again has its bytes: the wait is over.
        if signal.way == .hold, positionMs > before {
            apply(signal.handle(.fed))
            return
        }
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
            playingSince = isPlaying && !signal.isWaiting ? Date() : nil
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

    // MARK: - Network

    /// An error that means "no network" rather than "the server said no": the app marks its
    /// own such errors with `NetworkUnavailable`.
    public nonisolated static func isNetworkUnavailable(_ error: Error) -> Bool {
        if error is NetworkUnavailable { return true }
        if let error = error as? URLError { return StreamWindow.isUnreachable(error) }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return StreamWindow.isUnreachable(URLError(URLError.Code(rawValue: ns.code))) }
        return false
    }

    // MARK: - Lock screen

    private func updateNowPlaying() {
        guard let book else { return }
        nowPlaying.configureSkips(forwardSecs: skipForwardSecs, backwardSecs: skipBackwardSecs)
        nowPlaying.update(
            title: book.title, artist: book.author, album: currentChapter?.title,
            duration: Double(book.timeline.durationMs) / 1000, elapsedTime: Double(positionMs) / 1000,
            rate: isPlaying && !signal.isWaiting ? rate : 0, artwork: artwork,
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
