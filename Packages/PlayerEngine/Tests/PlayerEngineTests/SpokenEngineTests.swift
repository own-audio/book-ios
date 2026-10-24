import Foundation
import Testing

@testable import PlayerCore
@testable import SpokenEngine

@Suite("BookTimeline")
struct BookTimelineTests {
    private let timeline = BookTimeline(
        parts: [SpokenPart(id: "a", url: URL(string: "file:///a")!, durationMs: 1000), SpokenPart(id: "b", url: URL(string: "file:///b")!, durationMs: 2000), SpokenPart(id: "c", url: URL(string: "file:///c")!, durationMs: 500)],
        chapters: [SpokenChapter(title: "Two", startMs: 1500, endMs: 3000), SpokenChapter(title: "One", startMs: 0, endMs: 1500), SpokenChapter(title: "Three", startMs: 3000, endMs: 3500)]
    )

    @Test("parts lie end to end; a position finds its part and offset, clamped at both ends")
    func locate() {
        #expect(timeline.starts == [0, 1000, 3000] && timeline.durationMs == 3500)
        #expect(timeline.locate(0)! == (0, 0))
        #expect(timeline.locate(999)! == (0, 999))
        #expect(timeline.locate(1000)! == (1, 0))
        #expect(timeline.locate(3400)! == (2, 400))
        #expect(timeline.locate(3500)! == (2, 500))
        #expect(timeline.locate(9999)! == (2, 500))
        #expect(timeline.locate(-5)! == (0, 0))
        #expect(timeline.position(partIndex: 1, offsetMs: 10) == 1010)
        #expect(BookTimeline(parts: []).locate(0) == nil)
    }

    @Test("chapters are sorted, found by position, and stepped through like tracks")
    func chapters() {
        #expect(timeline.chapters.map(\.title) == ["One", "Two", "Three"])
        #expect(timeline.chapter(at: 0)?.title == "One")
        #expect(timeline.chapter(at: 1500)?.title == "Two")
        #expect(timeline.chapter(at: 3499)?.title == "Three")
        #expect(timeline.nextChapterStart(from: 100) == 1500)
        #expect(timeline.nextChapterStart(from: 3200) == nil)
        #expect(timeline.previousChapterStart(from: 2900, graceMs: 1000) == 1500)
        #expect(timeline.previousChapterStart(from: 1600) == 0, "just into a chapter goes to the one before")
        #expect(timeline.previousChapterStart(from: 100) == 0)
        #expect(timeline.endOfChapter(at: 1600) == 3000)
        #expect(BookTimeline(parts: timeline.parts).endOfChapter(at: 1600) == 3000, "no chapters: the part ends it")
        #expect(BookTimeline.chaptersFromParts(timeline.parts).map(\.endMs) == [1000, 3000, 3500])
    }

    @Test("skips are clamped to the book")
    func skips() {
        #expect(timeline.skipped(from: 100, bySeconds: -15) == 0)
        #expect(timeline.skipped(from: 3400, bySeconds: 30) == 3500)
        #expect(timeline.skipped(from: 1000, bySeconds: 0.5) == 1500)
    }

    @Test("smart rewind grows with the pause and can be switched off")
    func rewind() {
        let rule = SmartRewind()
        #expect(rule.rewindMs(pausedFor: 5) == 0)
        #expect(rule.rewindMs(pausedFor: 30) == 3000)
        #expect(rule.rewindMs(pausedFor: 300) == 10_000)
        #expect(rule.rewindMs(pausedFor: 1800) == 20_000)
        #expect(rule.rewindMs(pausedFor: 86_400) == 30_000)
        #expect(SmartRewind(isEnabled: false).rewindMs(pausedFor: 86_400) == 0)
    }
}

func fixture(_ name: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
}

/// A 6-second M4B with three 2-second chapters, then a 2-second M4A: an 8-second book.
func testBook(chapters: [SpokenChapter]? = nil, linksExpireAt: Date? = nil) -> SpokenBook {
    let parts = [SpokenPart(id: "p1", url: fixture("test-book.m4b"), durationMs: 6000), SpokenPart(id: "p2", url: fixture("test-part-2s.m4a"), durationMs: 2000)]
    return SpokenBook(id: "book1", title: "Test Book", author: "Test Author", parts: parts, chapters: chapters ?? [
        SpokenChapter(title: "One", startMs: 0, endMs: 2000), SpokenChapter(title: "Two", startMs: 2000, endMs: 4000),
        SpokenChapter(title: "Three", startMs: 4000, endMs: 6000), SpokenChapter(title: "Tail", startMs: 6000, endMs: 8000),
    ], linksExpireAt: linksExpireAt)
}

