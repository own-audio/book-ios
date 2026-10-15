import Foundation
import OSLog

/// What can go wrong talking to an Audiobookshelf server.
public enum AudiobookshelfError: Error, Sendable, Equatable {
    /// The server refused the sign-in (wrong name or password, or a locked account).
    case invalidCredentials
    /// Signed out: the refresh token was refused, so the account has to sign in again.
    case signedOut
    /// The server answered with an HTTP error; `message` is its text or `{error}` body.
    case http(Int, message: String?)
    case decoding
    case network
    /// Offline, and this wasn't saved from an earlier visit.
    case offline
}

/// Where answers to reads are kept, so a screen seen once opens again with no network. The key
/// names the server, the path and the query, never a token.
public protocol AnswerCache: Sendable {
    func data(forKey key: String) -> Data?
    func store(_ data: Data, forKey key: String)
}

/// Where the tokens live between launches (the app keeps them in the Keychain). Called
/// whenever a refresh rotates them; `nil` means signed out.
public protocol TokenKeeper: Sendable {
    func save(_ tokens: Tokens?) async
}

/// The access and refresh tokens of one signed-in account, refreshed one at a time.
///
/// Since Audiobookshelf 2.26 the access token is a JWT that lives an hour and the refresh token
/// rotates on every use; a refresh token used twice signs the device out. So concurrent requests
/// that find the access token expired must share one refresh rather than each start their own —
/// this actor makes them wait for it. A server older than 2.26 hands out one token that never
/// expires and no refresh token; those tokens are kept as they are.
public actor TokenSession {
    private var tokens: Tokens?
    private var refreshing: Task<Tokens, Error>?
    private let keeper: TokenKeeper?
    /// Refresh this long before the access token expires, so a request is not sent with one
    /// that dies on the way.
    private let margin: TimeInterval = 60

    public init(_ tokens: Tokens?, keeper: TokenKeeper? = nil) {
        self.tokens = tokens
        self.keeper = keeper
    }

    public var current: Tokens? { tokens }

    /// An access token that is good now, refreshing first when it is about to expire.
    func accessToken(using refresh: @Sendable @escaping (String) async throws -> Tokens) async throws -> String {
        guard let tokens else { throw AudiobookshelfError.signedOut }
        if tokens.refreshToken == nil || tokens.expiresAt.timeIntervalSinceNow > margin {
            return tokens.accessToken
        }
        return try await self.refresh(using: refresh).accessToken
    }

    /// Refreshes once, however many callers ask at the same time.
    func refresh(using refresh: @Sendable @escaping (String) async throws -> Tokens) async throws -> Tokens {
        if let refreshing {
            return try await refreshing.value
        }
        guard let refreshToken = tokens?.refreshToken else { throw AudiobookshelfError.signedOut }
        let task = Task { try await refresh(refreshToken) }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            tokens = fresh
            await keeper?.save(fresh)
            return fresh
        } catch AudiobookshelfError.http(let status, _) where status == 401 || status == 403 {
            tokens = nil
            await keeper?.save(nil)
            throw AudiobookshelfError.signedOut
        }
    }

    func signedOut() async {
        tokens = nil
        await keeper?.save(nil)
    }
}

/// A client for Audiobookshelf's REST API (2.x; tokens as of 2.26).
public struct AudiobookshelfClient: Sendable {
    public let host: URL
    public let tokens: TokenSession
    let session: URLSession
    let cache: AnswerCache?
    /// What answers are filed under: the server, whichever address it is reached at.
    let cacheIdentity: String?
    let isOffline: @Sendable () -> Bool

    /// With `cache`, reads of the library are kept and answer again offline (`isOffline`) or
    /// when the server can't be reached.
    public init(
        host: URL, tokens: TokenSession, session: URLSession = .shared,
        cache: AnswerCache? = nil, cacheIdentity: String? = nil, isOffline: @escaping @Sendable () -> Bool = { false }
    ) {
        self.host = host
        self.tokens = tokens
        self.session = session
        self.cache = cache
        self.cacheIdentity = cacheIdentity
        self.isOffline = isOffline
    }

    // MARK: - Before signing in

