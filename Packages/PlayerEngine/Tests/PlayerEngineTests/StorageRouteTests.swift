import Foundation
import Testing

@testable import PlayerCore

/// own.audio's stream link and its way through the media proxy when storage is blocked.
@Suite("Storage route")
struct StorageRouteTests {
    static let link = URL(string: "https://server.example/api/v2/stream?i=book:1&f=orig&b=0&o=0&u=u1&e=1900000000&k=1&s=ab%2Bcd%2F_e")!
    static let storage = URL(string: "https://acct.r2.cloudflarestorage.com/bucket/file.m4b?X-Amz-Signature=1")!

    private func memory(now: @escaping @Sendable () -> Date = { Date() }, defaults: UserDefaults? = nil) -> ProxyMemory {
        ProxyMemory(defaults: defaults ?? UserDefaults(suiteName: "route-\(UUID().uuidString)")!, now: now)
    }

    private func failure(_ code: URLError.Code, at url: URL?) -> URLError {
        URLError(code, userInfo: url.map { [NSURLErrorFailingURLErrorKey: $0] } ?? [:])
    }

    @Test("only own.audio's stream link takes route=proxy; its signed parameters are kept byte for byte")
    func links() {
        #expect(StorageRoute.takesProxyRoute(Self.link))
        #expect(!StorageRoute.takesProxyRoute(URL(string: "https://abs.example/api/items/1/file/2?token=x")!))
        #expect(!StorageRoute.takesProxyRoute(URL(string: "https://feeds.example/episode.mp3?route=a")!))
        #expect(!StorageRoute.takesProxyRoute(URL(fileURLWithPath: "/tmp/api/v2/stream")))
        let proxied = StorageRoute.proxied(Self.link)
        #expect(proxied.absoluteString == Self.link.absoluteString + "&route=proxy")
        #expect(StorageRoute.isProxied(proxied) && !StorageRoute.isProxied(Self.link))
        #expect(StorageRoute.proxied(proxied) == proxied, "once is enough")
        #expect(StorageRoute.direct(proxied) == Self.link)
        #expect(StorageRoute.alternate(to: Self.link) == proxied && StorageRoute.alternate(to: proxied) == Self.link)
        #expect(StorageRoute.alternate(to: Self.storage) == nil, "another host's address is never changed")
    }

    @Test("a network failure at the storage host is a block", arguments: [
        URLError.Code.cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .networkConnectionLost, .timedOut,
        .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
    ])
    func blockingErrors(code: URLError.Code) {
        #expect(StorageRoute.isBlocked(error: failure(code, at: Self.storage), link: Self.link))
    }

    @Test("not a block: no network at all, a cancel, the server itself unreachable, or no host to tell")
    func notBlocked() {
        #expect(!StorageRoute.isBlocked(error: failure(.notConnectedToInternet, at: Self.storage), link: Self.link), "a gap in the signal")
        #expect(!StorageRoute.isBlocked(error: failure(.cancelled, at: Self.storage), link: Self.link))
        #expect(!StorageRoute.isBlocked(error: failure(.badServerResponse, at: Self.storage), link: Self.link))
        #expect(!StorageRoute.isBlocked(error: failure(.cannotFindHost, at: Self.link), link: Self.link), "the server's own host")
        #expect(!StorageRoute.isBlocked(error: failure(.cannotFindHost, at: nil), link: Self.link))
        #expect(StorageRoute.isBlocked(error: failure(.cannotFindHost, at: nil), link: Self.link, current: Self.storage), "a task that says where it was")
        #expect(!StorageRoute.isBlocked(error: CancellationError(), link: Self.link))
    }

