import Foundation
import Testing

@testable import BookLibrary

/// Both adapters against real servers, through the same `BookSource` interface; skipped unless
/// the environment names a server (see `scripts/test-servers.sh` for the variables). The
/// Audiobookshelf user should be a throwaway: the tests play and write progress.
private let device = DeviceIdentity(id: "book-library-live-tests", name: "Live tests", model: "iPhone", appVersion: "0.1.0", systemVersion: "18.0")

private func exercise(_ source: any BookSource) async throws {
    #expect(await source.checkConnection() == .ok)

    let shelves = try await source.shelves()
    #expect(shelves.allSatisfy { !$0.isEmpty })
    let page = try await source.books(BookQuery(sort: .duration), cursor: nil, limit: 3)
    #expect(!page.books.isEmpty)
    let shortest = page.books[0]
    let book = try await source.book(id: shortest.id)
    let files = try #require(book.files)
    #expect(!files.isEmpty && files.last!.endMs > 0)
    #expect(abs(files.last!.endMs - book.durationMs) <= 2000)
    if let chapters = book.chapters, !chapters.isEmpty {
        #expect(chapters.first!.startMs == 0 && chapters.last!.endMs <= book.durationMs + 1000)
    }
    _ = try await source.authors()
    _ = try await source.narrators()
    if source.capabilities.contains(.series) {
        let series = try await source.series()
        if let first = series.first { #expect(try await source.series(id: first.id).books?.isEmpty == false) }
    }
    if source.capabilities.contains(.collections) { _ = try await source.collections() }
    let found = try await source.search(String(book.title.prefix(4)))
    #expect(found.books.contains { $0.id == book.id })
    let byTitle = try await source.books(BookQuery(text: String(book.title.prefix(4))), cursor: nil, limit: 10)
    #expect(byTitle.books.contains { $0.id == book.id })

    // ListeningProgress: written, read back, counted in progress, cleared.
    let saved = try await source.saveProgress(bookId: book.id, positionMs: 42_500, durationMs: book.durationMs, finished: false, at: Date())
    #expect(saved.positionMs == 42_500)
    let read = try #require(try await source.progress(bookId: book.id))
    #expect(abs(read.positionMs - 42_500) < 1000 && !read.finished)
    #expect(try await source.allProgress()[book.id] != nil)
    #expect(try await source.books(BookQuery(filter: .inProgress), cursor: nil, limit: 100).books.contains { $0.id == book.id })
    if source.capabilities.contains(.perDevicePositions) {
        #expect(read.devices.contains { $0.isThisDevice })
    }

    // Bookmarks: added, renamed, listed, deleted.
    let bookmark = try await source.addBookmark(bookId: book.id, positionMs: 33_000, label: "live test")
    #expect(bookmark.positionMs == 33_000 && bookmark.label == "live test")
    let renamed = try await source.renameBookmark(bookmark, label: "renamed")
    #expect(renamed.label == "renamed")
    #expect(try await source.bookmarks(bookId: book.id).contains { $0.positionMs == 33_000 })
    try await source.deleteBookmark(renamed)
    #expect(try await source.bookmarks(bookId: book.id).contains { $0.positionMs == 33_000 } == false)

    if source.capabilities.contains(.favourites) {
        try await source.setFavourite(bookId: book.id, true)
        #expect(try await source.favourites().contains(book.id))
        try await source.setFavourite(bookId: book.id, false)
        #expect(try await source.favourites().contains(book.id) == false)
    }

    // A plan: one part per file, the first one answers a range request.
    let plan = try await source.playPlan(for: book, maxBitrateKbps: nil)
    #expect(plan.parts.count == files.count)
    #expect(plan.parts.map(\.startMs) == files.map(\.startMs))
    var ranged = URLRequest(url: plan.parts[0].url)
    ranged.setValue("bytes=0-99", forHTTPHeaderField: "Range")
    let (chunk, response) = try await URLSession.shared.data(for: ranged)
    #expect((response as? HTTPURLResponse)?.statusCode == 206 && chunk.count == 100)
    let afterReport = try await source.report(PlaybackReport(bookId: book.id, sessionId: plan.sessionId, positionMs: 50_000, listenedMs: 7_500, durationMs: book.durationMs, finished: false))
    #expect(afterReport?.positionMs == 50_000)
    _ = try await source.report(PlaybackReport(bookId: book.id, sessionId: plan.sessionId, positionMs: 51_000, listenedMs: 1_000, durationMs: book.durationMs, finished: false, closes: true))
    #expect(abs(((try await source.progress(bookId: book.id))?.positionMs ?? 0) - 51_000) < 1000)
    let again = try await source.partURL(for: book, fileId: files[0].id, startMs: nil, maxBitrateKbps: nil)
    #expect(again.fileId == files[0].id)

    // A smaller stream where the server makes one.
    if source.capabilities.contains(.lowerBitrate) {
        let small = try await source.playPlan(for: book, maxBitrateKbps: 64)
        #expect(!small.parts.isEmpty)
        if small.parts[0].isHLS {
            try await Task.sleep(for: .seconds(3))
            let (data, response) = try await URLSession.shared.data(from: small.parts[0].url)
            #expect((response as? HTTPURLResponse)?.statusCode == 200 && String(decoding: data.prefix(7), as: UTF8.self) == "#EXTM3U")
        }
        if let session = small.sessionId {
            _ = try await source.report(PlaybackReport(bookId: book.id, sessionId: session, positionMs: 51_000, listenedMs: 0, durationMs: book.durationMs, finished: false, closes: true))
        }
    }

    try await source.clearProgress(bookId: book.id)
    #expect(try await source.progress(bookId: book.id) == nil)
    await source.signOut()
}

@Suite("Audiobookshelf source, live", .serialized, .enabled(if: ProcessInfo.processInfo.environment["AUDIOBOOKSHELF_HOST"] != nil))
struct AudiobookshelfSourceLiveTests {
    @Test("sign in, browse, progress, bookmarks, play, report")
    func everything() async throws {
        let env = ProcessInfo.processInfo.environment
        let host = try #require(URL(string: env["AUDIOBOOKSHELF_HOST"]!))
        let signIn = try await ServerSetup.audiobookshelfSignIn(host: host, username: env["AUDIOBOOKSHELF_USERNAME"]!, password: env["AUDIOBOOKSHELF_PASSWORD"]!, urlSession: .shared)
        #expect(!signIn.libraries.isEmpty && signIn.record.libraryId != nil)
        let environment = SourceEnvironment(urlSession: .shared, cache: nil, offline: nil, device: device)
        try await exercise(signIn.record.makeSource(environment))
    }

    @Test("a wrong password is refused, a wrong address is not Audiobookshelf")
    func refusals() async throws {
        let env = ProcessInfo.processInfo.environment
        let host = try #require(URL(string: env["AUDIOBOOKSHELF_HOST"]!))
        await #expect(throws: SourceError.signInRejected) {
            _ = try await ServerSetup.audiobookshelfSignIn(host: host, username: env["AUDIOBOOKSHELF_USERNAME"]!, password: "wrong-" + env["AUDIOBOOKSHELF_PASSWORD"]!, urlSession: .shared)
        }
        await #expect(throws: SourceError.self) {
            _ = try await ServerSetup.audiobookshelfSignIn(host: URL(string: "https://www.example.com")!, username: "a", password: "b", urlSession: .shared)
        }
    }
}

