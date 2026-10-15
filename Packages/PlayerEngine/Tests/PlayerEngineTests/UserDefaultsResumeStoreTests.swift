import Foundation
import Testing

@testable import PlayerCore
@testable import PlayerCore

/// The concrete, `UserDefaults`-backed store — `ResumeStoreTests` already covers the
/// contract against the in-memory double; this covers the one thing that's specific to this
/// implementation: it actually persists, and two stores with different keys don't collide.
@Suite("UserDefaultsResumeStore")
struct UserDefaultsResumeStoreTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "UserDefaultsResumeStoreTests-\(UUID().uuidString)")!
    }

    @Test("round-trips through a fresh store instance reading the same defaults and key")
    func persistsAcrossInstances() throws {
        let defaults = freshDefaults()
        UserDefaultsResumeStore(defaults: defaults, key: "test.resume")
            .saveResume(containerId: "album:x", trackId: "t3", positionSecs: 91.5)

        let reopened = UserDefaultsResumeStore(defaults: defaults, key: "test.resume")
        let resume = try #require(reopened.loadResume(containerId: "album:x"))
        #expect(resume.trackId == "t3")
        #expect(resume.positionSecs == 91.5)
    }

    @Test("two stores with different keys in the same UserDefaults never see each other's data")
    func keysAreIsolated() {
        let defaults = freshDefaults()
        let firstStore = UserDefaultsResumeStore(defaults: defaults, key: "first.resume")
        let secondStore = UserDefaultsResumeStore(defaults: defaults, key: "second.resume")

        firstStore.saveResume(containerId: "album:x", trackId: "first-track", positionSecs: 10)

        #expect(secondStore.loadResume(containerId: "album:x") == nil)
        #expect(firstStore.loadResume(containerId: "album:x")?.trackId == "first-track")
    }

    @Test("the default key is stable, so an update doesn't lose resume points")
    func defaultKeyIsUnchanged() {
        let defaults = freshDefaults()
        UserDefaultsResumeStore(defaults: defaults).saveResume(containerId: "album:y", trackId: "t1", positionSecs: 5)

        #expect(defaults.data(forKey: "player.resume") != nil)
    }
}
