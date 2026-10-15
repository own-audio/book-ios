import Foundation

/// A `URLProtocol` stub. Each stubbed session gets its own handler and request log, keyed by a
/// header, because Swift Testing runs tests in parallel and a shared handler would let them
/// overwrite each other's stubs.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct StubbedResponse: Sendable {
        let statusCode: Int
        let body: Data
        var headers: [String: String] = [:]
        /// The body in this many pieces with `pieceDelay` seconds between them: a download
        /// that takes a while, as a real song's does.
        var pieces = 1
        var pieceDelay: Double = 0
    }

    typealias Handler = @Sendable (URLRequest) async throws -> StubbedResponse

    struct StubbedSession: Sendable {
        let urlSession: URLSession
        fileprivate let id: UUID

        func requestLog() async -> [URLRequest] {
            await MockURLProtocol.storage.requests(for: id)
        }

        /// The query items of the first request, by name.
        func firstQuery() async -> [URLQueryItem] {
            await requestLog().first?.url
                .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        }
    }

    private static let sessionHeaderKey = "X-Mock-Session"

    private actor Storage {
        private var handlers: [UUID: Handler] = [:]
        private var logs: [UUID: [URLRequest]] = [:]

        func register(_ id: UUID, handler: @escaping Handler) {
            handlers[id] = handler
            logs[id] = []
        }

        func handler(for id: UUID, logging request: URLRequest) -> Handler? {
            logs[id, default: []].append(request)
            return handlers[id]
        }

        func requests(for id: UUID) -> [URLRequest] { logs[id] ?? [] }
    }

    private static let storage = Storage()

    static func makeStubbedSession(_ handler: @escaping Handler) async -> StubbedSession {
        let id = UUID()
        await storage.register(id, handler: handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.httpAdditionalHeaders = [sessionHeaderKey: id.uuidString]
        return StubbedSession(urlSession: URLSession(configuration: config), id: id)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        guard
            let idString = request.value(forHTTPHeaderField: Self.sessionHeaderKey),
            let id = UUID(uuidString: idString)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        Task {
            guard let handler = await Self.storage.handler(for: id, logging: request) else {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            do {
                let stub = try await handler(request)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: stub.statusCode,
                    httpVersion: "HTTP/1.1", headerFields: stub.headers
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if stub.pieces > 1 {
                    let size = (stub.body.count + stub.pieces - 1) / stub.pieces
                    var offset = 0
                    while offset < stub.body.count {
                        let end = min(offset + size, stub.body.count)
                        client?.urlProtocol(self, didLoad: stub.body.subdata(in: offset..<end))
                        offset = end
                        if offset < stub.body.count { try await Task.sleep(nanoseconds: UInt64(stub.pieceDelay * 1_000_000_000)) }
                    }
                } else {
                    client?.urlProtocol(self, didLoad: stub.body)
                }
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}
