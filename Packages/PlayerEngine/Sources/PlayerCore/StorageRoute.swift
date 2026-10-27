import Foundation

/// The way to an own.audio file when the network blocks cloud storage.
///
/// An own.audio server hands out a signed stream link (`…/api/v2/stream?…&s=…`) that answers
/// with a redirect to the file in cloud storage, on the storage's own host. Some networks — a
/// company firewall, mostly — block that host while the server's own host works: the name does
/// not resolve, the connection is refused or reset, TLS fails, or a proxy in between answers
/// 403. The same link with `route=proxy` added redirects to the server's media proxy on its own
/// domain instead. The parameter is not part of the signature, and a server without a proxy
/// ignores it, so adding it is always safe — but only on that link: no other server's address
/// is ever changed.
///
/// Copied as is between the own.audio apps (Books, Podcasts, Music).
public enum StorageRoute {
    static let parameter = "route"
    static let proxyValue = "proxy"

    /// Errors that mean "that host can't be reached from here". Not `notConnectedToInternet`:
    /// no network at all is a gap in the signal, waited out elsewhere.
    static let blockingErrors: Set<URLError.Code> = [
        .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .networkConnectionLost, .timedOut,
        .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
        .clientCertificateRequired,
    ]
    /// What a filtering proxy answers in place of the file.
    static let blockingStatuses: Set<Int> = [403, 407, 451]

    /// An own.audio stream link: the only kind of address that takes `route=proxy`.
    public static func takesProxyRoute(_ url: URL) -> Bool {
        guard !url.isFileURL, url.path.hasSuffix("/api/v2/stream"),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems else { return false }
        return items.contains { $0.name == "s" }
    }

    public static func isProxied(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems ?? []
        return items.contains { $0.name == parameter && $0.value == proxyValue }
    }

    /// The link through the media proxy. The signed parameters are kept byte for byte.
    public static func proxied(_ url: URL) -> URL {
        guard takesProxyRoute(url), !isProxied(url) else { return url }
        return withRoute(url, proxyValue)
    }

    /// The link as the server gave it: straight to storage.
    public static func direct(_ url: URL) -> URL {
        withRoute(url, nil)
    }

    /// The other way to fetch `url`, for when the way tried was blocked; nil for an address
    /// that is not an own.audio stream link.
    public static func alternate(to url: URL) -> URL? {
        guard takesProxyRoute(url) else { return nil }
        return isProxied(url) ? direct(url) : proxied(url)
    }

    /// A request for `link` failed: blocked when the failure was at another host than the
    /// link's own (the storage the server redirected to). A failure at the server itself is
    /// the server being unreachable, not storage being blocked. `current` is where the request
    /// was when it failed, for an error that does not say (a background download's task).
    public static func isBlocked(error: Error, link: URL, current: URL? = nil) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain, blockingErrors.contains(URLError.Code(rawValue: ns.code)) else { return false }
        let failing = (error as? URLError)?.failingURL ?? (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? current
        guard let failing else { return false }
        return !sameHost(failing, link)
    }

    /// An answer to a request for `link`: blocked when a host other than the link's own refused
    /// it. A 403 from the server itself is an expired link (`invalid_link`), renewed elsewhere.
    public static func isBlocked(response: URLResponse, link: URL) -> Bool {
        guard let http = response as? HTTPURLResponse, blockingStatuses.contains(http.statusCode), let url = http.url else { return false }
        return !sameHost(url, link)
    }

    static func sameHost(_ a: URL, _ b: URL) -> Bool {
        a.host?.lowercased() == b.host?.lowercased() && port(a) == port(b)
    }

    private static func port(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil)
    }

    private static func withRoute(_ url: URL, _ value: String?) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (components.percentEncodedQueryItems ?? []).filter { $0.name != parameter }
        if let value { items.append(URLQueryItem(name: parameter, value: value)) }
        components.percentEncodedQueryItems = items.isEmpty ? nil : items
        return components.url ?? url
    }
}