@Suite("own.audio source, live", .serialized, .enabled(if: ProcessInfo.processInfo.environment["OWNAUDIO_HOST"] != nil))
struct OwnAudioSourceLiveTests {
    private func session() -> URLSession {
        // The hosted service's edge refuses requests with no User-Agent.
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": "own.audio Books tests"]
        return URLSession(configuration: config)
    }

    @Test("sign in, sync the catalogue, browse, progress, bookmarks, favourites, play, report")
    func everything() async throws {
        let env = ProcessInfo.processInfo.environment
        let host = try #require(URL(string: env["OWNAUDIO_HOST"]!))
        let urlSession = session()
        let result = try await ServerSetup.ownAudioSignIn(host: host, email: env["OWNAUDIO_EMAIL"]!, password: env["OWNAUDIO_ACCOUNT_PASSWORD"]!, device: device, urlSession: urlSession)
        guard case .signedIn(let record) = result else { Issue.record("two-factor on the test account"); return }
        #expect(record.userId != nil && record.serverId != nil)
        let environment = SourceEnvironment(urlSession: urlSession, cache: nil, offline: nil, device: device)
        let source = record.makeSource(environment)
        let feed = try #require(source as? any ChangeFeedCatalogue)
        let first = try await feed.syncCatalogue(nil)
        #expect(!first.books.isEmpty && !first.authors.isEmpty)
        let second = try await feed.syncCatalogue(first.state)
        #expect(second.books.count == first.books.count)
        let own = try #require(source as? OwnAudioSource)
        let sessions = try await own.sessions()
        #expect(sessions.contains { $0.isThisDevice }, "this device should be among the sessions")
        try await exercise(source)
    }

