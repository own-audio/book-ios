import Foundation
import Testing

@testable import BookLibrary

@Suite("ResumeChoice")
struct ResumeChoiceTests {
    private let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    private func progress(_ ms: Int64, at: Date, finished: Bool = false, devices: [DevicePosition] = []) -> ListeningProgress {
        ListeningProgress(positionMs: ms, finished: finished, updatedAt: at, devices: devices)
    }

    private func device(_ name: String, _ ms: Int64, at: Date, thisDevice: Bool = false) -> DevicePosition {
        DevicePosition(id: name, name: name, kind: "ios", positionMs: ms, finished: false, at: at, isThisDevice: thisDevice)
    }

    @Test("nothing known: the server's position, or the start")
    func simple() {
        #expect(ResumeChoice.decide(local: nil, server: nil) == .start(positionMs: 0))
        #expect(ResumeChoice.decide(local: nil, server: progress(5000, at: t0)) == .start(positionMs: 5000))
        #expect(ResumeChoice.decide(local: progress(9000, at: t0), server: nil) == .start(positionMs: 9000))
        #expect(ResumeChoice.decide(local: progress(9000, at: t0), server: progress(90_000, at: t0, finished: true)) == .start(positionMs: 0))
    }

    @Test("the same place within the tolerance: the server's")
    func same() {
        #expect(ResumeChoice.decide(local: progress(100_000, at: t0), server: progress(110_000, at: t0.addingTimeInterval(60))) == .start(positionMs: 110_000))
    }

    @Test("another device went further since this phone saved: ask, naming it")
    func otherDeviceAhead() {
        let server = progress(400_000, at: t0.addingTimeInterval(3600), devices: [
            device("iPhone", 100_000, at: t0, thisDevice: true),
            device("Car", 400_000, at: t0.addingTimeInterval(3600)),
        ])
        #expect(ResumeChoice.decide(local: progress(100_000, at: t0), server: server) == .ask(localMs: 100_000, otherMs: 400_000, otherDevice: "Car"))
    }

    @Test("the server differs but it is this phone's own older report, or a server without devices: the newer wins")
    func noOtherDevice() {
        let onlyMine = progress(400_000, at: t0, devices: [device("iPhone", 400_000, at: t0, thisDevice: true)])
        #expect(ResumeChoice.decide(local: progress(100_000, at: t0.addingTimeInterval(60)), server: onlyMine) == .start(positionMs: 100_000))
        #expect(ResumeChoice.decide(local: progress(100_000, at: t0), server: progress(400_000, at: t0.addingTimeInterval(60))) == .start(positionMs: 400_000))
    }
}
