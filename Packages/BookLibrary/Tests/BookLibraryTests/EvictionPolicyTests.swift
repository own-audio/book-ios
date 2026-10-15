import Foundation
import Testing

@testable import BookLibrary

@Suite("EvictionPolicy")
struct EvictionPolicyTests {
    private let day: TimeInterval = 86_400
    private var now: Date { Date(timeIntervalSince1970: 1_792_000_000) }

    private var candidates: [EvictionPolicy.Candidate] {
        [
            .init(id: "playing", bytes: 400, isFinished: false, lastUsedAt: now),
            .init(id: "old", bytes: 300, isFinished: false, lastUsedAt: now.addingTimeInterval(-30 * day)),
            .init(id: "finished", bytes: 200, isFinished: true, lastUsedAt: now.addingTimeInterval(-1 * day)),
            .init(id: "recent", bytes: 100, isFinished: false, lastUsedAt: now.addingTimeInterval(-2 * day)),
        ]
    }

    @Test("no cap, nothing goes; under the cap, nothing goes")
    func nothing() {
        #expect(EvictionPolicy(capBytes: nil).evictions(from: candidates, protected: nil).isEmpty)
        #expect(EvictionPolicy(capBytes: 1000).evictions(from: candidates, protected: nil).isEmpty)
    }

    @Test("finished books go first, then the longest unplayed, until it fits; the playing book never")
    func order() {
        #expect(EvictionPolicy(capBytes: 900).evictions(from: candidates, protected: "playing") == ["finished"])
        #expect(EvictionPolicy(capBytes: 500).evictions(from: candidates, protected: "playing") == ["finished", "old"])
        #expect(EvictionPolicy(capBytes: 50).evictions(from: candidates, protected: "playing") == ["finished", "old", "recent"])
        #expect(EvictionPolicy(capBytes: 50).evictions(from: candidates, protected: nil) == ["finished", "old", "recent", "playing"])
    }
}
