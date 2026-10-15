import Foundation
import Testing

@testable import PlayerCore
@testable import PlayerCore

/// The store behind "continue this album where I left off": *which track* was current, and where.
@Suite("ResumeStore")
struct ResumeStoreTests {
    @Test("a container that has never been played has no resume point")
    func unknownContainerIsNil() {
        let store = InMemoryResumeStore()
        #expect(store.loadResume(containerId: "album:Queen/A Day at the Races") == nil)
    }

    @Test("saving then loading round-trips the track and its position")
    func roundTrips() throws {
        let store = InMemoryResumeStore()
        store.saveResume(containerId: "album:x", trackId: "t3", positionSecs: 91.5)

        let resume = try #require(store.loadResume(containerId: "album:x"))
        #expect(resume.trackId == "t3")
        #expect(resume.positionSecs == 91.5)
    }

    @Test("each container remembers its own place")
    func containersAreIndependent() throws {
        let store = InMemoryResumeStore()
        store.saveResume(containerId: "album:x", trackId: "t1", positionSecs: 10)
        store.saveResume(containerId: "playlist:y", trackId: "t9", positionSecs: 200)

        #expect(try #require(store.loadResume(containerId: "album:x")).trackId == "t1")
        #expect(try #require(store.loadResume(containerId: "playlist:y")).trackId == "t9")
    }

    @Test("a later save replaces the earlier one rather than accumulating")
    func saveOverwrites() throws {
        let store = InMemoryResumeStore()
        store.saveResume(containerId: "album:x", trackId: "t1", positionSecs: 10)
        store.saveResume(containerId: "album:x", trackId: "t2", positionSecs: 3)

        let resume = try #require(store.loadResume(containerId: "album:x"))
        #expect(resume.trackId == "t2")
        #expect(resume.positionSecs == 3)
    }

    /// What the engine does when a queue runs out: the next Play must start the album over, not
    /// resume onto the last second of its final track.
    @Test("clearing makes the container start from the beginning again")
    func clearResets() {
        let store = InMemoryResumeStore()
        store.saveResume(containerId: "album:x", trackId: "t8", positionSecs: 240)
        store.clearResume(containerId: "album:x")

        #expect(store.loadResume(containerId: "album:x") == nil)
    }
}