    @Test("a wrong password is refused")
    func refusal() async throws {
        let env = ProcessInfo.processInfo.environment
        let host = try #require(URL(string: env["OWNAUDIO_HOST"]!))
        await #expect(throws: SourceError.signInRejected) {
            _ = try await ServerSetup.ownAudioSignIn(host: host, email: env["OWNAUDIO_EMAIL"]!, password: "wrong", device: device, urlSession: session())
        }
    }

    @Test("a one-second file from the phone becomes a book with one file")
    func importsABook() async throws {
        let env = ProcessInfo.processInfo.environment
        let host = try #require(URL(string: env["OWNAUDIO_HOST"]!))
        let urlSession = session()
        let result = try await ServerSetup.ownAudioSignIn(host: host, email: env["OWNAUDIO_EMAIL"]!, password: env["OWNAUDIO_ACCOUNT_PASSWORD"]!, device: device, urlSession: urlSession)
        guard case .signedIn(let record) = result else { Issue.record("two-factor on the test account"); return }
        let uploader = try #require(record.makeSource(SourceEnvironment(urlSession: urlSession, cache: nil, offline: nil, device: device)) as? any BookUploader)
        // A second of silence as a WAV: 8 kHz, 8-bit, mono.
        var wav = Data("RIFF".utf8)
        let samples = 8000
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        wav.append(le32(UInt32(36 + samples)))
        wav.append(Data("WAVEfmt ".utf8))
        wav.append(le32(16))
        wav.append(le16(1))
        wav.append(le16(1))
        wav.append(le32(8000))
        wav.append(le32(8000))
        wav.append(le16(1))
        wav.append(le16(8))
        wav.append(Data("data".utf8))
        wav.append(le32(UInt32(samples)))
        wav.append(Data(repeating: 128, count: samples))
        let target = try await uploader.uploadTarget(kind: "audio", fileName: "silence.wav", contentType: "audio/wav", sizeBytes: Int64(wav.count))
        var put = URLRequest(url: target.url)
        put.httpMethod = target.method
        for (key, value) in target.headers { put.setValue(value, forHTTPHeaderField: key) }
        let (_, response) = try await urlSession.upload(for: put, from: wav)
        #expect((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0), "the storage should take the file")
        let importId = "live-" + UUID().uuidString
        let book = try await uploader.createBook(title: "own.audio Books live test", authors: ["Test Author"], narrators: ["Test Narrator"], description: nil, visibility: .private, coverUploadId: nil, files: [ImportedFile(uploadId: target.uploadId, fileName: "silence.wav", title: "Silence")], importId: importId)
        #expect(book.title == "own.audio Books live test")
        #expect(book.authors.map(\.name) == ["Test Author"] && book.narrators.map(\.name) == ["Test Narrator"])
        #expect(book.files?.count == 1)
        // The same import again answers the same book.
        let again = try await uploader.createBook(title: "own.audio Books live test", authors: ["Test Author"], narrators: ["Test Narrator"], description: nil, visibility: .private, coverUploadId: nil, files: [ImportedFile(uploadId: target.uploadId, fileName: "silence.wav", title: "Silence")], importId: importId)
        #expect(again.id == book.id)
        await uploader.signOut()
    }

    @Test("a position saved by another device shows up with that device's name, and the resume rule asks")
    func otherDevice() async throws {
        let env = ProcessInfo.processInfo.environment
        let host = try #require(URL(string: env["OWNAUDIO_HOST"]!))
        let urlSession = session()
        func signIn(_ name: String) async throws -> any BookSource {
            let identity = DeviceIdentity(id: name, name: name, model: "iPhone", appVersion: "0.1.0", systemVersion: "18.0")
            let result = try await ServerSetup.ownAudioSignIn(host: host, email: env["OWNAUDIO_EMAIL"]!, password: env["OWNAUDIO_ACCOUNT_PASSWORD"]!, device: identity, urlSession: urlSession)
            guard case .signedIn(let record) = result else { throw SourceError.signInRejected }
            return record.makeSource(SourceEnvironment(urlSession: urlSession, cache: nil, offline: nil, device: identity))
        }
        let phone = try await signIn("Live test phone")
        let car = try await signIn("Live test car")
        let book = try #require(try await phone.books(BookQuery(sort: .duration), cursor: nil, limit: 1).books.first)
        let t0 = Date()
        _ = try await phone.saveProgress(bookId: book.id, positionMs: 100_000, durationMs: book.durationMs, finished: false, at: t0)
        try await Task.sleep(for: .seconds(1))
        _ = try await car.saveProgress(bookId: book.id, positionMs: 400_000, durationMs: book.durationMs, finished: false, at: Date())
        let seen = try #require(try await phone.progress(bookId: book.id))
        #expect(seen.positionMs == 400_000)
        #expect(seen.devices.contains { !$0.isThisDevice && $0.name == "Live test car" && $0.positionMs == 400_000 })
        let local = ListeningProgress(positionMs: 100_000, finished: false, updatedAt: t0)
        #expect(ResumeChoice.decide(local: local, server: seen) == .ask(localMs: 100_000, otherMs: 400_000, otherDevice: "Live test car"))
        try await phone.clearProgress(bookId: book.id)
        await car.signOut()
        await phone.signOut()
    }
}
