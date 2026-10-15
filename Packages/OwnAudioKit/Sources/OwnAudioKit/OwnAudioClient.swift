import Foundation
import OSLog

/// What can go wrong talking to an own.audio server.
public enum OwnAudioError: Error, Sendable, Equatable {
    /// The server answered with problem details (`status`, `code`).
    case problem(Problem)
    /// Signed out: the refresh token was refused, so the account has to sign in again.
    case signedOut
    /// The account has two-factor sign-in: finish with `OwnAudioClient.finishTwoFactor`.
    case twoFactorRequired(mfaToken: String, methods: [String])
    case http(Int)
    case decoding
    case network
    /// Offline, and this wasn't saved from an earlier visit.
    case offline
}

/// Where answers to reads are kept, so a screen seen once opens again with no network. The
/// app's disk cache; the key names the server, the path and the query, never a token.
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
/// A refresh token works once: the server rotates it on every use and treats a second use as
/// theft, signing the device out. So concurrent requests that find the access token expired
/// must share one refresh rather than each start their own — this actor makes them wait for it.
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
        guard let tokens else { throw OwnAudioError.signedOut }
        if tokens.expiresAt.timeIntervalSinceNow > margin {
            return tokens.accessToken
        }
        return try await self.refresh(using: refresh).accessToken
    }

    /// Refreshes once, however many callers ask at the same time.
    func refresh(using refresh: @Sendable @escaping (String) async throws -> Tokens) async throws -> Tokens {
        if let refreshing {
            return try await refreshing.value
        }
        guard let refreshToken = tokens?.refreshToken else { throw OwnAudioError.signedOut }
        let task = Task { try await refresh(refreshToken) }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            tokens = fresh
            await keeper?.save(fresh)
            return fresh
        } catch OwnAudioError.problem(let p) where p.code == "invalid_grant" {
            tokens = nil
            await keeper?.save(nil)
            throw OwnAudioError.signedOut
        }
    }

    func signedOut() async {
        tokens = nil
        await keeper?.save(nil)
    }
}

/// A client for own.audio's own API, `/api/v2`.
public struct OwnAudioClient: Sendable {
    public let host: URL
    public let tokens: TokenSession
    let session: URLSession
    let cache: AnswerCache?
    /// What answers are filed under: the server, whichever address it is reached at.
    let cacheIdentity: String?
    let isOffline: @Sendable () -> Bool

    /// What the session list shows for this device.
    public struct Device: Sendable {
        public var name: String
        public var kind: String
        public init(name: String, kind: String = "ios") {
            self.name = name
            self.kind = kind
        }
    }

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