/// Remembers, per server and network, that storage is blocked there and the media proxy works,
/// so later streams and downloads go straight to the proxy. Kept a week in `UserDefaults`; a
/// network where the proxy fails and storage works again forgets it at once.
///
/// `network` is the app's signature of the current network path; the app keeps it current.
public final class ProxyMemory: @unchecked Sendable {
    public static let defaultLifetime: TimeInterval = 7 * 24 * 3600
    /// A few servers on a few networks; more is an old phone's history.
    static let capacity = 32

    private let defaults: UserDefaults
    private let storageKey: String
    private let lifetime: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var _network = ""
    /// "host:port|network" → when the proxy was found to work there.
    private var entries: [String: Date]

    public init(
        defaults: UserDefaults = .standard, key: String = "storageRoute.proxy",
        lifetime: TimeInterval = ProxyMemory.defaultLifetime, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        storageKey = key
        self.lifetime = lifetime
        self.now = now
        let stored = defaults.dictionary(forKey: key) as? [String: Date] ?? [:]
        let current = now()
        entries = stored.filter { current.timeIntervalSince($0.value) < lifetime }
    }

    public var network: String {
        get { lock.withLock { _network } }
        set { lock.withLock { _network = newValue } }
    }

    /// Whether streams of `link`'s server go through the proxy on this network.
    public func usesProxy(for link: URL) -> Bool {
        guard let key = entryKey(link) else { return false }
        return lock.withLock {
            guard let since = entries[key] else { return false }
            if now().timeIntervalSince(since) < lifetime { return true }
            entries[key] = nil
            saveLocked()
            return false
        }
    }

    /// `link` as it is to be fetched here: through the proxy where storage was found blocked.
    public func route(_ link: URL) -> URL {
        guard StorageRoute.takesProxyRoute(link) else { return link }
        return usesProxy(for: link) ? StorageRoute.proxied(link) : StorageRoute.direct(link)
    }

    /// `url` worked after the other way had been blocked: through the proxy is remembered,
    /// straight to storage forgets the proxy.
    public func worked(_ url: URL) {
        guard let key = entryKey(url) else { return }
        lock.withLock {
            if StorageRoute.isProxied(url) {
                entries[key] = now()
                if entries.count > Self.capacity, let oldest = entries.min(by: { $0.value < $1.value }) { entries[oldest.key] = nil }
            } else {
                guard entries[key] != nil else { return }
                entries[key] = nil
            }
            saveLocked()
        }
    }

    /// One request for `link`, the way remembered for this network; when that one is blocked
    /// (`StorageRoute.isBlocked`), once more the other way, and the way that worked is
    /// remembered. A second failure is thrown or returned as it is.
    public func fetch<T: Sendable>(_ link: URL, _ attempt: @Sendable (URL) async throws -> (T, URLResponse)) async throws -> (T, URLResponse) {
        let first = route(link)
        do {
            let result = try await attempt(first)
            guard StorageRoute.isBlocked(response: result.1, link: first), let other = StorageRoute.alternate(to: first) else { return result }
            return try await retry(other, attempt)
        } catch {
            guard StorageRoute.isBlocked(error: error, link: first), let other = StorageRoute.alternate(to: first) else { throw error }
            return try await retry(other, attempt)
        }
    }

    private func retry<T: Sendable>(_ url: URL, _ attempt: @Sendable (URL) async throws -> (T, URLResponse)) async throws -> (T, URLResponse) {
        let result = try await attempt(url)
        if let http = result.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode) { worked(url) }
        return result
    }

    private func entryKey(_ link: URL) -> String? {
        guard let host = link.host?.lowercased() else { return nil }
        return "\(host):\(link.port.map(String.init) ?? "")|\(network)"
    }

    private func saveLocked() {
        defaults.set(entries, forKey: storageKey)
    }
}
