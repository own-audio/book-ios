import BookLibrary
import Foundation
import SpokenEngine
import Testing
@testable import OwnAudioBooks

/// O1: every file plays from the phone when it is there — the listener's download, then the
/// listening cache, then the stream — per file, so a partly downloaded book uses what it has.
@MainActor
@Suite("Part locator")
struct PartLocatorTests {
    private let book = "S|book"
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/phone/\(name)") }
    private func stream(_ id: String, hls: Bool = false) -> PlayPlan.Part {
        PlayPlan.Part(fileId: id, url: URL(string: "https://server.example/\(id)")!, startMs: 0, durationMs: 1000, contentType: "audio/mp4", isHLS: hls)
    }

    private func locator(downloaded: Set<String>, cached: Set<String>) -> PartLocator {
        let downloadedURLs = Dictionary(uniqueKeysWithValues: downloaded.map { ($0, url("download-\($0)")) })
        let cachedURLs = Dictionary(uniqueKeysWithValues: cached.map { ($0, url("cache-\($0)")) })
        return PartLocator(downloaded: { _, id in downloadedURLs[id] }, cached: { _, id in cachedURLs[id] })
    }

    @Test("the download wins over the listening cache, which wins over the stream")
    func order() async {
        let locator = locator(downloaded: ["a"], cached: ["a", "b"])
        #expect(await locator.locate(compositeId: book, fileId: "a") == .downloaded(url("download-a")))
        #expect(await locator.locate(compositeId: book, fileId: "b") == .cached(url("cache-b")))
        #expect(await locator.locate(compositeId: book, fileId: "c") == .stream)
    }

    @Test("a partly downloaded book plays its downloaded files from the phone and streams the rest")
    func partlyDownloaded() async {
        let locator = locator(downloaded: ["f2"], cached: ["f3"])
        let parts = await locator.parts(compositeId: book, files: [], streams: [stream("f1"), stream("f2"), stream("f3")])
        #expect(parts.map(\.id) == ["f1", "f2", "f3"])
        #expect(parts[0].url.absoluteString == "https://server.example/f1")
        #expect(parts[1].url == url("download-f2"))
        #expect(parts[2].url == url("cache-f3"))
    }

    @Test("an HLS transcode is never swapped for a file on the phone")
    func hlsStays() async {
        let parts = await locator(downloaded: ["all"], cached: []).parts(compositeId: book, files: [], streams: [stream("all", hls: true)])
        #expect(parts[0].isHLS && !parts[0].url.isFileURL)
    }

    @Test("offline, a partly downloaded book has its files on the phone and the others unresolved")
    func offline() async {
        let parts = await locator(downloaded: ["f1"], cached: ["f3"]).parts(
            compositeId: book, files: [("f1", 1000), ("f2", 2000), ("f3", 3000)], streams: nil
        )
        #expect(parts[0].url == url("download-f1") && parts[2].url == url("cache-f3"))
        #expect(parts[1].isUnresolved && parts[1].durationMs == 2000)
    }

    @Test("the missing part's message, in words for the listener")
    func message() {
        #expect(PartNotOnPhone().errorDescription?.isEmpty == false)
    }

    @Test("a download finishing mid-book reaches the book playing, and only that book")
    func downloadMidBook() async {
        let model = AppModel.shared
        let composite = BookID.make(serverId: UUID(), bookId: "mid-book")
        let spoken = SpokenBook(id: composite, title: "T", author: nil, parts: [
            SpokenPart(id: "f1", url: URL(string: "https://server.example/f1")!, durationMs: 1000, isHLS: true),
            SpokenPart(id: "f2", url: URL(string: "https://server.example/f2")!, durationMs: 1000, isHLS: true),
        ], chapters: [])
        model.engine.load(spoken, at: 0, autoplay: false)
        defer { model.engine.stop(reporting: false) }
        model.downloads.onFileReady?("another|book", "f2", url("other"))
        #expect(model.engine.book?.timeline.parts[1].url.isFileURL == false)
        model.downloads.onFileReady?(composite, "f2", url("download-f2"))
        #expect(model.engine.book?.timeline.parts[1].url == url("download-f2"))
    }
}