    /// What the server at `host` is, or an error when it is not an own.audio server.
    public static func discover(host: URL, session: URLSession = .shared) async throws -> Discovery {
        var request = URLRequest(url: host.appending(path: ".well-known/own-audio"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request, session: session)
    }

    /// Signs in with an email and password. Throws `.twoFactorRequired` when the account asks
    /// for a second factor, `.problem` with `invalid_grant` for wrong credentials.
    public static func signIn(host: URL, email: String, password: String, device: Device, session: URLSession = .shared) async throws -> Tokens {
        try await token(host: host, session: session, fields: [
            "grant_type": "password", "username": email, "password": password,
            "device_name": device.name, "device_kind": device.kind,
        ])
    }

    /// Finishes a sign-in that answered `.twoFactorRequired`, with the authenticator's code or
    /// a recovery code.
    public static func finishTwoFactor(host: URL, mfaToken: String, code: String, session: URLSession = .shared) async throws -> Tokens {
        try await token(host: host, session: session, fields: [
            "grant_type": "urn:own-audio:params:oauth:grant-type:mfa-otp", "mfa_token": mfaToken, "otp": code,
        ])
    }

    /// A provider's id token (Apple, Google): the server checks it and signs the account in.
    public static func signIn(host: URL, provider: String, idToken: String, fullName: String? = nil, device: Device, session: URLSession = .shared) async throws -> Tokens {
        var fields = [
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "provider": provider, "assertion": idToken,
            "device_name": device.name, "device_kind": device.kind,
        ]
        fields["full_name"] = fullName
        return try await token(host: host, session: session, fields: fields)
    }

    static func refresh(host: URL, refreshToken: String, session: URLSession) async throws -> Tokens {
        try await token(host: host, session: session, fields: ["grant_type": "refresh_token", "refresh_token": refreshToken])
    }

    private static func token(host: URL, session: URLSession, fields: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: host.appending(path: "api/v2/auth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formEncode(fields)
        do {
            let response: TokenResponse = try await send(request, session: session)
            return response.tokens()
        } catch OwnAudioError.problem(let p) where p.code == "mfa_required" {
            throw OwnAudioError.twoFactorRequired(mfaToken: p.mfaToken ?? "", methods: p.mfaMethods ?? [])
        }
    }

    /// Ends this device's session on the server; the tokens are forgotten either way.
    public func signOut() async {
        if let refresh = await tokens.current?.refreshToken {
            var request = URLRequest(url: host.appending(path: "api/v2/auth/revoke"))
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formEncode(["token": refresh])
            _ = try? await session.data(for: request)
        }
        await tokens.signedOut()
    }

    // MARK: - Signed in

    /// GET `path` under `/api/v2`, decoded.
    public func get<T: Decodable>(_ path: String, query: [String: String?] = [:]) async throws -> T {
        try await call("GET", path, query: query, body: Optional<Empty>.none)
    }

    /// GET `path` under `/api/v1`, for the few things only that version has; the same
    /// access token works there.
    func getV1<T: Decodable>(_ path: String) async throws -> T {
        let data = try await raw("GET", path, query: [:], body: Optional<Empty>.none, idempotencyKey: nil, api: "api/v1")
        do {
            return try JSONDecoder.ownAudio.decode(T.self, from: data)
        } catch {
            networkLog.error("GET /api/v1\(path, privacy: .public): unreadable answer: \(String(describing: error), privacy: .public)")
            throw OwnAudioError.decoding
        }
    }

    /// A request with a JSON body, decoded. `idempotencyKey` makes a retry harmless.
    public func call<T: Decodable, B: Encodable>(_ method: String, _ path: String, query: [String: String?] = [:], body: B?, idempotencyKey: String? = nil) async throws -> T {
        let data = try await raw(method, path, query: query, body: body, idempotencyKey: idempotencyKey)
        if T.self == Empty.self { return Empty() as! T }
        do {
            return try JSONDecoder.ownAudio.decode(T.self, from: data)
        } catch {
            networkLog.error("\(method, privacy: .public) /api/v2\(path, privacy: .public): unreadable answer: \(String(describing: error), privacy: .public)")
            throw OwnAudioError.decoding
        }
    }

    /// A request whose answer has no body (`204`).
    public func send<B: Encodable>(_ method: String, _ path: String, body: B?) async throws {
        _ = try await raw(method, path, query: [:], body: body, idempotencyKey: nil)
    }

    /// The bytes of a request, with the access token; a `401` is answered once with a refresh.
    /// Offline, a saved answer to a read or `.offline` without touching the network; online, a
    /// network failure falls back to the saved answer.
    func raw<B: Encodable>(_ method: String, _ path: String, query: [String: String?], body: B?, idempotencyKey: String?, api: String = "api/v2") async throws -> Data {
        let key = method == "GET" && Self.keeps(path) ? cacheKey(path, query: query, api: api) : nil
        let saved = { key.flatMap { cache?.data(forKey: $0) } }
        if isOffline() {
            guard let data = saved() else { throw OwnAudioError.offline }
            return data
        }
        do {
            let data = try await fetch(method, path, query: query, body: body, idempotencyKey: idempotencyKey, api: api)
            if let key { cache?.store(data, forKey: key) }
            return data
        } catch OwnAudioError.network {
            if let data = saved() { return data }
            throw OwnAudioError.network
        }
    }

    /// Reads whose answers are kept. Search and random picks are left out: an old answer to
    /// those would mislead rather than help.
    static func keeps(_ path: String) -> Bool {
        let path = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let first = path.split(separator: "/").first.map(String.init) ?? path
        switch first {
        case "artists", "contributors", "albums", "tracks", "genres", "playlists", "smart-playlists":
            return !path.hasSuffix("/random") && !path.hasSuffix("/resolve")
        case "family":
            return path == "family" || path == "family/members" || path == "family/storage" || path == "family/billing"
        case "me":
            // Not `me` itself: the connection check asks it, and must not be answered from here.
            return path.hasPrefix("me/favourites") || path.hasPrefix("me/ratings") || path.hasPrefix("me/played")
        default:
            return false
        }
    }

    func cacheKey(_ path: String, query: [String: String?], api: String) -> String {
        let params = query.compactMap { k, v in v.map { "\(k)=\($0)" } }.sorted().joined(separator: "&")
        return "\(cacheIdentity ?? host.absoluteString)|\(api)/\(path)?\(params)"
    }

    private func fetch<B: Encodable>(_ method: String, _ path: String, query: [String: String?], body: B?, idempotencyKey: String?, api: String) async throws -> Data {
        let build = { (token: String) throws -> URLRequest in
            var request = URLRequest(url: try url(path, query: query, api: api))
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder.ownAudio.encode(body)
            }
            if let idempotencyKey {
                request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
            }
            return request
        }
        let refresher = refresher()
        let token = try await tokens.accessToken(using: refresher)
        do {
            return try await Self.data(build(token), session: session)
        } catch OwnAudioError.problem(let p) where p.status == 401 {
            // The access token was revoked or expired early: one refresh, one more try.
            let fresh = try await tokens.refresh(using: refresher)
            return try await Self.data(build(fresh.accessToken), session: session)
        }
    }

    func refresher() -> @Sendable (String) async throws -> Tokens {
        let host = host
        let session = session
        return { refresh in try await OwnAudioClient.refresh(host: host, refreshToken: refresh, session: session) }
    }

    func url(_ path: String, query: [String: String?], api: String = "api/v2") throws -> URL {
        var components = URLComponents(url: host.appending(path: api + (path.hasPrefix("/") ? path : "/" + path)), resolvingAgainstBaseURL: false)
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }.sorted { $0.name < $1.name }
        if !items.isEmpty { components?.queryItems = items }
        guard let url = components?.url else { throw OwnAudioError.network }
        return url
    }