    /// A typed address made into a URL: `host:port` and `host` get `http://`, because most home
    /// servers sit on a LAN with no TLS; a full `http(s)://…` is kept.
    public static func url(fromTyped text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: withScheme), url.host() != nil else { return nil }
        return url
    }

    /// What the server at `host` is, before signing in; an error when it is not Audiobookshelf.
    public static func status(host: URL, session: URLSession = .shared) async throws -> ServerStatus {
        var request = URLRequest(url: host.appending(path: "status"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let status: ServerStatus = try await send(request, session: session)
        guard status.app == "audiobookshelf" else { throw AudiobookshelfError.decoding }
        return status
    }

    /// Signs in with a name and password. Throws `.invalidCredentials` when refused.
    public static func signIn(host: URL, username: String, password: String, session: URLSession = .shared) async throws -> SignIn {
        var request = URLRequest(url: host.appending(path: "login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Without this the refresh token goes into an httpOnly cookie and the body says null.
        request.setValue("true", forHTTPHeaderField: "x-return-tokens")
        request.httpBody = try JSONEncoder().encode(["username": username, "password": password])
        do {
            let answer: SignInAnswer = try await send(request, session: session)
            return try answer.signIn()
        } catch AudiobookshelfError.http(let status, _) where status == 401 || status == 403 {
            throw AudiobookshelfError.invalidCredentials
        }
    }

    static func refresh(host: URL, refreshToken: String, session: URLSession) async throws -> Tokens {
        var request = URLRequest(url: host.appending(path: "auth/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(refreshToken, forHTTPHeaderField: "x-refresh-token")
        let answer: SignInAnswer = try await send(request, session: session)
        return try answer.signIn().tokens
    }

    /// Ends this device's session on the server; the tokens are forgotten either way.
    public func signOut() async {
        if let current = await tokens.current {
            var request = URLRequest(url: host.appending(path: "logout"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
            if let refresh = current.refreshToken { request.setValue(refresh, forHTTPHeaderField: "x-refresh-token") }
            _ = try? await session.data(for: request)
        }
        await tokens.signedOut()
    }

    // MARK: - Signed in

    /// GET `path` (under the server root, e.g. `api/libraries`), decoded.
    public func get<T: Decodable>(_ path: String, query: [String: String?] = [:]) async throws -> T {
        try await call("GET", path, query: query, body: Optional<Empty>.none)
    }

    /// A request with a JSON body, decoded. Answers that are plain text (`OK`) decode as `Empty`.
    public func call<T: Decodable, B: Encodable>(_ method: String, _ path: String, query: [String: String?] = [:], body: B?) async throws -> T {
        let data = try await raw(method, path, query: query, body: body)
        if T.self == Empty.self { return Empty() as! T }
        do {
            return try JSONDecoder.audiobookshelf.decode(T.self, from: data)
        } catch {
            networkLog.error("\(method, privacy: .public) /\(path, privacy: .public): unreadable answer: \(String(describing: error), privacy: .public)")
            throw AudiobookshelfError.decoding
        }
    }

    /// A request whose answer does not matter.
    public func send<B: Encodable>(_ method: String, _ path: String, query: [String: String?] = [:], body: B?) async throws {
        _ = try await raw(method, path, query: query, body: body)
    }

    /// The bytes of a request, with the access token; a `401` is answered once with a refresh.
    /// Offline, a saved answer to a read or `.offline` without touching the network; online, a
    /// network failure falls back to the saved answer.
    func raw<B: Encodable>(_ method: String, _ path: String, query: [String: String?], body: B?) async throws -> Data {
        let key = method == "GET" && Self.keeps(path) ? cacheKey(path, query: query) : nil
        let saved = { key.flatMap { cache?.data(forKey: $0) } }
        if isOffline() {
            guard let data = saved() else { throw AudiobookshelfError.offline }
            return data
        }
        do {
            let data = try await fetch(method, path, query: query, body: body)
            if let key { cache?.store(data, forKey: key) }
            return data
        } catch AudiobookshelfError.network {
            if let data = saved() { return data }
            throw AudiobookshelfError.network
        }
    }

    /// Reads whose answers are kept: the library and what is in it. Not search (an old answer
    /// would mislead), not `api/me` or `api/authorize` (the connection check asks those), not
    /// sessions.
    static func keeps(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.first == "api", parts.count >= 2 else { return false }
        switch parts[1] {
        case "libraries":
            return parts.last != "search"
        case "items", "series", "authors", "collections":
            return true
        default:
            return false
        }
    }

    func cacheKey(_ path: String, query: [String: String?]) -> String {
        let params = query.compactMap { k, v in v.map { "\(k)=\($0)" } }.sorted().joined(separator: "&")
        return "\(cacheIdentity ?? host.absoluteString)|\(path)?\(params)"
    }

    private func fetch<B: Encodable>(_ method: String, _ path: String, query: [String: String?], body: B?) async throws -> Data {
        let build = { (token: String) throws -> URLRequest in
            var request = URLRequest(url: try url(path, query: query))
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder.audiobookshelf.encode(body)
            }
            return request
        }
        let refresher = refresher()
        let token = try await tokens.accessToken(using: refresher)
        do {
            return try await Self.data(build(token), session: session)
        } catch AudiobookshelfError.http(401, _) {
            // The access token was revoked or expired early: one refresh, one more try. With no
            // refresh token (a pre-2.26 server) the session is simply over.
            let fresh = try await tokens.refresh(using: refresher)
            return try await Self.data(build(fresh.accessToken), session: session)
        }
    }

    func refresher() -> @Sendable (String) async throws -> Tokens {
        let host = host
        let session = session
        return { refresh in try await AudiobookshelfClient.refresh(host: host, refreshToken: refresh, session: session) }
    }

    func url(_ path: String, query: [String: String?]) throws -> URL {
        var components = URLComponents(url: host.appending(path: path), resolvingAgainstBaseURL: false)
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }.sorted { $0.name < $1.name }
        if !items.isEmpty { components?.queryItems = items }
        guard let url = components?.url else { throw AudiobookshelfError.network }
        return url
    }

    // MARK: - Media and covers

    /// The access token good now, for URLs a player or an image view loads on its own; they
    /// carry it as `?token=` because neither can send a header.
    public func freshToken() async throws -> String {
        try await tokens.accessToken(using: refresher())
    }

    /// One audio file of an item, with ranges; `token` from `freshToken()`.
    public func fileURL(itemId: String, ino: String, token: String) -> URL {
        var components = URLComponents(url: host.appending(path: "api/items/\(itemId)/file/\(ino)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url!
    }

    /// A `contentUrl` from a play session (a file path, or an HLS playlist), made absolute and
    /// given the token.
    public func mediaURL(contentUrl: String, token: String) -> URL {
        var components = URLComponents(url: host.appending(path: contentUrl.hasPrefix("/") ? String(contentUrl.dropFirst()) : contentUrl), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url!
    }

    /// An item's cover. Covers need no token on 2.37 (checked), but one is sent when known so
    /// a server that requires it still answers.
    public func coverURL(itemId: String, width: Int, token: String? = nil) -> URL {
        var components = URLComponents(url: host.appending(path: "api/items/\(itemId)/cover"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "width", value: String(width)), URLQueryItem(name: "format", value: "jpeg")]
        if let token { items.append(URLQueryItem(name: "token", value: token)) }
        components.queryItems = items
        return components.url!
    }

    // MARK: - Transport

    static func send<T: Decodable>(_ request: URLRequest, session: URLSession) async throws -> T {
        let data = try await data(request, session: session)
        do {
            return try JSONDecoder.audiobookshelf.decode(T.self, from: data)
        } catch {
            networkLog.error("\(request.httpMethod ?? "GET", privacy: .public) \(request.url?.path ?? "", privacy: .public): unreadable answer: \(String(describing: error), privacy: .public)")
            throw AudiobookshelfError.decoding
        }
    }

    static func data(_ request: URLRequest, session: URLSession) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            networkLog.error("\(request.httpMethod ?? "GET", privacy: .public) \(request.url?.path ?? "", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw AudiobookshelfError.network
        }
        guard let http = response as? HTTPURLResponse else { throw AudiobookshelfError.network }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(decoding: data.prefix(300), as: UTF8.self)
            networkLog.error("\(request.httpMethod ?? "GET", privacy: .public) \(request.url?.path ?? "", privacy: .public): HTTP \(http.statusCode) \(text, privacy: .public)")
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? (text.isEmpty ? nil : text)
            throw AudiobookshelfError.http(http.statusCode, message: message)
        }
        return data
    }
}

/// No body, or an answer that is only `OK`.
public struct Empty: Codable, Sendable {
    public init() {}
}

extension JSONDecoder {
    static let audiobookshelf: JSONDecoder = JSONDecoder()
}

extension JSONEncoder {
    static let audiobookshelf: JSONEncoder = JSONEncoder()
}

/// Requests that fail, and why: the errors thrown say only "network" or "decoding". The path
/// alone is logged, never the query, which can carry a token.
let networkLog = Logger(subsystem: "audio.own.bookplayer", category: "network.audiobookshelf")
