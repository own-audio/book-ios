import AVFoundation
import Foundation
import Testing

@testable import PlayerCore
@testable import SpokenEngine

@Suite("Byte ranges")
struct ByteRangesTests {
    @Test("ranges merge with their neighbours and overlaps; what is missing is found")
    func merging() {
        var ranges = ByteRanges([0..<10, 20..<30])
        #expect(ranges.ranges == [0..<10, 20..<30] && ranges.byteCount == 20)
        ranges.insert(10..<20)
        #expect(ranges.ranges == [0..<30], "touching ranges become one")
        ranges.insert(40..<50)
        ranges.insert(45..<60)
        #expect(ranges.ranges == [0..<30, 40..<60])
        #expect(ranges.contains(5..<25) && !ranges.contains(25..<45))
        #expect(ranges.contiguousEnd(from: 3) == 30 && ranges.contiguousEnd(from: 30) == 30 && ranges.contiguousEnd(from: 41) == 60)
        #expect(ranges.nextStored(after: 30) == 40 && ranges.nextStored(after: 40) == nil)
        #expect(ranges.missing(in: 0..<100) == [30..<40, 60..<100])
        #expect(ranges.missing(in: 5..<25).isEmpty)
        #expect(ranges.missing(in: 25..<45) == [30..<40])
    }

    @Test("a Content-Range header gives the start and the length")
    func contentRange() {
        #expect(StreamWindow.contentRange("bytes 0-1023/52428800")! == (0, 52_428_800))
        #expect(StreamWindow.contentRange("bytes 100-199/*")!.total == nil)
        #expect(StreamWindow.contentRange("items 1-2/3") == nil)
    }

    @Test("the player is told the type from the file's first bytes, else the server's")
    func types() throws {
        let m4b = try Data(contentsOf: fixture("test-book.m4b")).prefix(12)
        #expect(StreamWindow.uti(prefix: m4b, mimeType: "application/octet-stream", hint: nil) == AVFileType.m4a.rawValue)
        let mp3 = try Data(contentsOf: fixture("test-tone.mp3")).prefix(12)
        #expect(StreamWindow.uti(prefix: mp3, mimeType: nil, hint: nil) == AVFileType.mp3.rawValue)
        let flac = try Data(contentsOf: fixture("test-tone.flac")).prefix(12)
        #expect(StreamWindow.uti(prefix: flac, mimeType: nil, hint: nil) == "org.xiph.flac")
        #expect(StreamWindow.uti(prefix: Data("garbage".utf8), mimeType: "audio/mpeg", hint: nil) == AVFileType.mp3.rawValue)
        #expect(StreamWindow.uti(prefix: Data(), mimeType: nil, hint: "audio/mp4") == AVFileType.m4a.rawValue)
        #expect(StreamWindow.uti(prefix: Data("OggS".utf8), mimeType: "audio/ogg", hint: nil) == nil, "not a type the player takes")
    }

    @Test("no network: tried again after 2 s, doubling to 30 s")
    func backoff() {
        #expect((1...7).map { StreamWindow.retryDelay(attempt: $0) } == [2, 4, 8, 16, 30, 30, 30])
    }
}

