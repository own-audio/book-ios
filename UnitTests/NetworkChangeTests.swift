import Foundation
import Testing
@testable import OwnAudioBooks

/// Network changes are settled before anything is done about them, and in the background only
/// positions are sent.
@MainActor
@Suite("Network changes")
struct NetworkChangeTests {
    @Test("the same interfaces in another order are the same network")
    func reorderIsNoChange() {
        let a = NetworkMonitor.signature(connected: true, interfaces: ["wifi-en0", "cellular-pdp_ip0", "other-utun3"])
        let b = NetworkMonitor.signature(connected: true, interfaces: ["cellular-pdp_ip0", "other-utun3", "wifi-en0"])
        #expect(a == b)
    }

    @Test("another interface, one fewer, or no connection is a change")
    func realChanges() {
        let wifi = NetworkMonitor.signature(connected: true, interfaces: ["wifi-en0"])
        #expect(wifi != NetworkMonitor.signature(connected: true, interfaces: ["wifi-en0", "other-utun3"]), "a VPN came up")
        #expect(wifi != NetworkMonitor.signature(connected: true, interfaces: ["cellular-pdp_ip0"]))
        #expect(wifi != NetworkMonitor.signature(connected: false, interfaces: ["wifi-en0"]))
    }

    @Test("in front: addresses and positions; in the background: positions only")
    func work() {
        #expect(NetworkChangeWork.after(inForeground: true) == NetworkChangeWork(chooseAddresses: true, flushProgress: true))
        #expect(NetworkChangeWork.after(inForeground: false) == NetworkChangeWork(chooseAddresses: false, flushProgress: true))
    }

    @Test("a burst of changes runs the work once, after the last")
    func debounce() async throws {
        let debouncer = Debouncer(delay: .milliseconds(200))
        var runs: [Int] = []
        for n in 1...5 {
            debouncer.schedule { runs.append(n) }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(runs.isEmpty, "nothing while the changes keep coming")
        try await Task.sleep(for: .milliseconds(600))
        #expect(runs == [5])
    }

    @Test("changes far apart each run")
    func separateChanges() async throws {
        let debouncer = Debouncer(delay: .milliseconds(50))
        var runs = 0
        debouncer.schedule { runs += 1 }
        try await Task.sleep(for: .milliseconds(300))
        debouncer.schedule { runs += 1 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(runs == 2)
    }
}