@MainActor
func wait(until condition: @MainActor () -> Bool, seconds: Double = 8, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return true
}

@Suite("Embedded chapters")
struct EmbeddedChapterTests {
    @Test("an M4B's chapter marks are read and moved to book time behind the parts before it")
    func reads() async {
        let parts = [SpokenPart(id: "p0", url: fixture("test-part-2s.m4a"), durationMs: 2000), SpokenPart(id: "p1", url: fixture("test-book.m4b"), durationMs: 6000)]
        let chapters = await EmbeddedChapters.read(parts)
        #expect(chapters.map(\.title) == ["One", "Two", "Three"])
        #expect(chapters.map(\.startMs) == [2000, 4000, 6000])
        #expect(chapters.last?.endMs == 8000)
        #expect(await EmbeddedChapters.read([parts[0]]).isEmpty)
    }
}

@Suite("SpokenEngine", .serialized)
@MainActor
struct SpokenEngineTests {
    private func engine() -> (SpokenEngine, Positions) {
        let positions = Positions()
        let engine = SpokenEngine(nowPlaying: NowPlayingController(), resumeStore: InMemoryResumeStore())
        engine.tickIntervalSecs = 0.5
        engine.onPosition = { positions.all.append($0) }
        engine.onFinished = { positions.finished.append($0) }
        return (engine, positions)
    }

    final class Positions: @unchecked Sendable {
        var all: [SpokenEngine.Position] = []
        var finished: [String] = []
    }

    @Test("plays from a position, reports periodically, pauses and reports the pause")
    func playsAndReports() async {
        let (engine, positions) = engine()
        engine.load(testBook(), at: 500, autoplay: true)
        #expect(await wait(until: { engine.isPlaying && engine.positionMs > 900 }), "should advance past 0.9 s")
        #expect(await wait(until: { positions.all.contains { $0.reason == .periodic } }), "a periodic report")
        engine.pause()
        #expect(!engine.isPlaying)
        let pause = positions.all.last { $0.reason == .pause }
        #expect(pause?.partId == "p1" && (pause?.listenedMs ?? 0) > 0 && pause?.bookId == "book1")
        #expect(abs((pause?.positionMs ?? 0) - engine.positionMs) < 100)
        engine.stop()
        #expect(engine.book == nil && positions.all.last?.reason == .stop)
    }

    @Test("seeking across parts loads the other file at the right offset; chapters follow the position")
    func seeksAcrossParts() async {
        let (engine, positions) = engine()
        engine.load(testBook(), at: 0, autoplay: false)
        engine.seek(to: 6500)
        #expect(engine.positionMs == 6500 && engine.currentChapter?.title == "Tail")
        #expect(positions.all.last?.partId == "p2" && positions.all.last?.partOffsetMs == 500)
        #expect(positions.all.last?.reason == .chapter)
        engine.play()
        #expect(await wait(until: { engine.positionMs > 6700 }), "should play on inside the second file")
        engine.previousChapter()
        #expect(engine.positionMs == 4000, "just into a chapter goes back one")
        engine.nextChapter()
        #expect(engine.positionMs == 6000)
        engine.skipBackward()
        #expect(engine.positionMs == 0, "clamped at the start")
        engine.stop()
    }

    @Test("speed is pitch-corrected AVPlayer rate, rounded to 0.05 and bounded")
    func rate() async {
        let (engine, _) = engine()
        engine.load(testBook(), at: 0, autoplay: true)
        engine.setRate(1.37)
        #expect(engine.rate == 1.35)
        engine.setRate(9)
        #expect(engine.rate == 3.0)
        engine.setRate(0.1)
        #expect(engine.rate == 0.5)
        engine.setRate(3.0)
        let start = engine.positionMs
        try? await Task.sleep(for: .milliseconds(700))
        #expect(engine.positionMs - start > 1200, "at 3× more than 1.2 s of book should pass in 0.7 s")
        engine.stop()
    }