    // MARK: - Transport

    static func send<T: Decodable>(_ request: URLRequest, session: URLSession) async throws -> T {
        let data = try await data(request, session: session)
        do {
            return try JSONDecoder.ownAudio.decode(T.self, from: data)
        } catch {
            networkLog.error("\(request.httpMethod ?? "GET", privacy: .public) \(request.url?.path ?? "", privacy: .public): unreadable answer: \(String(describing: error), privacy: .public)")
            throw OwnAudioError.decoding
        }
    }

    static func data(_ request: URLRequest, session: URLSession) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            networkLog.error("\(request.httpMethod ?? "GET", privacy: .public) \(request.url?.path ?? "", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw OwnAudioError.network
        }
        guard let http = response as? HTTPURLResponse else { throw OwnAudioError.network }
        guard (200..<300).contains(http.statusCode) else {
            networkLog.error("\(request.httpMethod ?? "GET", privacy: .public) \(request.url?.path ?? "", privacy: .public): HTTP \(http.statusCode) \(String(decoding: data.prefix(300), as: UTF8.self), privacy: .public)")
            if let problem = try? JSONDecoder.ownAudio.decode(Problem.self, from: data) {
                throw OwnAudioError.problem(problem)
            }
            throw OwnAudioError.http(http.statusCode)
        }
        return data
    }

    static func formEncode(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }
}

/// No body, or no answer.
public struct Empty: Codable, Sendable {
    public init() {}
}

/// Requests that fail, and why: the errors thrown say only "network" or "decoding". The path
/// alone is logged, never the query, which can carry a sign-in.
let networkLog = Logger(subsystem: "audio.own.musicplayer", category: "network")
