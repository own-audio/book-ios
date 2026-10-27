import AVFoundation
import Foundation
import OSLog
import PlayerCore

/// Keeps the next minutes of a streamed book on disk, so a tunnel or a gap in the signal goes
/// unheard. The player reads a streamed file through an `AVAssetResourceLoaderDelegate` (a URL
/// of its own scheme, mapped back to the real link): what is on disk is served from a sparse
/// file per part (`PartCacheFile`), what is not is fetched with HTTP Range. Meanwhile a
/// prefetcher keeps `playhead … playhead + lookAheadSecs` on disk — fetched in a burst of
/// chunks, then the radio is idle until the window has shrunk by a quarter — and near the end
/// of a part, the start of the next.
///
/// Only files that answer Range (the original file); a server's transcode or HLS stream plays
/// as before. A file that turns out not to answer Range, or of a type the player can't be told,
/// is handed back to the engine to stream directly (`onUnsupported`).
public final class StreamWindow: @unchecked Sendable {
    public static let scheme = "spoken-window"

    /// Why a fetch did not bring bytes.
    enum Failure: Error, Equatable {
        /// No network, or none that reaches the server: wait and try again.
        case unreachable
        /// The server ignores Range, gives no length, or sends a type AVFoundation can't be told.
        case unsupported
        case server(Int)
    }

    public let directory: URL
    let session: URLSession
    /// What the player waits for: small, so playback starts quickly.
    let servingChunkBytes: Int64
    /// What the prefetcher fetches at a time.
    let prefetchChunkBytes: Int64
    /// Over the estimate from size and duration: speech is often VBR.
    let margin = 1.2

    /// Told when the player is waiting for bytes the network can't bring (`true`), and when
    /// they come again (`false`).
    public var onStarved: (@Sendable (_ key: String, _ starved: Bool) -> Void)? {
        get { lock.withLock { _onStarved } }
        set { lock.withLock { _onStarved = newValue } }
    }
    /// A part that can't be played through the window; the engine streams it directly.
    public var onUnsupported: (@Sendable (_ key: String) -> Void)? {
        get { lock.withLock { _onUnsupported } }
        set { lock.withLock { _onUnsupported = newValue } }
    }

    /// Where own.audio storage is blocked on this network, its files come through the server's
    /// media proxy; nil fetches every link as it is.
    public var storageRoute: ProxyMemory? {
        get { lock.withLock { _storageRoute } }
        set { lock.withLock { _storageRoute = newValue } }
    }

    private struct Active: Equatable {
        var key: String
        var offsetMs: Int64
        var durationMs: Int64
    }

    private struct Upcoming {
        var key: String
        var durationMs: Int64
    }

    private let lock = NSLock()
    private var _lookAheadSecs: Double = 600
    private var _playerAheadSecs: Double = 180
    private var _onStarved: (@Sendable (String, Bool) -> Void)?
    private var _onUnsupported: (@Sendable (String) -> Void)?
    private var _storageRoute: ProxyMemory?
    private var files: [String: PartCacheFile] = [:]
    private var links: [String: URL] = [:]
    private var typeHints: [String: String] = [:]
    private var refreshers: [String: @Sendable () async throws -> URL] = [:]
    private var inFlight: [String: [Range<Int64>]] = [:]
    private var refreshing: [String: Task<URL, Error>] = [:]
    private var starved: Set<String> = []
    /// Where the player's last read of each part stopped.
    private var readHeads: [String: Int64] = [:]
    private var active: Active?
    private var upcoming: Upcoming?
    private var stalled = false
    private var prefetching: Task<Void, Never>?
    private var prefetchRetryAt = Date.distantPast
    private var prefetchFailures = 0
    private var loaders: [String: Loader] = [:]
    private var wakeGeneration = 0
    private let loaderQueue = DispatchQueue(label: "audio.own.player.window")
    private let log = Logger(subsystem: "audio.own.player", category: "window")