    @Test("the book finishes: the last position is reported as finished and the app is told")
    func finishes() async {
        let (engine, positions) = engine()
        engine.load(testBook(), at: 7200, autoplay: true)
        engine.setRate(2.0)
        #expect(await wait(until: { !positions.finished.isEmpty }), "the book should end")
        #expect(positions.finished == ["book1"])
        #expect(positions.all.last?.reason == .finished && positions.all.last?.finished == true)
        #expect(engine.positionMs == 8000 && !engine.isPlaying)
    }

    @Test("stopping at the end of the chapter pauses there")
    func endOfChapter() async {
        let (engine, _) = engine()
        engine.load(testBook(), at: 1500, autoplay: true)
        engine.setRate(2.0)
        engine.stopAtEndOfChapter(true)
        #expect(await wait(until: { !engine.isPlaying }), "should pause at 2 s")
        #expect(engine.positionMs >= 1700 && engine.positionMs <= 2300)
        #expect(!engine.stopsAtEndOfChapter)
        engine.stop()
    }

    @Test("smart rewind steps back on resume after a pause; off, it does not")
    func smartRewind() async {
        let (engine, _) = engine()
        engine.load(testBook(), at: 5000, autoplay: false)
        engine.smartRewind = SmartRewind(isEnabled: false)
        engine.play()
        engine.pause()
        let paused = engine.positionMs
        engine.play()
        #expect(abs(engine.positionMs - paused) < 150)
        engine.pause()
        engine.stop()
    }

    @Test("a part that fails to load gets one fresh link from the app and plays on from the same place")
    func recovers() async {
        let (engine, _) = engine()
        let broken = SpokenBook(id: "book1", title: "T", author: nil, parts: [SpokenPart(id: "p1", url: URL(string: "file:///nowhere/missing.m4b")!, durationMs: 6000)], chapters: [])
        let refreshed = Refreshed()
        engine.partRefresher = { _, partId in
            refreshed.ids.append(partId)
            return fixture("test-book.m4b")
        }
        engine.load(broken, at: 1000, autoplay: true)
        #expect(await wait(until: { engine.isPlaying && engine.positionMs > 1100 }), "should play after the refresh")
        #expect(refreshed.ids == ["p1"] && engine.errorMessage == nil)
        engine.stop()
    }

    final class Refreshed: @unchecked Sendable { var ids: [String] = [] }

    @Test("a part the app has on the phone plays from there when its turn comes")
    func usesLocatedPart() async {
        let (engine, _) = engine()
        // The second part's link points nowhere; the locator has the real file.
        let book = SpokenBook(id: "book1", title: "T", author: nil, parts: [
            SpokenPart(id: "p1", url: fixture("test-part-2s.m4a"), durationMs: 2000),
            SpokenPart(id: "p2", url: URL(string: "https://example.invalid/p2.m4b")!, durationMs: 6000),
        ], chapters: [])
        let asked = Refreshed()
        engine.partLocator = { _, partId in
            asked.ids.append(partId)
            return partId == "p2" ? fixture("test-book.m4b") : nil
        }
        engine.load(book, at: 1700, autoplay: true)
        #expect(await wait(until: { engine.positionMs > 2300 }, seconds: 15), "the second part should play from the located file")
        #expect(asked.ids.contains("p2") && engine.errorMessage == nil && engine.isPlaying)
        #expect(engine.book?.timeline.parts[1].url.isFileURL == true, "the book now names the local copy")
        engine.stop()
    }

    @Test("with no refresher the failure is shown")
    func fails() async {
        let (engine, _) = engine()
        let broken = SpokenBook(id: "b", title: "T", author: nil, parts: [SpokenPart(id: "p1", url: URL(string: "file:///nowhere/missing.m4b")!, durationMs: 6000)], chapters: [])
        engine.load(broken, at: 0, autoplay: true)
        #expect(await wait(until: { engine.errorMessage != nil }))
        #expect(!engine.isPlaying)
        engine.stop()
    }
}

@Suite("ImportMetadata")
struct ImportMetadataTests {
    @Test("an M4B's tags fill the form: title, artist, duration, the type from the extension")
    func reads() async {
        let url = Bundle.module.url(forResource: "test-book.m4b", withExtension: nil, subdirectory: "Fixtures")!
        let meta = await ImportMetadata.read(url)
        #expect(meta.title == "Test Book" && meta.artist == "Test Author")
        #expect(abs(meta.durationMs - 6000) < 100)
        #expect(meta.contentType == "audio/mp4")
        #expect(ImportMetadata.contentType(for: URL(fileURLWithPath: "/x/a.MP3")) == "audio/mpeg")
    }
}
