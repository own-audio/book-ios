import BookLibrary
import Foundation
import Testing
@testable import OwnAudioBooks

/// The smaller battery items: narration polling backs off and stops, download progress is
/// throttled before it reaches the main thread.
@MainActor
@Suite("Background work")
struct BatteryTests {
    @Test("narration polling: 4 s after a change, doubling to a minute while nothing moves")
    func narrationBackoff() {
        var delay = NarrationManager.firstDelay
        var seen: [Duration] = []
        for _ in 0..<6 {
            delay = NarrationManager.nextDelay(after: delay, changed: false)
            seen.append(delay)
        }
        #expect(seen == [.seconds(8), .seconds(16), .seconds(32), .seconds(60), .seconds(60), .seconds(60)])
        #expect(NarrationManager.nextDelay(after: .seconds(60), changed: true) == .seconds(4))
    }

    @Test("narration polling stops when the job's server is gone")
    func narrationStopsWithoutServer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("narration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = NarrationManager(directory: directory)
        manager.narratorProvider = { _ in nil }
        let job = NarrationJob(id: "j1", title: "A text", stages: ["translate", "speak"], stage: "speak", error: nil, chapters: [], bookId: nil, quotedPriceCents: 100, chargedPriceCents: nil, currency: "EUR")
        manager.add(job, serverId: UUID())
        #expect(manager.hasRunning)
        for _ in 0..<50 where manager.isPolling { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!manager.isPolling, "nobody to ask: no loop left running")
        #expect(manager.hasRunning, "the job is kept for when its server is back")
    }

    @Test("download progress: at most twice a second per file, and always the last")
    func downloadProgressThrottle() {
        let throttle = ProgressThrottle(interval: 0.5)
        let start = Date(timeIntervalSince1970: 0)
        var passed = 0
        for tick in 0..<100 {
            if throttle.shouldPass("f1", now: start.addingTimeInterval(Double(tick) * 0.02)) { passed += 1 }
        }
        #expect(passed == 4, "two seconds of callbacks every 20 ms")
        #expect(throttle.shouldPass("f2", now: start.addingTimeInterval(0.1)), "another file has its own pace")
        #expect(throttle.shouldPass("f1", done: true, now: start.addingTimeInterval(1.99)), "the end always passes")
    }
}