    /// `servingChunkBytes` and `prefetchChunkBytes` are there for tests; 256 KB keeps the start
    /// quick, 1 MB keeps the requests few.
    public init(directory: URL, session: URLSession = .shared, servingChunkBytes: Int64 = 256 << 10, prefetchChunkBytes: Int64 = 1 << 20) {
        self.directory = directory
        self.session = session
        self.servingChunkBytes = servingChunkBytes
        self.prefetchChunkBytes = prefetchChunkBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// How far ahead of the playhead to keep on disk.
    public var lookAheadSecs: Double {
        get { lock.withLock { _lookAheadSecs } }
        set { lock.withLock { _lookAheadSecs = max(1, newValue) } }
    }

    /// How far ahead the player itself buffers in memory: reads within that are never held
    /// back, whatever the window, or the player would starve with bytes it was promised.
    var playerAheadSecs: Double {
        get { lock.withLock { _playerAheadSecs } }
        set { lock.withLock { _playerAheadSecs = max(0, newValue) } }
    }

    // MARK: - For the engine

    /// The asset the player plays a streamed part from. `refresher` brings a new link when the
    /// server refuses the one it has (401/403).
    func asset(key: String, url: URL, typeHint: String?, refresher: @escaping @Sendable () async throws -> URL) -> AVURLAsset {
        register(key: key, url: url, typeHint: typeHint, refresher: refresher)
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "part"
        components.path = "/" + UUID().uuidString
        let asset = AVURLAsset(url: components.url!)
        let loader = Loader(window: self, key: key)
        lock.withLock { loaders[key] = loader }
        asset.resourceLoader.setDelegate(loader, queue: loaderQueue)
        file(for: key).touch()
        return asset
    }

    /// The link of a part the prefetcher may fetch from (the next part).
    func register(key: String, url: URL, typeHint: String?, refresher: @escaping @Sendable () async throws -> URL) {
        lock.withLock {
            links[key] = url
            if let typeHint { typeHints[key] = typeHint }
            refreshers[key] = refresher
        }
    }

    /// Where the player is, and which part follows (if it streams through the window too);
    /// starts a burst of fetching when the window has shrunk.
    func update(key: String?, offsetMs: Int64, durationMs: Int64, next: (key: String, durationMs: Int64)?) {
        let start: Bool = lock.withLock {
            active = key.map { Active(key: $0, offsetMs: offsetMs, durationMs: durationMs) }
            upcoming = next.map { Upcoming(key: $0.key, durationMs: $0.durationMs) }
            guard active != nil, prefetching == nil, Date() >= prefetchRetryAt else { return false }
            return true
        }
        guard start, needsFetching() else { return }
        lock.withLock {
            guard prefetching == nil else { return }
            prefetching = Task.detached(priority: .utility) { [weak self] in
                await self?.prefetchBurst()
                self?.lock.withLock { self?.prefetching = nil }
            }
        }
    }

    /// The player is waiting for data: fetch past the window's end for it.
    func setStalled(_ value: Bool) {
        lock.withLock { stalled = value }
    }

    /// Milliseconds of `key` on disk from `offsetMs` on, and whether that reaches the part's
    /// end; nil while its size is not known yet.
    func savedAhead(key: String, offsetMs: Int64, durationMs: Int64) -> (ms: Int64, toEnd: Bool)? {
        let file = file(for: key)
        guard let total = file.totalLength, total > 0, durationMs > 0 else { return nil }
        let at = Self.byte(atMs: offsetMs, durationMs: durationMs, total: total)
        let end = file.contiguousEnd(from: at)
        let ms = Int64(Double(end - at) / Double(total) * Double(durationMs))
        return (max(0, ms), end >= total)
    }

    /// A network came back: waits for a retry end now.
    public func networkReturned() {
        lock.withLock {
            wakeGeneration += 1
            prefetchRetryAt = .distantPast
            prefetchFailures = 0
        }
    }

    // MARK: - Disk

    /// What the window keeps on disk, in bytes.
    public func totalBytes() -> Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? []
        return urls.filter { $0.pathExtension == "part" }.reduce(0) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
    }

