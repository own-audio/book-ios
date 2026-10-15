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
            // Interface names carry the VPN (utun…) as well as Wi-Fi and cellular.
            let signature = ([connected ? "up" : "down"] + path.availableInterfaces.map { "\($0.type)-\($0.name)" })
                .joined(separator: ",")
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
}
