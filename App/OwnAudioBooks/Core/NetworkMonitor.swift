import Network
import Observation

/// The phone's network path: whether there is one, whether it costs (mobile data, a hotspot),
/// whether iOS Low Data Mode is on, and a signature that changes whenever the path does —
/// Wi-Fi to mobile data, a VPN coming up — which is when the best address to a server can
/// change. It can't tell a Wi-Fi with no internet from a working one; short request timeouts
/// and the saved answers cover that case.
@Observable
@MainActor
final class NetworkMonitor {
    private(set) var isConnected = true
    /// Mobile data or a phone's hotspot: the system's own idea of a connection that costs.
    private(set) var isExpensive = false
    /// iOS Low Data Mode, the listener's phone-wide choice.
    private(set) var isConstrained = false
    /// Changes with every change of path; used to remember which address worked where.
    private(set) var signature = ""
    @ObservationIgnored var onChange: ((Bool) -> Void)?
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            let signature = Self.signature(connected: connected, interfaces: path.availableInterfaces.map { "\($0.type)-\($0.name)" })
            Task { @MainActor in
                guard let self, self.signature != signature || self.isExpensive != expensive || self.isConstrained != constrained else { return }
                self.isConnected = connected
                self.isExpensive = expensive
                self.isConstrained = constrained
                self.signature = signature
                self.onChange?(connected)
            }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }

    /// Interface names carry the VPN (utun…) as well as Wi-Fi and cellular. Sorted: iOS reorders
    /// the same interfaces as it prefers one or the other, which is no new network.
    nonisolated static func signature(connected: Bool, interfaces: [String]) -> String {
        ([connected ? "up" : "down"] + interfaces.sorted()).joined(separator: ",")
    }
}

/// What a settled network change sets off. In front: the best address to each server is chosen
/// again, then queued positions are sent. In the background (a car's handovers between cells
/// while a book plays), only the positions: racing every address can wait until the app is
/// opened.
struct NetworkChangeWork: Equatable {
    var chooseAddresses: Bool
    var flushProgress: Bool

    static func after(inForeground: Bool) -> NetworkChangeWork {
        NetworkChangeWork(chooseAddresses: inForeground, flushProgress: true)
    }
}

/// Runs the last of a burst of calls once things have been quiet for `delay`: a network change
/// often comes as several path updates within a second or two.
@MainActor
final class Debouncer {
    private let delay: Duration
    private var task: Task<Void, Never>?

    init(delay: Duration) {
        self.delay = delay
    }

    func schedule(_ work: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await work()
        }
    }
}