    @Test("403, 407 and 451 from another host are a block; a 403 from the server is an expired link")
    func blockingAnswers() {
        func answer(_ status: Int, from url: URL) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        }
        for status in [403, 407, 451] {
            #expect(StorageRoute.isBlocked(response: answer(status, from: Self.storage), link: Self.link), "\(status)")
        }
        #expect(!StorageRoute.isBlocked(response: answer(403, from: Self.link), link: Self.link), "invalid_link: renewed, not rerouted")
        #expect(!StorageRoute.isBlocked(response: answer(404, from: Self.storage), link: Self.link))
        #expect(!StorageRoute.isBlocked(response: answer(206, from: Self.storage), link: Self.link))
        let otherPort = URL(string: "https://server.example:8443/x")!
        #expect(StorageRoute.isBlocked(response: answer(403, from: otherPort), link: Self.link), "another port is another host")
    }

    @Test("remembered per server and network, kept across launches, forgotten after a week")
    func memoryPerNetwork() {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 2_000_000_000) }
        let clock = Clock()
        let defaults = UserDefaults(suiteName: "route-\(UUID().uuidString)")!
        let memory = memory(now: { clock.now }, defaults: defaults)
        memory.network = "up,wifi-en0"
        #expect(memory.route(Self.link) == Self.link)
        memory.worked(StorageRoute.proxied(Self.link))
        #expect(memory.usesProxy(for: Self.link))
        #expect(memory.route(Self.link) == StorageRoute.proxied(Self.link))
        #expect(memory.route(Self.storage) == Self.storage, "only stream links are routed")
        #expect(!memory.usesProxy(for: URL(string: "https://other.example/api/v2/stream?s=1")!), "another server")

        memory.network = "up,cellular-pdp_ip0"
        #expect(!memory.usesProxy(for: Self.link), "another network goes straight to storage")

        let relaunched = ProxyMemory(defaults: defaults, now: { clock.now })
        relaunched.network = "up,wifi-en0"
        #expect(relaunched.usesProxy(for: Self.link), "kept in UserDefaults")

        clock.now += ProxyMemory.defaultLifetime + 1
        #expect(!relaunched.usesProxy(for: Self.link), "a week later storage is tried again")
    }

    @Test("blocked: once more through the proxy, which is remembered; later fetches go straight to it")
    func fetchFallsBack() async throws {
        let memory = memory()
        memory.network = "office"
        let tried = Tried()
        let (body, _) = try await memory.fetch(Self.link) { url in
            tried.append(url)
            if StorageRoute.isProxied(url) { return (Data("audio".utf8), HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: nil)!) }
            throw URLError(.cannotFindHost, userInfo: [NSURLErrorFailingURLErrorKey: Self.storage])
        }
        #expect(body == Data("audio".utf8))
        #expect(tried.urls == [Self.link, StorageRoute.proxied(Self.link)])
        #expect(memory.usesProxy(for: Self.link))

        _ = try await memory.fetch(Self.link) { url in
            tried.append(url)
            return (Data(), HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: nil)!)
        }
        #expect(tried.urls.last == StorageRoute.proxied(Self.link) && tried.urls.count == 3, "straight to the proxy")
    }

    @Test("the proxy fails but storage works again: forgotten")
    func forgetsWhenStorageWorks() async throws {
        let memory = memory()
        memory.worked(StorageRoute.proxied(Self.link))
        let proxyHost = URL(string: "https://media.example/file")!
        _ = try await memory.fetch(Self.link) { url in
            if StorageRoute.isProxied(url) { throw URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: proxyHost]) }
            return (Data(), HTTPURLResponse(url: Self.storage, statusCode: 206, httpVersion: nil, headerFields: nil)!)
        }
        #expect(!memory.usesProxy(for: Self.link))
    }

    @Test("not a block: the error comes back as it is, with no second request")
    func noFallbackOtherwise() async {
        let memory = memory()
        let tried = Tried()
        await #expect(throws: URLError.self) {
            _ = try await memory.fetch(Self.link) { url -> (Data, URLResponse) in
                tried.append(url)
                throw URLError(.notConnectedToInternet, userInfo: [NSURLErrorFailingURLErrorKey: Self.storage])
            }
        }
        // A 403 from the server itself goes back to the caller, which renews the link.
        let (_, response) = try! await memory.fetch(Self.link) { url in
            tried.append(url)
            return (Data(), HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        #expect((response as? HTTPURLResponse)?.statusCode == 403)
        #expect(tried.urls == [Self.link, Self.link])
        #expect(!memory.usesProxy(for: Self.link))
    }

    @Test("the listening cache downloads through the proxy when storage is blocked")
    func cacheDownload() async throws {
        let server = RangeServer()
        try server.add("/files/book.m4b", fixture: "test-book.m4b", type: "audio/mp4")
        server.blockedHosts = ["storage.example"]
        let session = await MockURLProtocol.makeStubbedSession { request in try server.respond(request) }
        let memory = memory()
        let link = URL(string: "https://server.example/api/v2/stream?i=/files/book.m4b&f=orig&k=1&s=sig")!
        let cache = TrackFileCache(
            remoteURL: { _ in link }, session: session.urlSession,
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString)"),
            storageRoute: memory
        )
        let file = try await cache.localURL(trackId: "book1#p1")
        #expect(file.pathExtension == "m4a")
        #expect(server.servedHosts == ["media.example"])
        #expect(memory.usesProxy(for: link))
    }
}

final class Tried: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    var urls: [URL] { lock.withLock { _urls } }
    func append(_ url: URL) { lock.withLock { _urls.append(url) } }
}
