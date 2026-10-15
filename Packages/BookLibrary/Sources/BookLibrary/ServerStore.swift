import AudiobookshelfKit
import Foundation
import OwnAudioKit
import Security
import ServerSupport
import os

public enum ServerKind: String, Codable, Sendable, CaseIterable {
    case audiobookshelf, ownAudio
}

/// How the app signs in to a server; kept in the Keychain only. Both kinds hand out tokens
/// that rotate on refresh, so they are saved again each time; `nil` tokens mean the server
/// refused a refresh and the account has to sign in again.
public enum ServerAuth: Codable, Sendable, Equatable {
    case audiobookshelf(username: String, tokens: AudiobookshelfKit.Tokens?)
    case ownAudio(username: String, tokens: OwnAudioKit.Tokens?)

    public var username: String {
        switch self {
        case .audiobookshelf(let username, _): username
        case .ownAudio(let username, _): username
        }
    }

    public var isSignedIn: Bool {
        switch self {
        case .audiobookshelf(_, let tokens): tokens != nil
        case .ownAudio(_, let tokens): tokens != nil
        }
    }
}

/// One configured server. `displayName` defaults to the server's name or host and can be
/// renamed later.
public struct ServerRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var displayName: String
    public let kind: ServerKind
    /// The address the server was added with.
    public var host: URL
    public var auth: ServerAuth
    /// Audiobookshelf: the book library shown (an account may reach several). own.audio: nil.
    public var libraryId: String?
    /// The account's id on the server, for sessions built on the phone.
    public var userId: String?
    /// The server's own identity, where its kind has one (own.audio). An address that
    /// answers with another id is not this server.
    public var serverId: String?
    /// Every other address the server is known by: told by the server, or added by hand.
    public var addresses: [ServerAddress]
    public var connection: ConnectionMode

    public init(
        id: UUID = UUID(), displayName: String, kind: ServerKind, host: URL, auth: ServerAuth,
        libraryId: String? = nil, userId: String? = nil, serverId: String? = nil, addresses: [ServerAddress] = [],
        connection: ConnectionMode = .automatic
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.host = host
        self.auth = auth
        self.libraryId = libraryId
        self.userId = userId
        self.serverId = serverId
        self.addresses = addresses
        self.connection = connection
    }

    /// Every address to try, the one it was added with first, each once, the unsafe ones out.
    public var candidateAddresses: [ServerAddress] {
        var seen = Set<URL>()
        return ([ServerAddress(url: host, origin: .added)] + addresses).filter {
            $0.isSafeToUse && seen.insert(Self.normalized($0.url)).inserted
        }
    }

    /// Adds addresses the server named, keeping the ones already known.
    public mutating func learn(_ named: [ServerAddress]) {
        let known = Set(candidateAddresses.map { Self.normalized($0.url) })
        addresses += named.filter { !known.contains(Self.normalized($0.url)) }
    }

    static func normalized(_ url: URL) -> URL {
        var text = url.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text) ?? url
    }
}

/// Every configured server, stored as a single Keychain item so adding or removing one is a
/// single write.
public actor ServerStore {
    private let service: String
    private let account = "servers"
    private let logger = Logger(subsystem: "audio.own.bookplayer", category: "ServerStore")

    public init(service: String = "audio.own.bookplayer.servers") {
        self.service = service
    }

    public func loadAll() -> [ServerRecord] {
        guard let data = loadRawData() else { return [] }
        do {
            return try JSONDecoder().decode([ServerRecord].self, from: data)
        } catch {
            logger.error("Saved servers could not be decoded.")
            return []
        }
    }

    public func add(_ record: ServerRecord) throws {
        try persist(loadAll() + [record])
    }

    public func remove(id: UUID) throws {
        try persist(loadAll().filter { $0.id != id })
    }

    public func rename(id: UUID, to displayName: String) throws {
        var records = loadAll()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].displayName = displayName
        try persist(records)
    }

    public func update(_ record: ServerRecord) throws {
        var records = loadAll()
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
        try persist(records)
    }

    /// Rotated tokens; nil after a refused refresh.
    public func updateTokens(serverId: UUID, ownAudio tokens: OwnAudioKit.Tokens?) {
        var records = loadAll()
        guard let index = records.firstIndex(where: { $0.id == serverId }),
              case .ownAudio(let username, _) = records[index].auth else { return }
        records[index].auth = .ownAudio(username: username, tokens: tokens)
        save(records)
    }

    public func updateTokens(serverId: UUID, audiobookshelf tokens: AudiobookshelfKit.Tokens?) {
        var records = loadAll()
        guard let index = records.firstIndex(where: { $0.id == serverId }),
              case .audiobookshelf(let username, _) = records[index].auth else { return }
        records[index].auth = .audiobookshelf(username: username, tokens: tokens)
        save(records)
    }

    private func save(_ records: [ServerRecord]) {
        do {
            try persist(records)
        } catch {
            logger.error("Rotated tokens could not be saved.")
        }
    }

    public func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func loadRawData() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                logger.error("Server load failed: OSStatus \(status, privacy: .public)")
            }
            return nil
        }
        return data
    }

    private func persist(_ records: [ServerRecord]) throws {
        let data = try JSONEncoder().encode(records)
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery()
            addQuery[kSecValueData as String] = data
            // Playback continues with the screen locked, and requests need the sign-in then.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ServerStoreError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw ServerStoreError.keychain(updateStatus)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public enum ServerStoreError: Error, Sendable {
    case keychain(OSStatus)
}

/// This device, as servers see it: in session lists and play sessions.
public struct DeviceIdentity: Sendable, Equatable {
    /// Stable for the installation.
    public let id: String
    public let name: String
    public let model: String
    public let appVersion: String
    public let systemVersion: String