/// A server for the stub session that answers Range like own.audio and Audiobookshelf do:
/// 206 with Content-Range. It can lose its network, refuse an old link, or ignore Range.
final class RangeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: (data: Data, type: String)] = [:]
    private var _offline = false
    private var _ranges: [String] = []
    var refusedToken: String?
    var ignoresRange = false
    /// After this many answers the network is gone (`offline` turns on by itself).
    var cutAfter: Int?
    /// How the network is gone: no network at all, or a server that does not answer.
    var failure: URLError.Code = .notConnectedToInternet
    /// Hosts this network can't reach: own.audio's storage behind a company firewall.
    var blockedHosts: Set<String> = []
    /// How a blocked host fails: a name that does not resolve, else this status from a proxy.
    var blockedStatus: Int?
    private var _servedHosts: [String] = []
    /// The host of every request that reached a file.
    var servedHosts: [String] { lock.withLock { _servedHosts } }

    var offline: Bool {
        get { lock.withLock { _offline } }
        set { lock.withLock { _offline = newValue } }
    }
    var ranges: [String] { lock.withLock { _ranges } }

    func add(_ path: String, fixture name: String, type: String) throws {
        files[path] = (try Data(contentsOf: fixture(name)), type)
    }

    func respond(_ request: URLRequest) throws -> MockURLProtocol.StubbedResponse {
        let cut: Bool = lock.withLock {
            if let cutAfter, _ranges.count >= cutAfter { _offline = true }
            return _offline
        }
        if cut { throw URLError(failure) }
        let url = request.url!
        if let refusedToken, url.query?.contains("token=\(refusedToken)") == true {
            return .init(statusCode: 403, body: Data())
        }
        if url.path == "/api/v2/stream" {
            // own.audio's stream link: a redirect to storage, or with `route=proxy` to the
            // server's media proxy on its own domain.
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let path = query.first { $0.name == "i" }?.value ?? ""
            let proxied = query.contains { $0.name == "route" && $0.value == "proxy" }
            let target = URL(string: "https://\(proxied ? "media.example" : "storage.example")\(path)")!
            return .init(statusCode: 302, body: Data(), redirectTo: target)
        }
        if let host = url.host, blockedHosts.contains(host) {
            if let blockedStatus { return .init(statusCode: blockedStatus, body: Data("Blocked by policy".utf8), headers: ["Content-Type": "text/html"]) }
            throw URLError(.cannotFindHost, userInfo: [NSURLErrorFailingURLErrorKey: url])
        }
        guard let file = files[url.path] else { return .init(statusCode: 404, body: Data()) }
        let header = request.value(forHTTPHeaderField: "Range") ?? ""
        lock.withLock {
            _ranges.append(header)
            _servedHosts.append(url.host ?? "")
        }
        guard !ignoresRange, header.hasPrefix("bytes="), let dash = header.firstIndex(of: "-") else {
            return .init(statusCode: 200, body: file.data, headers: ["Content-Type": file.type])
        }
        let total = file.data.count
        let start = Int(header[header.index(header.startIndex, offsetBy: 6)..<dash]) ?? 0
        let end = min(total - 1, Int(header[header.index(after: dash)...]) ?? total - 1)
        guard start < total else { return .init(statusCode: 416, body: Data(), headers: ["Content-Range": "bytes */\(total)"]) }
        return .init(statusCode: 206, body: file.data.subdata(in: start..<end + 1), headers: [
            "Content-Type": file.type, "Content-Range": "bytes \(start)-\(end)/\(total)", "Content-Length": "\(end - start + 1)",
        ])
    }
}