    /// Lets the least recently played parts go until the window fits `capBytes`; `protecting`
    /// (the part playing, the next) stay.
    public func enforce(capBytes: Int64, protecting: Set<String>) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var entries: [(key: String, bytes: Int64, used: Date)] = []
        for url in urls where url.pathExtension == "json" {
            guard let key = PartCacheFile.key(fromFileName: url.deletingPathExtension().lastPathComponent) else { continue }
            let probe = file(for: key)
            entries.append((key, probe.diskBytes, probe.snapshot.lastUsed))
        }
        var total = entries.reduce(0) { $0 + $1.bytes }
        let activeKey = lock.withLock { active?.key }
        for entry in entries.sorted(by: { $0.used < $1.used }) where total > capBytes {
            guard !protecting.contains(entry.key), entry.key != activeKey else { continue }
            file(for: entry.key).remove()
            lock.withLock { files[entry.key] = nil }
            total -= entry.bytes
        }
    }

    public func clear() {
        lock.withLock { files = [:] }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func file(for key: String) -> PartCacheFile {
        lock.withLock {
            if let file = files[key] { return file }
            let file = PartCacheFile(directory: directory, key: key)
            files[key] = file
            return file
        }
    }

    // MARK: - Serving the player

    fileprivate func serve(_ request: LoadingRequest, key: String) async {
        let file = file(for: key)
        do {
            if let info = request.value.contentInformationRequest {
                if file.totalLength == nil || file.uti == nil {
                    try await fetchWaiting(key: key, file: file, range: 0..<servingChunkBytes)
                }
                guard let total = file.totalLength, let uti = file.uti else { throw Failure.unsupported }
                info.contentType = uti
                info.contentLength = total
                info.isByteRangeAccessSupported = true
            }
            if let dataRequest = request.value.dataRequest {
                try await deliver(dataRequest, key: key, file: file)
            }
            try Task.checkCancellation()
            request.value.finishLoading()
        } catch is CancellationError {
            // The player let go of the request (a seek, a new item).
        } catch Failure.unsupported {
            log.info("\(key, privacy: .public) can't play through the window; streaming it directly")
            request.value.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotDecodeContentData))
            onUnsupported?(key)
        } catch {
            log.error("\(key, privacy: .public): \(String(describing: error), privacy: .public)")
            request.value.finishLoading(with: error)
        }
    }

    private func deliver(_ dataRequest: AVAssetResourceLoadingDataRequest, key: String, file: PartCacheFile) async throws {
        guard let total = file.totalLength else { throw Failure.unsupported }
        let requestStart = dataRequest.requestedOffset
        let end = dataRequest.requestsAllDataToEndOfResource ? total : min(total, requestStart + Int64(dataRequest.requestedLength))
        var offset = dataRequest.currentOffset
        while offset < end {
            try Task.checkCancellation()
            let stored = file.contiguousEnd(from: offset)
            if stored > offset {
                let upto = min(stored, end, offset + servingChunkBytes)
                guard let data = file.read(offset..<upto) else { throw Failure.unsupported }
                dataRequest.respond(with: data)
                offset = upto
                lock.withLock { readHeads[key] = upto }
                continue
            }
            if isInFlight(key: key, offset: offset) {
                try await Task.sleep(for: .milliseconds(50))
                continue
            }
            // The player reads on ahead as fast as it is fed; past the window it waits for the
            // playhead to move, so a long file is not fetched whole on mobile data.
            if dataRequest.requestsAllDataToEndOfResource, holdsBack(key: key, requestStart: requestStart, offset: offset, total: total) {
                try await Task.sleep(for: .milliseconds(250))
                continue
            }
            let stop = min(end, offset + servingChunkBytes, file.nextStored(after: offset) ?? end)
            try await fetchWaiting(key: key, file: file, range: offset..<stop)
        }
    }

    /// A fetch the player waits for: with no network it is tried again, 2 s doubling to 30 s
    /// (sooner when the network returns), and the engine is told the player is starved.
    private func fetchWaiting(key: String, file: PartCacheFile, range: Range<Int64>) async throws {
        var attempt = 0
        while true {
            do {
                try await fetch(key: key, file: file, range: range)
                // Fed again — whichever request it was that starved.
                if lock.withLock({ starved.remove(key) }) != nil { onStarved?(key, false) }
                return
            } catch Failure.unreachable {
                attempt += 1
                lock.withLock { _ = starved.insert(key) }
                // Every failed try, so a player that resumed too early hears it again.
                onStarved?(key, true)
                try await waitBeforeRetry(attempt: attempt)
            }
        }
    }

    private func holdsBack(key: String, requestStart: Int64, offset: Int64, total: Int64) -> Bool {
        lock.withLock {
            guard !stalled, let active, active.key == key, active.durationMs > 0 else { return false }
            let playhead = Self.byte(atMs: active.offsetMs, durationMs: active.durationMs, total: total)
            let bytesPerSec = Double(total) / Double(active.durationMs) * 1000
            let playerBytes = Int64(bytesPerSec * _playerAheadSecs * margin) + servingChunkBytes
            let windowEnd = playhead + max(windowBytesLocked(durationMs: active.durationMs, total: total), playerBytes)
            // A read that begins near the playhead, or goes on where the last one stopped, is
            // listening. One that begins elsewhere is the player looking something up (an index
            // at the end of the file): it gets what it asks for.
            let nearPlayhead = requestStart >= playhead - (2 << 20) && requestStart <= windowEnd
            let continues = readHeads[key].map { abs(requestStart - $0) <= servingChunkBytes } ?? false
            return (nearPlayhead || continues) && offset >= windowEnd
        }
    }

    private func windowBytesLocked(durationMs: Int64, total: Int64) -> Int64 {
        Int64(Double(total) / Double(durationMs) * _lookAheadSecs * 1000 * margin)
    }

    static func byte(atMs offsetMs: Int64, durationMs: Int64, total: Int64) -> Int64 {
        guard durationMs > 0 else { return 0 }
        return min(total, max(0, Int64(Double(total) * Double(offsetMs) / Double(durationMs))))
    }

    /// Backoff while there is no network: 2, 4, 8, 16, then 30 s.
    static func retryDelay(attempt: Int) -> Double {
        min(30, 2 * pow(2, Double(max(0, attempt - 1))))
    }

    private func waitBeforeRetry(attempt: Int) async throws {
        let generation = lock.withLock { wakeGeneration }
        let deadline = Date().addingTimeInterval(Self.retryDelay(attempt: attempt))
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
            if lock.withLock({ wakeGeneration }) != generation { return }
        }
    }

    // MARK: - Fetching

    private func isInFlight(key: String, offset: Int64) -> Bool {
        lock.withLock { inFlight[key]?.contains { $0.contains(offset) } ?? false }
    }

    private func fetch(key: String, file: PartCacheFile, range: Range<Int64>) async throws {
        guard !range.isEmpty else { return }
        let (link, refresher, hint) = lock.withLock { (links[key], refreshers[key], typeHints[key]) }
        guard var url = link else { throw Failure.server(404) }
        lock.withLock { inFlight[key, default: []].append(range) }
        defer { lock.withLock { inFlight[key]?.removeAll { $0 == range } } }
        var refreshed = false
        while true {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await load(request)
            } catch {
                // The player let go of the request: nothing failed.
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                throw SpokenEngine.isNetworkUnavailable(error) ? Failure.unreachable : error
            }
            guard let http = response as? HTTPURLResponse else { throw Failure.server(0) }
            switch http.statusCode {
            case 206:
                guard let (start, total) = Self.contentRange(http.value(forHTTPHeaderField: "Content-Range")), let total, total > 0 else {
                    throw Failure.unsupported
                }
                if file.uti == nil || file.totalLength != total {
                    if start == 0 {
                        guard let uti = Self.uti(prefix: data, mimeType: http.mimeType, hint: hint) else { throw Failure.unsupported }
                        file.setInfo(totalLength: total, uti: uti)
                        log.info("\(key, privacy: .public): \(total, privacy: .public) bytes of \(uti, privacy: .public), through the window")
                    } else {
                        // The type is told by the file's first bytes: those first.
                        try await fetch(key: key, file: file, range: 0..<min(servingChunkBytes, total))
                        guard file.uti != nil, file.totalLength == total else { throw Failure.unsupported }
                    }
                }
                file.write(data, at: start)
                return
            case 200:
                // The whole file, Range ignored: nothing to keep a window of.
                throw Failure.unsupported
            case 401, 403:
                guard !refreshed, let refresher else { throw Failure.server(http.statusCode) }
                refreshed = true
                // Another fetch of this part may have renewed the link meanwhile; else one
                // renewal is shared by all of them.
                if let current = lock.withLock({ links[key] }), current != url {
                    url = current
                    continue
                }
                do {
                    url = try await sharedRefresh(key: key, refresher: refresher)
                } catch {
                    throw SpokenEngine.isNetworkUnavailable(error) ? Failure.unreachable : error
                }
                log.info("\(key, privacy: .public): the link was refused (\(http.statusCode)); fetched a new one")
            case 416:
                return
            default:
                throw Failure.server(http.statusCode)
            }
        }
    }

    /// One request, through the media proxy when storage is blocked (`ProxyMemory`).
    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let storageRoute, let link = request.url else { return try await session.data(for: request) }
        let session = session
        return try await storageRoute.fetch(link) { url in
            var routed = request
            routed.url = url
            return try await session.data(for: routed)
        }
    }

    private func sharedRefresh(key: String, refresher: @escaping @Sendable () async throws -> URL) async throws -> URL {
        let task: Task<URL, Error> = lock.withLock {
            if let running = refreshing[key] { return running }
            let task = Task<URL, Error> { try await refresher() }
            refreshing[key] = task
            return task
        }
        do {
            let url = try await task.value
            lock.withLock {
                links[key] = url
                refreshing[key] = nil
            }
            return url
        } catch {
            lock.withLock { refreshing[key] = nil }
            throw error
        }
    }

    /// `bytes 0-1023/52428800` → (0, 52428800); a `*` length is nil.
    static func contentRange(_ header: String?) -> (start: Int64, total: Int64?)? {
        guard let header, header.lowercased().hasPrefix("bytes ") else { return nil }
        let rest = header.dropFirst(6)
        let parts = rest.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let dash = parts[0].firstIndex(of: "-"), let start = Int64(parts[0][..<dash]) else { return nil }
        return (start, Int64(parts[1]))
    }

    /// The type to tell AVFoundation: the file's own first bytes, else the server's content
    /// type, else what the server's record said.
    static func uti(prefix: Data, mimeType: String?, hint: String?) -> String? {
        let ext = TrackFileCache.fileExtension(prefix: prefix) ?? TrackFileCache.fileExtension(mimeType: mimeType) ?? TrackFileCache.fileExtension(mimeType: hint)
        return ext.flatMap(uti(fileExtension:))
    }

    static func uti(fileExtension: String) -> String? {
        switch fileExtension {
        case "m4a", "m4b", "mp4", "aac": AVFileType.m4a.rawValue
        case "mp3": AVFileType.mp3.rawValue
        case "flac": "org.xiph.flac"
        case "wav": AVFileType.wav.rawValue
        case "aiff": AVFileType.aiff.rawValue
        default: nil
        }
    }

    static func isUnreachable(_ error: URLError) -> Bool {
        [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
         .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive, .secureConnectionFailed].contains(error.code)
    }

    // MARK: - Prefetching

    private func needsFetching() -> Bool {
        !plannedRanges(refill: true).isEmpty
    }

    /// What the window lacks. With `refill`, nothing until the stretch on disk ahead of the
    /// playhead has shrunk below three quarters of the window: one burst, then quiet.
    func plannedRanges(refill: Bool) -> [(key: String, range: Range<Int64>)] {
        let (active, upcoming, lookAhead) = lock.withLock { (self.active, self.upcoming, _lookAheadSecs) }
        guard let active else { return [] }
        let current = file(for: active.key)
        guard let total = current.totalLength, active.durationMs > 0 else {
            // Size not known yet: the player's own first request tells it, and the window is
            // planned at the next tick rather than fetching the same bytes twice.
            return []
        }
        var out: [(String, Range<Int64>)] = []
        let playhead = Self.byte(atMs: active.offsetMs, durationMs: active.durationMs, total: total)
        let windowBytes = Int64(Double(total) / Double(active.durationMs) * lookAhead * 1000 * margin)
        let windowEnd = min(total, playhead + windowBytes)
        let onDisk = current.contiguousEnd(from: playhead)
        let shrunk = onDisk < windowEnd && (onDisk - playhead) < windowBytes * 3 / 4
        if !refill || shrunk || onDisk == playhead {
            out += current.missing(in: playhead..<windowEnd).map { (active.key, $0) }
        }
        // Near the end of the part, the start of the next.
        let remainingMs = active.durationMs - active.offsetMs
        if let upcoming, Double(remainingMs) < lookAhead * 1000, upcoming.durationMs > 0 {
            let next = file(for: upcoming.key)
            if let nextTotal = next.totalLength {
                let wantMs = Int64(lookAhead * 1000) - remainingMs
                let wantBytes = min(nextTotal, Int64(Double(nextTotal) / Double(upcoming.durationMs) * Double(wantMs) * margin))
                let missing = next.missing(in: 0..<wantBytes)
                if !refill || shrunk || next.contiguousEnd(from: 0) < wantBytes * 3 / 4 || out.isEmpty {
                    out += missing.map { (upcoming.key, $0) }
                }
            } else {
                out.append((upcoming.key, 0..<prefetchChunkBytes))
            }
        }
        return out
    }

    private func prefetchBurst() async {
        while !Task.isCancelled {
            guard let (key, range) = plannedRanges(refill: false).first(where: { !isInFlight(key: $0.key, offset: $0.range.lowerBound) }) else { return }
            let chunk = range.lowerBound..<min(range.upperBound, range.lowerBound + prefetchChunkBytes)
            do {
                try await fetch(key: key, file: file(for: key), range: chunk)
                lock.withLock { prefetchFailures = 0 }
            } catch Failure.unreachable {
                // No network: the next try waits, 2 s doubling to 30 s, or until it returns.
                lock.withLock {
                    prefetchFailures += 1
                    prefetchRetryAt = Date().addingTimeInterval(Self.retryDelay(attempt: prefetchFailures))
                }
                return
            } catch {
                log.error("prefetch of \(key, privacy: .public) stopped: \(String(describing: error), privacy: .public)")
                lock.withLock { prefetchRetryAt = Date().addingTimeInterval(60) }
                if case Failure.unsupported = error { onUnsupported?(key) }
                return
            }
        }
    }
}

/// `AVAssetResourceLoadingRequest` is not `Sendable`; it is answered from one task at a time,
/// and AVFoundation lets that be any thread.
private struct LoadingRequest: @unchecked Sendable {
    let value: AVAssetResourceLoadingRequest
}

/// The delegate of one asset: each loading request is served by a task, cancelled when the
/// player lets go of it. Called on the window's serial queue.
private final class Loader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    weak var window: StreamWindow?
    let key: String
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let lock = NSLock()

    init(window: StreamWindow, key: String) {
        self.window = window
        self.key = key
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let window, loadingRequest.request.url?.scheme == StreamWindow.scheme else { return false }
        let id = ObjectIdentifier(loadingRequest)
        let request = LoadingRequest(value: loadingRequest)
        let key = key
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await window.serve(request, key: key)
            self?.lock.withLock { self?.tasks[id] = nil }
        }
        lock.withLock { tasks[id] = task }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        lock.withLock { tasks.removeValue(forKey: ObjectIdentifier(loadingRequest)) }?.cancel()
    }
}