    public init(id: String, name: String, model: String, appVersion: String, systemVersion: String) {
        self.id = id
        self.name = name
        self.model = model
        self.appVersion = appVersion
        self.systemVersion = systemVersion
    }

    var audiobookshelf: DeviceInfo {
        DeviceInfo(deviceId: id, clientName: "own.audio Books", clientVersion: appVersion, manufacturer: "Apple", model: model, sdkVersion: systemVersion)
    }

    var ownAudio: OwnAudioClient.Device {
        OwnAudioClient.Device(name: name, kind: "ios")
    }
}

/// What every source shares: the session to make requests with, the saved answers, the offline
/// switch, this device, and the token sessions kept across rebuilt sources.
public struct SourceEnvironment: Sendable {
    public let urlSession: URLSession
    public let cache: ResponseCache?
    public let offline: OfflineSwitch?
    public let device: DeviceIdentity
    public let sessions: TokenSessions

    public init(urlSession: URLSession, cache: ResponseCache?, offline: OfflineSwitch?, device: DeviceIdentity, sessions: TokenSessions = TokenSessions(store: nil)) {
        self.urlSession = urlSession
        self.cache = cache
        self.offline = offline
        self.device = device
        self.sessions = sessions
    }
}

/// One token session per server, kept across the sources the app rebuilds whenever an address
/// changes. A refresh token works once; two sources refreshing the same one would look like
/// theft to the server, which then signs the device out. The own.audio catalogue lives here
/// too, so a rebuilt source goes on from the same copy.
public final class TokenSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var ownAudio: [UUID: OwnAudioKit.TokenSession] = [:]
    private var audiobookshelf: [UUID: AudiobookshelfKit.TokenSession] = [:]
    private var catalogues: [UUID: OwnAudioCatalogue] = [:]
    private let store: ServerStore?

    public init(store: ServerStore?) {
        self.store = store
    }

    func ownAudioSession(for serverId: UUID, tokens: OwnAudioKit.Tokens?) -> OwnAudioKit.TokenSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = ownAudio[serverId] { return existing }
        let made = OwnAudioKit.TokenSession(tokens, keeper: store.map { StoredOwnAudioTokens(store: $0, serverId: serverId) })
        ownAudio[serverId] = made
        return made
    }

    func audiobookshelfSession(for serverId: UUID, tokens: AudiobookshelfKit.Tokens?) -> AudiobookshelfKit.TokenSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = audiobookshelf[serverId] { return existing }
        let made = AudiobookshelfKit.TokenSession(tokens, keeper: store.map { StoredAudiobookshelfTokens(store: $0, serverId: serverId) })
        audiobookshelf[serverId] = made
        return made
    }

    func catalogue(for serverId: UUID) -> OwnAudioCatalogue {
        lock.lock()
        defer { lock.unlock() }
        if let existing = catalogues[serverId] { return existing }
        let made = OwnAudioCatalogue()
        catalogues[serverId] = made
        return made
    }

    /// Forgets a server's session, when it is removed or signed in again.
    public func forget(_ serverId: UUID) {
        lock.lock()
        ownAudio[serverId] = nil
        audiobookshelf[serverId] = nil
        catalogues[serverId] = nil
        lock.unlock()
    }
}

/// The app's saved answers, for the kits (each keeps its own protocol so it needs nothing
/// beyond Foundation).
struct SavedAnswers: OwnAudioKit.AnswerCache, AudiobookshelfKit.AnswerCache {
    let cache: ResponseCache

    func data(forKey key: String) -> Data? { cache.data(forKey: key) }
    func store(_ data: Data, forKey key: String) { cache.store(data, forKey: key) }
}

struct StoredOwnAudioTokens: OwnAudioKit.TokenKeeper {
    let store: ServerStore
    let serverId: UUID

    func save(_ tokens: OwnAudioKit.Tokens?) async {
        await store.updateTokens(serverId: serverId, ownAudio: tokens)
    }
}

struct StoredAudiobookshelfTokens: AudiobookshelfKit.TokenKeeper {
    let store: ServerStore
    let serverId: UUID

    func save(_ tokens: AudiobookshelfKit.Tokens?) async {
        await store.updateTokens(serverId: serverId, audiobookshelf: tokens)
    }
}

extension ServerRecord {
    /// The source for this server, reached at `address` (the one it was added with unless
    /// another was chosen). Saved answers are filed under the server, not the address.
    public func makeSource(_ environment: SourceEnvironment, address: URL? = nil) -> any BookSource {
        let url = address ?? host
        let offline = environment.offline
        switch auth {
        case .audiobookshelf(_, let tokens):
            let client = AudiobookshelfClient(
                host: url, tokens: environment.sessions.audiobookshelfSession(for: id, tokens: tokens), session: environment.urlSession,
                cache: environment.cache.map(SavedAnswers.init), cacheIdentity: id.uuidString,
                isOffline: { offline?.isOn == true }
            )
            return AudiobookshelfSource(client: client, libraryId: libraryId ?? "", userId: userId, device: environment.device)
        case .ownAudio(_, let tokens):
            let client = OwnAudioClient(
                host: url, tokens: environment.sessions.ownAudioSession(for: id, tokens: tokens), session: environment.urlSession,
                cache: environment.cache.map(SavedAnswers.init), cacheIdentity: id.uuidString,
                isOffline: { offline?.isOn == true }
            )
            return OwnAudioSource(client: client, userId: userId, device: environment.device, catalogue: environment.sessions.catalogue(for: id))
        }
    }
}