/// O2: a streamed part plays through the look-ahead window and keeps playing from disk.
@Suite("Look-ahead window", .serialized)
@MainActor
struct StreamWindowTests {
    final class Calls: @unchecked Sendable { var count = 0 }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("window-\(UUID().uuidString)", isDirectory: true)
    }

    private func setUp(_ server: RangeServer, directory: URL? = nil) async -> (SpokenEngine, StreamWindow) {
        let session = await MockURLProtocol.makeStubbedSession { request in try server.respond(request) }
        // Small chunks, so a 20 KB file takes several ranges.
        let window = StreamWindow(directory: directory ?? self.directory(), session: session.urlSession, servingChunkBytes: 4096, prefetchChunkBytes: 8192)
        let engine = SpokenEngine(nowPlaying: NowPlayingController(), resumeStore: InMemoryResumeStore())
        engine.window = window
        return (engine, window)
    }

    private func streamedBook(_ path: String = "/files/book.m4b", token: String = "t1", durationMs: Int64 = 6000) -> SpokenBook {
        SpokenBook(id: "book1", title: "T", author: nil, parts: [
            SpokenPart(id: "p1", url: URL(string: "https://server.example\(path)?token=\(token)")!, durationMs: durationMs, streamsByRange: true),
        ], chapters: [])
    }

    @Test("a streamed part plays through the window, fetched in Range chunks, and the window fills")
    func fills() async throws {
        let server = RangeServer()
        try server.add("/files/book.m4b", fixture: "test-book.m4b", type: "audio/mp4")
        let (engine, window) = await setUp(server)
        engine.load(streamedBook(), at: 500, autoplay: true)
        #expect(await wait(until: { engine.isPlaying && engine.positionMs > 1200 }, seconds: 10), "plays from the window")
        #expect(engine.errorMessage == nil)
        #expect(await wait(until: { window.file(for: "book1#p1").isComplete }), "a 6 s file is inside a 10 min window")
        #expect(server.ranges.allSatisfy { $0.hasPrefix("bytes=") } && server.ranges.count >= 3, "only Range requests, in chunks")
        #expect(engine.savedAheadMs != nil && (engine.savedAheadMs ?? 0) > 3000, "the player can say how much is saved")
        engine.stop()
    }

    @Test("with the network cut, playback goes on from what is on disk")
    func playsFromDiskOffline() async throws {
        let server = RangeServer()
        try server.add("/files/book.m4b", fixture: "test-book.m4b", type: "audio/mp4")
        let (engine, window) = await setUp(server)
        engine.load(streamedBook(), at: 0, autoplay: true)
        #expect(await wait(until: { window.file(for: "book1#p1").isComplete }, seconds: 10))
        server.offline = true
        let before = server.ranges.count
        engine.seek(to: 3500)
        #expect(await wait(until: { engine.positionMs > 4500 }, seconds: 10), "plays on with no network")
        engine.stop()

        // A new item for the same part, still offline: every byte comes from disk.
        engine.load(streamedBook(), at: 1000, autoplay: true)
        #expect(await wait(until: { engine.positionMs > 2000 }, seconds: 10), "a reload plays from disk too")
        #expect(engine.errorMessage == nil && server.ranges.count == before)
        engine.stop()
    }

    @Test("the range map survives a relaunch: a new window on the same folder plays with no network")
    func survivesRelaunch() async throws {
        let server = RangeServer()
        try server.add("/files/book.m4b", fixture: "test-book.m4b", type: "audio/mp4")
        let folder = directory()
        let (first, window) = await setUp(server, directory: folder)
        first.load(streamedBook(), at: 0, autoplay: true)
        #expect(await wait(until: { window.file(for: "book1#p1").isComplete }, seconds: 10))
        let map = window.file(for: "book1#p1").snapshot
        first.stop()

        server.offline = true
        let (second, relaunched) = await setUp(server, directory: folder)
        #expect(relaunched.file(for: "book1#p1").snapshot.ranges == map.ranges)
        #expect(relaunched.file(for: "book1#p1").snapshot.uti == AVFileType.m4a.rawValue)
        second.load(streamedBook(), at: 2000, autoplay: true)
        #expect(await wait(until: { second.positionMs > 3000 }, seconds: 10), "plays from the saved bytes")
        #expect(second.errorMessage == nil)
        second.stop()
    }

    @Test("a link the server refuses (403) is renewed through the app once, and playback goes on")
    func refreshesOn403() async throws {
        let server = RangeServer()
        try server.add("/files/book.m4b", fixture: "test-book.m4b", type: "audio/mp4")
        server.refusedToken = "old"
        let (engine, _) = await setUp(server)
        let calls = Calls()
        engine.partRefresher = { _, _ in
            calls.count += 1
            return URL(string: "https://server.example/files/book.m4b?token=new")!
        }
        engine.load(streamedBook(token: "old"), at: 0, autoplay: true)
        #expect(await wait(until: { engine.positionMs > 1000 }, seconds: 10), "plays with the new link")
        #expect(calls.count == 1 && engine.errorMessage == nil)
        #expect(engine.book?.timeline.parts[0].url.query == "token=new", "the timeline keeps the new link")
        engine.stop()
    }

    /// A book whose part is own.audio's stream link, which redirects to storage.
    private func linkedBook(streamsByRange: Bool = true) -> (SpokenBook, URL) {
        let link = URL(string: "https://server.example/api/v2/stream?i=/files/book.m4b&f=orig&b=0&o=0&u=u1&e=1900000000&k=1&s=sig")!
        return (SpokenBook(id: "book1", title: "T", author: nil, parts: [
            SpokenPart(id: "p1", url: link, durationMs: 6000, streamsByRange: streamsByRange),
        ], chapters: []), link)
    }

    @Test("storage blocked on this network: the window fetches through the server's media proxy and remembers it",
          arguments: [nil, 403, 451])
    func storageBlocked(status: Int?) async throws {
        let server = RangeServer()
        try server.add("/files/book.m4b", fixture: "test-book.m4b", type: "audio/mp4")
        server.blockedHosts = ["storage.example"]
        server.blockedStatus = status
        let (engine, _) = await setUp(server)
        let memory = ProxyMemory(defaults: UserDefaults(suiteName: "route-\(UUID().uuidString)")!)
        memory.network = "up,wifi-en0"
        engine.storageRoute = memory
        let (book, link) = linkedBook()
        engine.load(book, at: 0, autoplay: true)
        #expect(await wait(until: { engine.positionMs > 1500 }, seconds: 10), "plays through the proxy")
        #expect(engine.errorMessage == nil && !engine.isWaitingForSignal)
        #expect(!server.servedHosts.isEmpty && server.servedHosts.allSatisfy { $0 == "media.example" })
        #expect(memory.usesProxy(for: link))
        engine.stop()
    }

    @Test("a part the player streams itself: blocked storage is found and the part loaded again through the proxy")
    func directPathReroutes() async throws {
        let server = RangeServer()
        try server.add("/files/book.m4b", fixture: "test-book.m4b", type: "audio/mp4")
        server.blockedHosts = ["storage.example"]
        // The window's session is where the engine asks; the part itself is not windowed.
        let (engine, _) = await setUp(server)
        let memory = ProxyMemory(defaults: UserDefaults(suiteName: "route-\(UUID().uuidString)")!)
        engine.storageRoute = memory
        let (book, link) = linkedBook(streamsByRange: false)
        engine.load(book, at: 0, autoplay: true)
        #expect(engine.loadedRoute == link)
        // AVPlayer can't reach the test's hosts at all; what matters is that its failure leads
        // to the check and to the part being loaded again by the proxy.
        #expect(await wait(until: { engine.loadedRoute.map(StorageRoute.isProxied) == true }, seconds: 20))
        #expect(memory.usesProxy(for: link))
        engine.stop()
    }

    @Test("past the window the player waits for the playhead: the file is not fetched whole at once, and plays to the end")
    func boundedWindow() async throws {
        let server = RangeServer()
        try server.add("/files/book.m4b", fixture: "test-book.m4b", type: "audio/mp4")
        let (engine, window) = await setUp(server)
        // One second ahead of a 6-second file: about 4 kB.
        window.lookAheadSecs = 1
        engine.forwardBufferSecs = 1
        engine.load(streamedBook(), at: 0, autoplay: true)
        #expect(await wait(until: { engine.positionMs > 1000 }, seconds: 10))
        let file = window.file(for: "book1#p1")
        let total = file.totalLength ?? 0
        #expect(total > 0 && file.storedBytes < total - 4096, "only the window and the player's next read: \(file.storedBytes) of \(total)")
        #expect(await wait(until: { engine.positionMs > 5500 || !engine.isPlaying }, seconds: 15))
        #expect(engine.positionMs > 5500 && engine.errorMessage == nil, "held back, never stuck")
        engine.stop()
    }

    @Test("MP3 and FLAC are told to the player by type and play through the window")
    func otherTypes() async throws {
        let server = RangeServer()
        try server.add("/files/tone.mp3", fixture: "test-tone.mp3", type: "audio/mpeg")
        try server.add("/files/tone.flac", fixture: "test-tone.flac", type: "audio/flac")
        let (engine, _) = await setUp(server)
        for path in ["/files/tone.mp3", "/files/tone.flac"] {
            engine.load(streamedBook(path, durationMs: 3000), at: 0, autoplay: true)
            #expect(await wait(until: { engine.positionMs > 800 }, seconds: 10), "\(path) plays")
            #expect(engine.errorMessage == nil)
            engine.stop()
        }
    }

    @Test("a server that ignores Range: the part is streamed directly instead")
    func rangeIgnored() async throws {
        let server = RangeServer()
        try server.add("/files/book.m4b", fixture: "test-book.m4b", type: "audio/mp4")
        server.ignoresRange = true
        let (engine, _) = await setUp(server)
        engine.load(streamedBook(), at: 0, autoplay: true)
        #expect(await wait(until: { engine.directOnly.contains("book1#p1") }, seconds: 10))
        engine.stop()
    }

    @Test("the window is the look-ahead from the playhead plus 20 %, and refills only once it has shrunk")
    func windowBounds() {
        let window = StreamWindow(directory: directory())
        window.lookAheadSecs = 60
        let file = window.file(for: "b#p")
        // A 10-minute part of 6 MB: 10 kB per second.
        file.setInfo(totalLength: 6_000_000, uti: AVFileType.mp3.rawValue)
        window.update(key: "b#p", offsetMs: 120_000, durationMs: 600_000, next: nil)
        let planned = window.plannedRanges(refill: false)
        #expect(planned.map(\.range) == [1_200_000..<1_920_000], "two minutes in, 60 s × 10 kB × 1.2 ahead")

        file.write(Data(count: 720_000), at: 1_200_000)
        #expect(window.plannedRanges(refill: true).isEmpty, "full: quiet")
        window.update(key: "b#p", offsetMs: 130_000, durationMs: 600_000, next: nil)
        #expect(window.plannedRanges(refill: true).isEmpty, "10 s later: still more than three quarters")
        window.update(key: "b#p", offsetMs: 160_000, durationMs: 600_000, next: nil)
        #expect(window.plannedRanges(refill: true).map(\.range) == [1_920_000..<2_320_000], "40 s later: one burst to the new end")
    }

    @Test("near the end of a part, the start of the next is fetched too")
    func nextPartStart() {
        let window = StreamWindow(directory: directory())
        window.lookAheadSecs = 60
        window.file(for: "b#p1").setInfo(totalLength: 6_000_000, uti: AVFileType.mp3.rawValue)
        window.file(for: "b#p2").setInfo(totalLength: 1_000_000, uti: AVFileType.mp3.rawValue)
        // 30 s left of p1; p2 is 100 s of 1 MB.
        window.update(key: "b#p1", offsetMs: 570_000, durationMs: 600_000, next: (key: "b#p2", durationMs: 100_000))
        let planned = window.plannedRanges(refill: false)
        #expect(planned.first?.key == "b#p1" && planned.first?.range == 5_700_000..<6_000_000)
        #expect(planned.last?.key == "b#p2" && planned.last?.range == 0..<360_000, "the other 30 s, +20 %")
    }

    @Test("over the cap, the least recently played parts go; the one playing stays")
    func eviction() {
        let window = StreamWindow(directory: directory())
        for (index, key) in ["b#old", "b#mid", "b#now"].enumerated() {
            let file = window.file(for: key)
            file.setInfo(totalLength: 1_000_000, uti: AVFileType.mp3.rawValue)
            file.write(Data(repeating: 1, count: 200_000), at: 0)
            Thread.sleep(forTimeInterval: 0.01 * Double(index + 1))
            file.touch()
        }
        window.update(key: "b#now", offsetMs: 0, durationMs: 100_000, next: nil)
        let before = window.totalBytes()
        #expect(before >= 600_000)
        window.enforce(capBytes: before - 100_000, protecting: [])
        #expect(window.file(for: "b#old").storedBytes == 0, "the oldest went")
        #expect(window.file(for: "b#mid").storedBytes > 0 && window.file(for: "b#now").storedBytes > 0)
        window.enforce(capBytes: 0, protecting: ["b#mid"])
        #expect(window.file(for: "b#mid").storedBytes > 0, "protected")
        #expect(window.file(for: "b#now").storedBytes > 0, "playing")
    }
}
