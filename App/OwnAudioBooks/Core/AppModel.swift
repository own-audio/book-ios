import BookLibrary
import Foundation
import OSLog
import Observation
import PlayerCore
import SpokenEngine
import UIKit

/// The app's state: the servers and their sources, the active one, the engine and what it is
/// playing, the listener's settings, and the plumbing between them — positions written to disk
/// first and then sent, catalogues synced, addresses chosen.
@Observable
@MainActor
final class AppModel {
    static let shared = AppModel()

    private(set) var hasLoaded = false
    private(set) var servers: [ServerRecord] = []
    var activeServerId: UUID? {
        didSet {
            UserDefaults.standard.set(activeServerId?.uuidString, forKey: Self.activeServerKey)
            followLibraryChanges()
        }
    }
    /// Something the listener asked for failed; shown once, then cleared.
    var actionError: String?
    /// Servers whose sign-in the server refused since launch: shown on the server, fixed by
    /// signing in again.
    private(set) var signInRefused: Set<UUID> = []

    let engine: SpokenEngine
    let nowPlaying = NowPlayingController()
    let settings = PlaybackSettings()
    let covers = CoverLoader()
    let network = NetworkMonitor()
    let downloads = DownloadManager()
    let imports = ImportManager()
    /// The book in the engine, with the server it came from.
    private(set) var nowPlayingBook: Book?
    private(set) var nowPlayingServerId: UUID?
    /// The book in the player when the app last went away, shown in the mini player until it is
    /// played again; nil while a book is loaded.
    private(set) var lastBook: LastBook?
    /// Each Audiobookshelf server's own icon, once loaded (`loadServerIcons`).
    var serverIcons: [UUID: UIImage] = [:]
    /// Each server's favourite books (own.audio), for the badge on covers and the filter.
    var favouriteBooks: [UUID: Set<String>] = [:]
    private(set) var nowPlayingPlan: PlayPlan?
    /// Positions the app knows, by composite id, for the screens; the server's answer wins.
    private(set) var progress: [String: ListeningProgress] = [:]
    private(set) var catalogueSyncing: Set<UUID> = []

    private static let activeServerKey = "activeServerId"
    private let store = ServerStore()
    private let sessions: TokenSessions
    private var sources: [UUID: any BookSource] = [:]
    private let responseCache = DiskResponseCache()
    private let offlineSwitch = OfflineSwitch()
    private let catalogueStore = CatalogueStore()
    /// Positions on their way to the servers; see `ProgressReporter` for when they are sent.
    private let reporter = ProgressReporter(pending: PendingProgress())
    private var pendingProgress: PendingProgress { reporter.pending }
    private let knownPositions = KnownPositions()
    private let resumeStore = CheckpointedResumeStore(UserDefaultsResumeStore(key: "books.resume"))
    /// Files of books being streamed, kept as they are heard (Wi-Fi only, up to a gigabyte, the
    /// oldest let go first), so the next part starts from disk and a book heard once again needs
    /// no network. Separate from the listener's downloads, which it never counts as.
    private(set) var listeningCache: TrackFileCache!
    static let listeningCacheCapBytes: Int64 = 1 << 30
    nonisolated static let cacheLog = Logger(subsystem: "audio.own.bookplayer", category: "listeningCache")
    private var listeningCacheTask: Task<Void, Never>?
    /// The next minutes of a streamed book, on disk (`StreamWindow`); shares the listening
    /// cache's cap.
    let streamWindow = StreamWindow(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("listening-window", isDirectory: true),
        session: AppModel.session
    )
    let narrations = NarrationManager()
    private var loadTask: Task<Void, Never>?
    private var liveUpdates: Task<Void, Never>?
    /// False until a window scene is active: CarPlay, a background download or a refresh can
    /// start the app with no screen, and then no event stream or polling is opened.
    private(set) var isInForeground = false
    @ObservationIgnored private let networkDebounce = Debouncer(delay: .seconds(3))
    /// A network change came while in the background; the addresses are chosen on return.
    private var addressesStale = false

    /// The hosted service's edge refuses requests with no User-Agent.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": "own.audio Books/\(appVersion) iOS"]
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// This device as servers see it; the id is made once and kept.
    static let device: DeviceIdentity = {
        let key = "deviceId"
        let id = UserDefaults.standard.string(forKey: key) ?? {
            let made = UUID().uuidString
            UserDefaults.standard.set(made, forKey: key)
            return made
        }()
        return DeviceIdentity(id: id, name: UIDevice.current.name, model: UIDevice.current.model, appVersion: appVersion, systemVersion: UIDevice.current.systemVersion)
    }()

    private init() {
        sessions = TokenSessions(store: store)
        engine = SpokenEngine(nowPlaying: nowPlaying, resumeStore: resumeStore)
        engine.onPosition = { [weak self] position in self?.positionReported(position) }
        engine.onFinished = { [weak self] _ in self?.nowPlayingPlan = nil }
        engine.artworkProvider = { [weak self] compositeId in
            await self?.coverImage(compositeId: compositeId, size: 600)
        }
        engine.partRefresher = { [weak self] compositeId, partId in
            guard let self, let (serverId, bookId) = BookID.parse(compositeId) else { throw SourceError.notFound }
            return try await self.freshPartURL(serverId: serverId, bookId: bookId, partId: partId)
        }
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("listening-cache", isDirectory: true)
        listeningCache = TrackFileCache(remoteURL: { [weak self] key in
            guard let self, let (compositeId, fileId) = Self.splitCacheKey(key), let (serverId, bookId) = BookID.parse(compositeId),
                  let source = await self.sources[serverId] else { throw SourceError.notFound }
            // Always the original file, as a download would be.
            let book = await self.nowPlayingBook?.id == bookId ? await self.nowPlayingBook! : try await source.book(id: bookId)
            return try await source.partURL(for: book, fileId: fileId, startMs: nil, maxBitrateKbps: nil).url
        }, session: Self.session, cacheDirectory: cachesDirectory)
        engine.window = streamWindow
        engine.partLocator = { [weak self] compositeId, partId in
            guard let self else { return nil }
            let local = await self.partLocator.locate(compositeId: compositeId, fileId: partId).localURL
            // The chain goes on whether this part was on the phone or not.
            await self.cacheFollowingParts()
            return local
        }
        downloads.onFileReady = { [weak self] compositeId, fileId, url in
            guard let self, self.engine.book?.id == compositeId else { return }
            self.engine.useLocalCopy(partId: fileId, at: url)
        }
        downloads.urlProvider = { [weak self] compositeId, fileId in
            guard let self, let (serverId, _) = BookID.parse(compositeId), let source = self.sources[serverId],
                  let book = self.downloads.books[compositeId]?.book else { throw SourceError.notFound }
            // Downloads are always the original file.
            return try await source.partURL(for: book, fileId: fileId, startMs: nil, maxBitrateKbps: nil).url
        }
        imports.uploaderProvider = { [weak self] serverId in self?.sources[serverId] as? any BookUploader }
        narrations.narratorProvider = { [weak self] serverId in self?.sources[serverId] as? any BookNarrator }
        narrations.onCompleted = { [weak self] _ in Task { await self?.syncCatalogues() } }
        reporter.send = { [weak self] entry in
            guard let self, let source = self.sources[entry.serverId] else { throw ProgressReporter.NoServer() }
            return try await source.report(PlaybackReport(
                bookId: entry.bookId, sessionId: entry.sessionId, positionMs: entry.positionMs, listenedMs: entry.listenedMs,
                durationMs: entry.durationMs, finished: entry.finished, at: entry.at, closes: entry.closes
            ))
        }
        reporter.onAnswer = { [weak self] entry, answer in
            guard let self else { return }
            let composite = BookID.make(serverId: entry.serverId, bookId: entry.bookId)
            if let answer, self.engine.book?.id != composite { self.progress[composite] = answer }
        }
        reporter.onSignInRefused = { [weak self] serverId in self?.signInRefused.insert(serverId) }
        applyPlaybackSettings()
        followWidgetTriggers()
        network.onChange = { [weak self] connected in
            // Lost: the player is told at once, so a stalled stream waits rather than fails.
            // Back: once it has settled.
            if !connected { self?.engine.networkChanged(isConnected: false) }
            self?.networkDebounce.schedule { [weak self] in await self?.networkSettled() }
        }
    }

    // MARK: - Servers

    var serversInOrder: [ServerRecord] { servers.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending } }
    var activeServer: ServerRecord? { servers.first { $0.id == activeServerId } }
    var activeSource: (any BookSource)? { activeServerId.flatMap { sources[$0] } }
    var capabilities: Capabilities { activeSource?.capabilities ?? [] }

    func source(for serverId: UUID) -> (any BookSource)? { sources[serverId] }
    func server(_ id: UUID) -> ServerRecord? { servers.first { $0.id == id } }

    /// No network, or the listener's choice on mobile data: the screens show downloads only
    /// (B6) and nothing is asked of the servers.
    var isOffline: Bool {
        !network.isConnected || settings.offlineMode || (network.isExpensive && settings.mobileData == .downloadedOnly) || Self.isSimulatingOffline
    }

    /// Offline by the listener's choice rather than the network's.
    var isOfflineByChoice: Bool {
        network.isConnected && !Self.isSimulatingOffline && (settings.offlineMode || (network.isExpensive && settings.mobileData == .downloadedOnly))
    }

    func setOfflineMode(_ on: Bool) {
        settings.offlineMode = on
        offlineSwitch.isOn = isOffline
        followLibraryChanges()
        if !on { Task { await chooseAddresses(); await syncCatalogues(); await flushPendingProgress() } }
    }

    static var isSimulatingOffline: Bool { ProcessInfo.processInfo.arguments.contains("-simulateOffline") }

    /// A smaller stream on mobile data when the listener asked for one.
    var maxBitrateKbps: Int? {
        (network.isExpensive || network.isConstrained || ProcessInfo.processInfo.arguments.contains("-simulateMobileData")) && settings.mobileData == .saver
            ? PlaybackSettings.saverBitrateKbps : nil
    }

    func load() async {
        if let loadTask { return await loadTask.value }
        let task = Task { await performLoad() }
        loadTask = task
        await task.value
    }

    private func performLoad() async {
        // UI tests start from a clean slate; the Keychain survives reinstalling the app.
        if ProcessInfo.processInfo.arguments.contains("-uiTestReset") {
            await store.clear()
            UserDefaults.standard.removeObject(forKey: Self.activeServerKey)
            UserDefaults.standard.removeObject(forKey: "books.resume")
            await covers.clear()
            responseCache.removeAll()
            catalogueStore.removeAll()
            pendingProgress.removeAll()
            knownPositions.removeAll()
            downloads.removeAll()
            for item in imports.imports.values { imports.cancel(item.id) }
            settings.offlineMode = false
            forgetLastBook()
        }
        lastBook = LastBook.load()
        recoverUnsavedPositions()
        servers = await store.loadAll()
        await addServerFromLaunchArguments()
        for server in servers where server.kind == .ownAudio {
            if let state = catalogueStore.load(serverId: server.id) { sessions.catalogue(for: server.id).restore(state) }
        }
        offlineSwitch.isOn = isOffline
        await rebuildClients()
        let saved = UserDefaults.standard.string(forKey: Self.activeServerKey).flatMap(UUID.init)
        activeServerId = servers.contains { $0.id == saved } ? saved : servers.first?.id
        hasLoaded = true
        followLibraryChanges()
        Task { await refreshModules() }
        if isInForeground { narrations.startPolling() }
        downloads.resume()
        imports.resume()
        keepProgressFresh()
        Task {
            await chooseAddresses()
            await loadServerIcons()
            await refreshBookLibraries()
            await syncCatalogues()
            await flushPendingProgress()
        }
    }

    /// A server to add from the launch arguments, for the UI tests and development:
    /// `-debugServerHost`, `-debugServerUser`, `-debugServerPassword`.
    private func addServerFromLaunchArguments() async {
        #if DEBUG
        let defaults = UserDefaults.standard
        guard let address = defaults.string(forKey: "debugServerHost"),
              let username = defaults.string(forKey: "debugServerUser"),
              let password = defaults.string(forKey: "debugServerPassword")
        else { return }
        guard !servers.contains(where: { $0.auth.username == username && Self.sameHost($0.host, address) }) else { return }
        try? await addServer(address: address, username: username, password: password, name: defaults.string(forKey: "debugServerName") ?? "")
        #endif
    }

    private static func sameHost(_ url: URL, _ typed: String) -> Bool {
        typed.contains(url.host() ?? "\u{0}")
    }

    /// Finds out what is at `address` and signs in before anything is saved, so a typo is
    /// caught here. An own.audio server answers its discovery document; otherwise the address
    /// is tried as Audiobookshelf. Without a scheme, https first and then http.
    func addServer(address: String, username: String, password: String, name: String) async throws {
        var lastError: Error = AddServerError.unreachable
        for host in Self.candidateHosts(address) {
            do {
                let record = try await signIn(host: host, username: username, password: password, name: name)
                try await save(record)
                return
            } catch AddServerError.rejected {
                throw AddServerError.rejected
            } catch let error as AddServerError where error.isFinal {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func signIn(host: URL, username: String, password: String, name: String) async throws -> ServerRecord {
        if let info = try? await ServerSetup.ownAudioInfo(at: host, urlSession: Self.session) {
            guard info.speaksV2 else { throw AddServerError.serverTooOld }
            let result: ServerSetup.OwnAudioSignInResult
            do {
                result = try await ServerSetup.ownAudioSignIn(host: host, email: username, password: password, device: Self.device, urlSession: Self.session)
            } catch SourceError.signInRejected {
                throw AddServerError.rejected
            } catch SourceError.network {
                throw AddServerError.unreachable
            } catch SourceError.server(let message) {
                throw AddServerError.server(message)
            }
            switch result {
            case .signedIn(var record):
                record.displayName = Self.displayName(name, fallback: record.displayName)
                return record
            case .twoFactor(let mfaToken, let methods):
                pendingTwoFactor = PendingTwoFactor(host: host, mfaToken: mfaToken, methods: methods, name: name)
                throw AddServerError.twoFactorNeeded
            }
        }
        do {
            var signIn = try await ServerSetup.audiobookshelfSignIn(host: host, username: username, password: password, urlSession: Self.session)
            signIn.record.displayName = Self.displayName(name, fallback: host.host() ?? "Audiobookshelf")
            audiobookshelfLibraries[signIn.record.id] = signIn.libraries
            return signIn.record
        } catch SourceError.signInRejected {
            throw AddServerError.rejected
        } catch SourceError.unsupported {
            throw AddServerError.noBookLibrary
        } catch SourceError.network {
            throw AddServerError.unreachable
        } catch {
            throw AddServerError.notAServer
        }
    }

    /// The typed address as URLs to try: as typed with a scheme, else https then http.
    static func candidateHosts(_ typed: String) -> [URL] {
        var text = ServerSetup.ownAudioAPIAddress(typed)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return [] }
        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            return [URL(string: text)].compactMap { $0 }
        }
        return [URL(string: "https://\(text)"), URL(string: "http://\(text)")].compactMap { $0 }
    }

    private static func displayName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Audiobookshelf accounts may reach several book libraries; the record shows one.
    private(set) var audiobookshelfLibraries: [UUID: [(id: String, name: String)]] = [:]

    func bookLibraries(serverId: UUID) async -> [(id: String, name: String)] {
        if let known = audiobookshelfLibraries[serverId] { return known }
        guard let source = sources[serverId] as? AudiobookshelfSource,
              let libraries = try? await source.client.bookLibraries() else {
            return server(serverId)?.libraries?.map { ($0.id, $0.name) } ?? []
        }
        let list: [(id: String, name: String)] = libraries.map { ($0.id, $0.name) }
        audiobookshelfLibraries[serverId] = list
        // Kept on the record, so the Home switch can name them offline.
        let refs = list.map { ServerLibraryRef(id: $0.id, name: $0.name) }
        if var record = server(serverId), record.libraries != refs {
            record.libraries = refs
            try? await store.update(record)
            if let index = servers.firstIndex(where: { $0.id == serverId }) { servers[index] = record }
        }
        return list
    }

    /// Every Audiobookshelf server's book libraries, read again (at launch).
    func refreshBookLibraries() async {
        guard !isOffline else { return }
        for record in servers where record.kind == .audiobookshelf {
            audiobookshelfLibraries[record.id] = nil
            _ = await bookLibraries(serverId: record.id)
        }
    }

    /// The Home switch's choice: a server, and on an Audiobookshelf account with several book
    /// libraries, one of them.
    func select(serverId: UUID, libraryId: String?) async {
        selectServer(id: serverId)
        if let libraryId, server(serverId)?.libraryId != libraryId {
            try? await setLibrary(serverId: serverId, libraryId: libraryId)
        }
    }

    func setLibrary(serverId: UUID, libraryId: String) async throws {
        guard var record = server(serverId) else { return }
        record.libraryId = libraryId
        try await update(record)
    }

    // MARK: Sign in with Apple and Google

    enum OwnAudioSignIn {
        /// Sign in with Apple: the identity token, and the name Apple gives only the first time.
        case apple(identityToken: String, fullName: String?)
        /// Google: the ID token for this app's iOS client.
        case google(idToken: String)

        var provider: String {
            switch self {
            case .apple: "apple"
            case .google: "google"
            }
        }
    }

    /// An own.audio server added with Apple or Google: the server exchanges the provider's
    /// token for its own.
    func addOwnAudioServer(address: String, signIn: OwnAudioSignIn, name: String) async throws {
        guard let host = Self.candidateHosts(address).first else { throw AddServerError.unreachable }
        let record = try await ownAudioSignIn(host: host, signIn: signIn, name: name)
        try await save(record)
    }

    private func ownAudioSignIn(host: URL, signIn: OwnAudioSignIn, name: String) async throws -> ServerRecord {
        let (idToken, fullName): (String, String?) = switch signIn {
        case .apple(let token, let fullName): (token, fullName)
        case .google(let token): (token, nil)
        }
        let result: ServerSetup.OwnAudioSignInResult
        do {
            result = try await ServerSetup.ownAudioSignIn(host: host, provider: signIn.provider, idToken: idToken, fullName: fullName, device: Self.device, urlSession: Self.session)
        } catch SourceError.signInRejected {
            throw AddServerError.rejected
        } catch SourceError.network {
            throw AddServerError.unreachable
        } catch SourceError.server(let message) {
            throw AddServerError.server(message)
        }
        switch result {
        case .signedIn(var record):
            record.displayName = Self.displayName(name, fallback: record.displayName)
            return record
        case .twoFactor(let mfaToken, let methods):
            pendingTwoFactor = PendingTwoFactor(host: host, mfaToken: mfaToken, methods: methods, name: name)
            throw AddServerError.twoFactorNeeded
        }
    }

    /// The same account signed in again with Apple or Google.
    func signInAgain(serverId: UUID, with signIn: OwnAudioSignIn) async throws {
        guard let existing = server(serverId) else { return }
        do {
            var record = try await ownAudioSignIn(host: existing.host, signIn: signIn, name: existing.displayName)
            record.displayName = existing.displayName
            try await replaceSignIn(of: serverId, with: record)
        } catch AddServerError.twoFactorNeeded {
            pendingTwoFactor?.replacing = serverId
            throw AddServerError.twoFactorNeeded
        }
    }

    /// Which providers the own.audio server at `address` offers, so only their buttons show;
    /// none for any other address.
    func ownAudioProviders(address: String) async -> Set<String> {
        for host in Self.candidateHosts(address) {
            if let info = try? await ServerSetup.ownAudioInfo(at: host, urlSession: Self.raceSession) {
                return Set(info.providers)
            }
        }
        return []
    }

    // MARK: Devices (own.audio sessions)

    func sessions(serverId: UUID) async throws -> [DeviceSession] {
        guard let source = sources[serverId] as? OwnAudioSource else { throw SourceError.unsupported }
        return try await source.sessions()
    }

    func revokeSession(serverId: UUID, id: String) async throws {
        guard let source = sources[serverId] as? OwnAudioSource else { throw SourceError.unsupported }
        try await source.revokeSession(id: id)
    }

    /// Every device out, this one included: the server then needs a fresh sign-in.
    func signOutEverywhere(serverId: UUID) async throws {
        guard let source = sources[serverId] as? OwnAudioSource else { throw SourceError.unsupported }
        try await source.signOutEverywhere()
        signInRefused.insert(serverId)
    }

    // MARK: Two-factor and signing in again

    struct PendingTwoFactor: Identifiable {
        let id = UUID()
        let host: URL
        let mfaToken: String
        let methods: [String]
        let name: String
        var replacing: UUID?
    }

    var pendingTwoFactor: PendingTwoFactor?

    func finishTwoFactor(code: String) async throws {
        guard let pending = pendingTwoFactor else { return }
        var record: ServerRecord
        do {
            record = try await ServerSetup.ownAudioFinishTwoFactor(host: pending.host, mfaToken: pending.mfaToken, code: code, urlSession: Self.session)
        } catch SourceError.signInRejected {
            throw AddServerError.wrongCode
        }
        pendingTwoFactor = nil
        if let replacing = pending.replacing {
            try await replaceSignIn(of: replacing, with: record)
        } else {
            record.displayName = Self.displayName(pending.name, fallback: record.displayName)
            try await save(record)
        }
    }

    func cancelTwoFactor() {
        pendingTwoFactor = nil
    }

    /// A server whose sign-in was refused: the same account signed in again, the record kept.
    func signInAgain(serverId: UUID, username: String, password: String) async throws {
        guard let existing = server(serverId) else { return }
        do {
            var record = try await signIn(host: existing.host, username: username, password: password, name: existing.displayName)
            record.displayName = existing.displayName
            try await replaceSignIn(of: serverId, with: record)
        } catch AddServerError.twoFactorNeeded {
            pendingTwoFactor?.replacing = serverId
            throw AddServerError.twoFactorNeeded
        }
    }

    private func replaceSignIn(of id: UUID, with fresh: ServerRecord) async throws {
        guard var record = server(id) else { return }
        record.auth = fresh.auth
        record.userId = fresh.userId
        record.serverId = fresh.serverId ?? record.serverId
        if record.kind == .audiobookshelf, record.libraryId == nil { record.libraryId = fresh.libraryId }
        sessions.forget(id)
        signInRefused.remove(id)
        try await update(record)
    }

    /// The public demo: a shared own.audio server with sample books.
    static let demoHost = URL(string: "https://demopi.own.audio")!

    func addDemoServer() async throws {
        let account: (email: String, password: String)
        do {
            account = try await ServerSetup.ownAudioDemoAccount(host: Self.demoHost, urlSession: Self.session)
        } catch {
            throw AddServerError.unreachable
        }
        try await addServer(address: Self.demoHost.absoluteString, username: account.email, password: account.password, name: "own.audio demo")
    }

    private func save(_ record: ServerRecord) async throws {
        try await store.add(record)
        servers.append(record)
        await rebuildClients()
        activeServerId = record.id
        Task {
            await chooseAddresses()
            await loadServerIcons()
            await syncCatalogues()
        }
    }

    func removeServer(id: UUID) async throws {
        if nowPlayingServerId == id { engine.stop(); nowPlayingBook = nil; nowPlayingPlan = nil }
        if let source = sources[id] { await source.signOut() }
        try await store.remove(id: id)
        servers.removeAll { $0.id == id }
        sessions.forget(id)
        catalogueStore.remove(serverId: id)
        await rebuildClients()
        if activeServerId == id { activeServerId = servers.first?.id }
    }

    func renameServer(id: UUID, to name: String) async throws {
        try await store.rename(id: id, to: name)
        if let index = servers.firstIndex(where: { $0.id == id }) { servers[index].displayName = name }
    }

    func selectServer(id: UUID) {
        activeServerId = id
    }

    func checkConnection(id: UUID) async -> ConnectionStatus {
        guard let source = sources[id] else { return .unreachable }
        let status = await source.checkConnection()
        if status == .rejected { signInRefused.insert(id) } else if status == .ok { signInRefused.remove(id) }
        return status
    }

    /// Saves a changed server (addresses, connection mode, library) and uses it at once.
    func update(_ record: ServerRecord) async throws {
        try await store.update(record)
        if let index = servers.firstIndex(where: { $0.id == record.id }) { servers[index] = record }
        if case .fixed(let url) = record.connection {
            activeAddresses[record.id] = url
        } else if let active = activeAddresses[record.id], !record.candidateAddresses.contains(where: { $0.url == active }) {
            activeAddresses[record.id] = nil
        }
        await rebuildClients()
    }

    private var sourceEnvironment: SourceEnvironment {
        SourceEnvironment(urlSession: Self.session, cache: responseCache, offline: offlineSwitch, device: Self.device, sessions: sessions)
    }

    private func rebuildClients() async {
        let environment = sourceEnvironment
        sources = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0.makeSource(environment, address: activeAddresses[$0.id])) })
        followLibraryChanges()
        // A server added or re-addressed after launch: what it offers is asked again.
        Task { await refreshModules() }
    }

    // MARK: - Connections

    enum ConnectionState: Equatable {
        case checking
        case connected(URL)
        case unreachable
    }

    /// The address each server is reached at right now, where it isn't the one it was added with.
    private(set) var activeAddresses: [UUID: URL] = [:]
    private(set) var connectionStates: [UUID: ConnectionState] = [:]
    private var choosing: Task<Void, Never>?

    /// For racing addresses: a wrong one must not hold the right one up.
    private static let raceSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": "own.audio Books/\(appVersion) iOS"]
        configuration.timeoutIntervalForRequest = 4
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Picks each server's address for the network the phone is on now: the fixed one where
    /// the listener chose one, otherwise every known address tried at once and the fastest
    /// that answers as the same server kept, remembered for this network.
    func chooseAddresses() async {
        if let choosing { return await choosing.value }
        let task = Task { await performChooseAddresses() }
        choosing = task
        await task.value
        choosing = nil
    }

    private func performChooseAddresses() async {
        offlineSwitch.isOn = isOffline
        guard !isOffline else { return }
        let network = network.signature
        var changed = false
        for record in servers {
            if case .fixed(let url) = record.connection {
                changed = changed || activeAddresses[record.id] != url
                activeAddresses[record.id] = url
                connectionStates[record.id] = .connected(url)
                continue
            }
            let candidates = record.candidateAddresses.map(\.url)
            guard candidates.count > 1 || record.serverId != nil else {
                connectionStates[record.id] = .connected(record.host)
                continue
            }
            let rememberedKey = "address.\(record.id.uuidString).\(network)"
            if let remembered = UserDefaults.standard.string(forKey: rememberedKey).flatMap(URL.init(string:)),
               candidates.contains(remembered), activeAddresses[record.id] != remembered {
                activeAddresses[record.id] = remembered
                changed = true
            }
            if connectionStates[record.id] == nil { connectionStates[record.id] = .checking }
            guard let won = await ServerSetup.race(record, candidates: candidates, expectedId: record.serverId, urlSession: Self.raceSession) else {
                connectionStates[record.id] = .unreachable
                continue
            }
            UserDefaults.standard.set(won.url.absoluteString, forKey: rememberedKey)
            connectionStates[record.id] = .connected(won.url)
            if activeAddresses[record.id] != won.url {
                activeAddresses[record.id] = won.url
                changed = true
            }
            var updated = record
            updated.learn(won.addresses)
            if let id = won.serverId { updated.serverId = id }
            if updated != record { try? await update(updated) }
        }
        if changed { await rebuildClients() }
    }

    // MARK: - Catalogues (own.audio's library on the phone)

    func syncCatalogues() async {
        guard !isOffline else { return }
        for server in servers where server.kind == .ownAudio && server.auth.isSignedIn {
            await syncCatalogue(server.id)
        }
        await loadFavourites()
    }

    /// From the library copy on the phone (own.audio), so covers can wear the badge offline too.
    func loadFavourites() async {
        for server in servers {
            guard let source = sources[server.id], source.capabilities.contains(.favourites),
                  let ids = try? await source.favourites() else { continue }
            favouriteBooks[server.id] = ids
        }
    }

    func isFavourite(_ book: Book, serverId: UUID) -> Bool {
        favouriteBooks[serverId]?.contains(book.id) == true
    }

    func noteFavourite(_ book: Book, serverId: UUID, _ on: Bool) {
        if on { favouriteBooks[serverId, default: []].insert(book.id) } else { favouriteBooks[serverId]?.remove(book.id) }
    }

    /// What the copy of an own.audio library on this phone holds; nil for other servers and
    /// before the first sync.
    func catalogueSummary(serverId: UUID) -> (books: Int, authors: Int, syncedAt: Date?)? {
        guard sources[serverId] is any ChangeFeedCatalogue else { return nil }
        return sessions.catalogue(for: serverId).summary
    }

    /// Settings → Servers → ⓘ → Update Now.
    func updateCatalogue(_ id: UUID) async {
        await syncCatalogue(id)
    }

    /// After joining another household: the saved feed is dropped and the library fetched
    /// from a fresh snapshot.
    func resyncCatalogue(_ id: UUID) async {
        catalogueStore.remove(serverId: id)
        sessions.catalogue(for: id).reset()
        await syncCatalogue(id)
    }

    private func syncCatalogue(_ id: UUID) async {
        guard let feed = sources[id] as? any ChangeFeedCatalogue, !catalogueSyncing.contains(id) else { return }
        catalogueSyncing.insert(id)
        defer { catalogueSyncing.remove(id) }
        do {
            let result = try await feed.syncCatalogue(sessions.catalogue(for: id).state)
            catalogueStore.save(result.state, serverId: id)
            for (bookId, p) in result.progress { progress[BookID.make(serverId: id, bookId: bookId)] = p }
            signInRefused.remove(id)
        } catch SourceError.signInRejected {
            signInRefused.insert(id)
        } catch {}
    }

    /// A network change, three seconds after the last path update (`NetworkChangeWork`).
    private func networkSettled() async {
        offlineSwitch.isOn = isOffline
        applyLookAhead()
        // A book waiting for a signal plays on (the link renewed if it has to be).
        engine.networkChanged(isConnected: network.isConnected && !Self.isSimulatingOffline)
        let work = NetworkChangeWork.after(inForeground: isInForeground)
        if work.chooseAddresses { await chooseAddresses() } else { addressesStale = true }
        if work.flushProgress { await flushPendingProgress() }
    }

    func sceneBecame(active: Bool) {
        guard isInForeground != active else { return }
        isInForeground = active
        followLibraryChanges()
        if active {
            narrations.startPolling()
            Task {
                if addressesStale {
                    addressesStale = false
                    await chooseAddresses()
                }
                await syncCatalogues()
                await flushPendingProgress()
                await refreshProgress()
            }
        } else {
            narrations.stopPolling()
            BackgroundRefresh.schedule()
        }
    }

    private var progressRefresh: Task<Void, Never>?

    /// Positions made elsewhere, from the active server: at foreground, and every few minutes
    /// while a book plays with the app in front (own.audio's feed brings them too;
    /// Audiobookshelf has no feed).
    func refreshProgress() async {
        guard !isOffline, let id = activeServerId, let source = sources[id], let all = try? await source.allProgress() else { return }
        for (bookId, p) in all {
            let composite = BookID.make(serverId: id, bookId: bookId)
            if engine.book?.id != composite { progress[composite] = p }
        }
    }

    private func keepProgressFresh() {
        progressRefresh?.cancel()
        progressRefresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(180))
                // In the background nobody sees the screens these positions are for.
                guard !Task.isCancelled, let self, self.engine.isPlaying, self.isInForeground else { continue }
                await self.refreshProgress()
            }
        }
    }

    /// Follows the active own.audio server's events while on screen; the stream ends with the
    /// connection, so it is reopened, waiting longer after each failure.
    private func followLibraryChanges() {
        liveUpdates?.cancel()
        liveUpdates = nil
        guard hasLoaded, isInForeground, !isOffline, !network.isConstrained,
              let id = activeServerId, let source = sources[id] as? any LiveLibraryUpdates,
              server(id)?.auth.isSignedIn == true
        else { return }
        liveUpdates = Task { [weak self] in
            var wait: Duration = .seconds(2)
            while !Task.isCancelled {
                do {
                    for try await _ in source.libraryChanges() {
                        wait = .seconds(2)
                        await self?.syncCatalogue(id)
                    }
                } catch SourceError.signInRejected {
                    self?.signInRefused.insert(id)
                    return
                } catch {}
                try? await Task.sleep(for: wait)
                wait = min(wait * 2, .seconds(120))
            }
        }
    }

    // MARK: - Playing

    /// Another device went on with the book since this phone last saved: the listener picks
    /// where to start.
    struct PendingResume: Identifiable {
        let id = UUID()
        let book: Book
        let serverId: UUID
        let localMs: Int64
        let otherMs: Int64
        let otherDevice: String?
    }

    var pendingResume: PendingResume?

    /// Starts `book` where the listener left it: the server's position, else the one this phone
    /// remembers, else the start (and the start again for a finished book). When the server's
    /// position is another device's and far from this phone's, the listener is asked first;
    /// `startAt` is their answer.
    func play(_ book: Book, serverId: UUID, startAt: Int64? = nil) async {
        guard let source = sources[serverId] else { return }
        let composite = BookID.make(serverId: serverId, bookId: book.id)
        do {
            let detail: Book
            let parts: [SpokenPart]
            var plan: PlayPlan?
            let record = downloads.books[composite]
            if record != nil { downloads.notePlayed(composite) }
            if let local = downloads.downloaded(composite) {
                // From the phone: the files as downloaded, the record as it was.
                detail = local.book
                parts = await partLocator.parts(compositeId: composite, files: (detail.files ?? []).map { ($0.id, $0.durationMs) }, streams: nil)
            } else if isOffline {
                // What is on the phone plays — a partly downloaded book, files heard before; a
                // file that is not waits for the network.
                let known = record?.book ?? book
                let files = (known.files ?? []).map { (id: $0.id, durationMs: $0.durationMs) }
                let offlineParts = await partLocator.parts(compositeId: composite, files: files, streams: nil)
                guard offlineParts.contains(where: { !$0.isUnresolved }) else {
                    actionError = String(localized: "This book is not on this iPhone. Download it, or turn Offline Mode off.")
                    return
                }
                detail = known
                parts = offlineParts
            } else {
                detail = book.files == nil ? try await source.book(id: book.id) : book
                let made = try await source.playPlan(for: detail, maxBitrateKbps: maxBitrateKbps)
                plan = made
                parts = await partLocator.parts(compositeId: composite, files: [], streams: made.parts, original: maxBitrateKbps == nil)
            }
            let serverProgress = isOffline ? progress[composite] : try? await source.progress(bookId: book.id)
            if let serverProgress { progress[composite] = serverProgress }
            if startAt == nil, !isOffline, let known = knownPositions[composite] {
                let local = ListeningProgress(positionMs: known.positionMs, finished: known.finished, updatedAt: known.at)
                if case .ask(let localMs, let otherMs, let device) = ResumeChoice.decide(local: local, server: serverProgress) {
                    pendingResume = PendingResume(book: detail, serverId: serverId, localMs: localMs, otherMs: otherMs, otherDevice: device)
                    return
                }
            }
            let chapters = await chapters(for: detail, parts: parts)
            let spoken = SpokenBook(id: composite, title: detail.title, author: detail.authorLine.isEmpty ? nil : detail.authorLine, parts: parts, chapters: chapters, linksExpireAt: plan?.expiresAt)
            let start: Int64
            if let startAt {
                start = startAt
            } else if let serverProgress, !serverProgress.finished {
                start = serverProgress.positionMs
            } else if let local = resumeStore.loadResume(containerId: composite), serverProgress?.finished != true {
                start = Int64(local.positionSecs * 1000)
            } else {
                start = plan?.startPositionMs ?? 0
            }
            nowPlayingBook = detail
            nowPlayingServerId = serverId
            nowPlayingPlan = plan
            applyPlaybackSettings()
            engine.setRate(settings.rate(for: composite))
            engine.load(spoken, at: start, autoplay: true)
            scheduleListeningCache(for: spoken)
            lastBook = nil
            LastBook(serverId: serverId, book: detail, positionMs: start, durationMs: spoken.timeline.durationMs).save()
        } catch {
            actionError = (error as? SourceError)?.userMessage ?? error.localizedDescription
        }
    }

    /// The server's chapters; else the files' own marks, read on the phone; else one per file.
    private func chapters(for book: Book, parts: [SpokenPart]) async -> [SpokenChapter] {
        if let chapters = book.chapters, !chapters.isEmpty {
            return chapters.map { SpokenChapter(title: $0.title, startMs: $0.startMs, endMs: $0.endMs) }
        }
        // Reading marks from a stream costs a request per file; a few seconds at most.
        let embedded = await withTaskGroup(of: [SpokenChapter].self) { group -> [SpokenChapter] in
            group.addTask { await EmbeddedChapters.read(parts) }
            group.addTask { try? await Task.sleep(for: .seconds(6)); return [] }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
        if !embedded.isEmpty { return embedded }
        return BookTimeline.chaptersFromParts(parts, titles: book.files?.map { $0.title ?? "" })
    }

    func applyPlaybackSettings() {
        downloads.wifiOnly = settings.wifiOnlyDownloads
        downloads.enforce(capBytes: settings.storageCapBytes, protected: engine.book?.id)
        engine.skipForwardSecs = settings.skipForwardSecs
        engine.skipBackwardSecs = settings.skipBackwardSecs
        engine.smartRewind = SmartRewind(isEnabled: settings.smartRewind)
        applyLookAhead()
    }

    /// The window is the listener's choice, and the smallest with Low Data Mode on.
    private func applyLookAhead() {
        let minutes = network.isConstrained ? PlaybackSettings.constrainedLookAheadMinutes : settings.lookAheadMinutes
        streamWindow.lookAheadSecs = Double(minutes) * 60
    }

    func setRate(_ rate: Float) {
        engine.setRate(rate)
        if let book = engine.book { settings.remember(rate: engine.rate, for: book.id) }
    }

    // MARK: - The listening cache

    /// Downloads first, then the listening cache, then the stream; asked per file every time.
    var partLocator: PartLocator {
        let downloads = downloads
        let cache = listeningCache!
        return PartLocator(
            downloaded: { compositeId, fileId in downloads.fileURL(compositeId: compositeId, fileId: fileId) },
            cached: { compositeId, fileId in await cache.existingLocalURL(trackId: Self.cacheKey(compositeId, fileId)) }
        )
    }

    nonisolated static func cacheKey(_ compositeId: String, _ fileId: String) -> String { compositeId + "#" + fileId }

    nonisolated static func splitCacheKey(_ key: String) -> (compositeId: String, fileId: String)? {
        guard let hash = key.lastIndex(of: "#") else { return nil }
        return (String(key[..<hash]), String(key[key.index(after: hash)...]))
    }

    /// Streaming a book on Wi-Fi: the part after the one playing is fetched now, so it starts
    /// from disk; the one playing is fetched a little later, once the player has its own
    /// buffer, so the two never compete for a slow server at the start. HLS transcodes are made
    /// per listen and are not kept.
    private func scheduleListeningCache(for book: SpokenBook) {
        listeningCacheTask?.cancel()
        listeningCacheTask = nil
        Task { await enforceListeningCap(protecting: book) }
        guard !network.isExpensive, !network.isConstrained else { return }
        Task { await cacheFollowingParts() }
        listeningCacheTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard let self, !Task.isCancelled, self.engine.book?.id == book.id else { return }
            await self.cacheCurrentPart()
        }
    }

    /// The listening cache and the look-ahead window share one cap. The window's stretches go
    /// first (a few minutes each, quick to fetch again), then the oldest whole files; the book
    /// playing keeps its window.
    private func enforceListeningCap(protecting book: SpokenBook) async {
        let cap = Self.listeningCacheCapBytes
        let cacheBytes = await listeningCache.totalBytes()
        let window = streamWindow
        let keys = Set(book.timeline.parts.map { book.id + "#" + $0.id })
        let windowBytes = await Task.detached(priority: .utility) {
            window.enforce(capBytes: max(0, cap - cacheBytes), protecting: keys)
            return window.totalBytes()
        }.value
        await listeningCache.enforce(capBytes: max(0, cap - windowBytes))
    }

    /// The part after the one playing, if it streams and isn't cached yet.
    private func cacheFollowingParts() async {
        guard !network.isExpensive, !network.isConstrained, let book = engine.book,
              let (index, _) = book.timeline.locate(engine.positionMs), index + 1 < book.timeline.parts.count else { return }
        let next = book.timeline.parts[index + 1]
        guard !next.isHLS, !next.url.isFileURL else { return }
        if await listeningCache.existingLocalURL(trackId: Self.cacheKey(book.id, next.id)) == nil {
            Self.cacheLog.info("fetching the next part \(next.id, privacy: .public) ahead")
        }
        await listeningCache.prefetch(trackId: Self.cacheKey(book.id, next.id))
    }

    private func cacheCurrentPart() async {
        guard let book = engine.book, let (index, _) = book.timeline.locate(engine.positionMs) else { return }
        let part = book.timeline.parts[index]
        guard !part.isHLS, !part.url.isFileURL else { return }
        Self.cacheLog.info("fetching the part playing \(part.id, privacy: .public) for the cache")
        await listeningCache.prefetch(trackId: Self.cacheKey(book.id, part.id))
    }

    private func freshPartURL(serverId: UUID, bookId: String, partId: String) async throws -> URL {
        if isOfflineByChoice { throw PartNotOnPhone() }
        if isOffline { throw NoSignal() }
        guard let source = sources[serverId], let book = nowPlayingBook, book.id == bookId else { throw SourceError.notFound }
        // A part streaming through the look-ahead window stays the original file.
        let windowed = engine.book?.timeline.parts.first { $0.id == partId }?.streamsByRange ?? false
        let part = try await source.partURL(for: book, fileId: partId, startMs: nil, maxBitrateKbps: windowed ? nil : maxBitrateKbps)
        return part.url
    }

    var isNowPlaying: Bool { engine.book != nil }

    func canImport(serverId: UUID) -> Bool {
        sources[serverId] is any BookUploader && !isOffline
    }

    // MARK: - Narration (hosted own.audio servers)

    /// Servers whose discovery lists the `narration` module, asked once per launch.
    private(set) var narrationServers: Set<UUID> = []

    func canNarrate(serverId: UUID) -> Bool {
        narrationServers.contains(serverId) && sources[serverId] is any BookNarrator && !isOffline
    }

    func refreshModules() async {
        for server in servers where server.kind == .ownAudio {
            let host = activeAddresses[server.id] ?? server.host
            guard let info = try? await ServerSetup.ownAudioInfo(at: host, urlSession: Self.raceSession) else { continue }
            if info.modules.contains("narration") { narrationServers.insert(server.id) } else { narrationServers.remove(server.id) }
        }
    }

    /// The player's Stop: the book is let go everywhere, not only in the engine, so the mini
    /// player and the widget follow.
    func stopPlayback() {
        engine.stop()
        nowPlayingBook = nil
        nowPlayingServerId = nil
        nowPlayingPlan = nil
        forgetLastBook()
        Task { await refreshWidget() }
    }

    func isNowPlaying(_ book: Book, serverId: UUID) -> Bool {
        engine.book?.id == BookID.make(serverId: serverId, bookId: book.id)
    }

    // MARK: - ListeningProgress

    /// Every position the engine reports: to disk first, then to the server. A playing tick
    /// (every 10 s) writes only the queue in `PendingProgress`; the other stores — the resume
    /// point, the known positions, the last book — and the server follow at a checkpoint: at once
    /// on pause, seek, chapter, stop, a book change, the end and going to the background, and
    /// every minute while playing. A kill in between loses nothing: the queue is replayed at
    /// launch (`recoverUnsavedPositions`).
    private func positionReported(_ position: SpokenEngine.Position) {
        guard let (serverId, bookId) = BookID.parse(position.bookId) else { return }
        let composite = position.bookId
        progress[composite] = ListeningProgress(positionMs: position.positionMs, finished: position.finished, updatedAt: position.at, devices: progress[composite]?.devices ?? [])
        let closes = position.reason == .stop || position.reason == .finished || position.reason == .teardown
        let due = reporter.record(.init(
            id: UUID().uuidString, serverId: serverId, bookId: bookId, sessionId: nowPlayingPlan?.sessionId,
            positionMs: position.positionMs, listenedMs: position.listenedMs, durationMs: engine.durationMs,
            finished: position.finished, at: position.at, closes: closes
        ), reason: position.reason)
        guard due else {
            Task { await cacheFollowingParts() }
            return
        }
        knownPositions.set(composite, .init(positionMs: position.positionMs, finished: position.finished, at: position.at))
        resumeStore.commit()
        if position.finished {
            forgetLastBook()
        } else if position.reason != .stop, let book = nowPlayingBook, nowPlayingServerId == serverId, book.id == bookId {
            LastBook(serverId: serverId, book: book, positionMs: position.positionMs, durationMs: engine.durationMs).save()
        }
        Task { await flushPendingProgress(); await cacheFollowingParts() }
    }

    /// The app was killed between two checkpoints: positions still queued that are newer than
    /// the saved ones become the saved ones, so the next play resumes there, also offline.
    private func recoverUnsavedPositions() {
        for (composite, entry) in ProgressReporter.newerThanSaved(pendingProgress.all(), saved: { knownPositions[$0] }) {
            knownPositions.set(composite, .init(positionMs: entry.positionMs, finished: entry.finished, at: entry.at))
            if entry.finished {
                resumeStore.clearResume(containerId: composite)
            } else {
                let track = resumeStore.loadResume(containerId: composite)?.trackId ?? ""
                resumeStore.saveResume(containerId: composite, trackId: track, positionSecs: Double(entry.positionMs) / 1000)
            }
            if let last = lastBook, last.serverId == entry.serverId, last.book.id == entry.bookId {
                if entry.finished {
                    forgetLastBook()
                } else {
                    let moved = LastBook(serverId: last.serverId, book: last.book, positionMs: entry.positionMs, durationMs: last.durationMs)
                    moved.save()
                    lastBook = moved
                }
            }
        }
        resumeStore.commit()
    }

    // MARK: - The widget

    /// Continue Listening as the home screen last saw it, for the widget.
    private var widgetBooks: [(book: Book, serverId: UUID)] = []

    func noteShelves(_ shelves: [Shelf], serverId: UUID) {
        // No shelf means nothing under way: the widget says so rather than keeping an old list.
        if let shelf = shelves.first(where: { $0.id == "continue-listening" }), case .books(let books) = shelf.kind {
            widgetBooks = books.prefix(3).map { ($0, serverId) }
        } else {
            widgetBooks = []
        }
        Task { await refreshWidget() }
    }

    /// The widget follows play, pause and the book changing, not the position ticks: each
    /// write that changes it costs a redraw from the system's budget.
    private func followWidgetTriggers() {
        withObservationTracking {
            _ = engine.isPlaying
            _ = engine.book?.id
        } onChange: {
            Task { @MainActor [weak self] in
                await self?.refreshWidget()
                self?.followWidgetTriggers()
            }
        }
    }

    /// Writes the widget's snapshot: the book playing first, then the shelf.
    func refreshWidget() async {
        var list = widgetBooks
        if let now = nowPlayingBook, let serverId = nowPlayingServerId {
            list.removeAll { $0.book.id == now.id && $0.serverId == serverId }
            list.insert((now, serverId), at: 0)
        }
        var entries: [WidgetSnapshot.Entry] = []
        for (book, serverId) in list.prefix(3) {
            let progress = knownProgress(book, serverId: serverId)
            let position = progress?.finished == true ? 0 : (progress?.positionMs ?? 0)
            let fraction = book.durationMs > 0 ? Double(position) / Double(book.durationMs) : 0
            let cover = await coverImage(book, serverId: serverId, size: 120)?.jpegData(compressionQuality: 0.7)
            entries.append(.init(
                id: BookID.make(serverId: serverId, bookId: book.id), title: book.title, author: book.authorLine,
                fraction: min(max(fraction, 0), 1), remainingMs: max(book.durationMs - position, 0), cover: cover
            ))
        }
        WidgetSnapshot(entries: entries, at: Date()).save()
    }

    /// `ownbook://play/<id>` from the widget: the book from the phone or its server, then play.
    /// A bare server-side id (no `<server>|`) means the active server.
    func play(compositeId: String) async {
        // The link can be what starts the app.
        if !hasLoaded { await load() }
        let (serverId, bookId): (UUID, String)
        if let parsed = BookID.parse(compositeId) {
            (serverId, bookId) = parsed
        } else if let active = activeServerId {
            (serverId, bookId) = (active, compositeId)
        } else {
            return
        }
        let compositeId = BookID.make(serverId: serverId, bookId: bookId)
        let book: Book
        if let local = downloads.downloaded(compositeId)?.book {
            book = local
        } else if let source = sources[serverId], let found = try? await source.book(id: bookId) {
            book = found
        } else {
            actionError = String(localized: "That book is not in the library any more.")
            return
        }
        await play(book, serverId: serverId)
    }

    /// Sends what is on disk, oldest first (`ProgressReporter.flush`).
    func flushPendingProgress() async {
        await reporter.flush(isOffline: isOffline)
    }

    /// The position for a screen: what the app knows, else what the server says.
    func progress(for book: Book, serverId: UUID) async -> ListeningProgress? {
        let composite = BookID.make(serverId: serverId, bookId: book.id)
        if let known = progress[composite] { return known }
        guard let source = sources[serverId], let fetched = try? await source.progress(bookId: book.id) else { return nil }
        progress[composite] = fetched
        return fetched
    }

    func knownProgress(_ book: Book, serverId: UUID) -> ListeningProgress? {
        progress[BookID.make(serverId: serverId, bookId: book.id)]
    }

    func markFinished(_ book: Book, serverId: UUID, _ finished: Bool) async {
        guard let source = sources[serverId] else { return }
        let composite = BookID.make(serverId: serverId, bookId: book.id)
        forgetPlayback(of: composite, serverId: serverId, bookId: book.id)
        do {
            let position = finished ? book.durationMs : 0
            let saved = try await source.saveProgress(bookId: book.id, positionMs: position, durationMs: book.durationMs, finished: finished, at: Date())
            progress[composite] = saved
            if !finished { resumeStore.clearResume(containerId: composite) }
        } catch {
            actionError = (error as? SourceError)?.userMessage ?? error.localizedDescription
        }
    }

    /// Before a position is set by hand or forgotten: the engine lets go of the book without
    /// reporting where it was, and nothing queued for it is sent afterwards.
    private func forgetPlayback(of composite: String, serverId: UUID, bookId: String) {
        if engine.book?.id == composite {
            engine.stop(reporting: false)
            nowPlayingBook = nil
            nowPlayingPlan = nil
        }
        pendingProgress.remove(serverId: serverId, bookId: bookId)
        knownPositions.set(composite, nil)
    }

    func clearProgress(_ book: Book, serverId: UUID) async {
        guard let source = sources[serverId] else { return }
        let composite = BookID.make(serverId: serverId, bookId: book.id)
        forgetPlayback(of: composite, serverId: serverId, bookId: book.id)
        do {
            try await source.clearProgress(bookId: book.id)
            progress[composite] = nil
            resumeStore.clearResume(containerId: composite)
        } catch {
            actionError = (error as? SourceError)?.userMessage ?? error.localizedDescription
        }
    }

    // MARK: - Downloads and the offline library

    /// Downloads the book's files; the detail is fetched first when the record has none.
    func download(_ book: Book, serverId: UUID) async {
        guard let source = sources[serverId] else { return }
        do {
            let detail = book.files == nil ? try await source.book(id: book.id) : book
            downloads.download(detail, serverId: serverId)
        } catch {
            actionError = (error as? SourceError)?.userMessage ?? error.localizedDescription
        }
    }

    func downloadState(_ book: Book, serverId: UUID) -> DownloadManager.State? {
        downloads.state(of: BookID.make(serverId: serverId, bookId: book.id))
    }

    func removeDownload(_ book: Book, serverId: UUID) {
        downloads.remove(BookID.make(serverId: serverId, bookId: book.id))
    }

    func isDownloaded(_ book: Book, serverId: UUID) -> Bool {
        downloads.isDownloaded(BookID.make(serverId: serverId, bookId: book.id))
    }

    /// A whole set — a series, an author's books, a collection — one after the other; those
    /// already here are left alone.
    func downloadAll(_ books: [Book], serverId: UUID) async {
        for book in books where downloadState(book, serverId: serverId) == nil {
            await download(book, serverId: serverId)
        }
    }

    func removeDownloads(_ books: [Book], serverId: UUID) {
        for book in books { removeDownload(book, serverId: serverId) }
    }

    /// Offline, whether the server's screens list the whole catalogue (the listener's choice,
    /// and only where a copy of it is on the phone) rather than the downloads alone.
    func showsWholeLibraryOffline(serverId: UUID) -> Bool {
        settings.wholeLibraryOffline && sources[serverId] is any ChangeFeedCatalogue && sessions.catalogue(for: serverId).summary != nil
    }

    /// A book that cannot play right now: offline, and not on the phone.
    func isOutOfReach(_ book: Book, serverId: UUID) -> Bool {
        isOffline && !isDownloaded(book, serverId: serverId)
    }

    /// The books on this iPhone from a server, newest download first.
    func offlineBooks(serverId: UUID) -> [Book] {
        downloads.downloadedBooks(serverId: serverId).map(\.book)
    }

    /// A downloaded book's record, for a screen that can't ask the server.
    func downloadedBook(_ book: Book, serverId: UUID) -> Book? {
        downloads.downloaded(BookID.make(serverId: serverId, bookId: book.id))?.book
    }

    // MARK: - Covers

    func coverImage(_ book: Book, serverId: UUID, size: Int) async -> UIImage? {
        let url = book.coverURL
        return await covers.image(compositeId: BookID.make(serverId: serverId, bookId: book.id), size: size) { url }
    }

    /// For the lock screen: the cover of the book in the engine.
    private func coverImage(compositeId: String, size: Int) async -> UIImage? {
        guard let book = nowPlayingBook, let serverId = nowPlayingServerId, BookID.make(serverId: serverId, bookId: book.id) == compositeId else { return nil }
        return await coverImage(book, serverId: serverId, size: size)
    }

    // MARK: - Errors

    /// Runs something the listener asked for; a failure is shown once.
    func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                actionError = (error as? SourceError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}

enum AddServerError: LocalizedError, Equatable {
    case rejected
    case unreachable
    case notAServer
    case noBookLibrary
    case serverTooOld
    case twoFactorNeeded
    case wrongCode
    case badAddress
    case server(String)

    /// Errors that mean the address was right and trying another scheme is pointless.
    var isFinal: Bool {
        switch self {
        case .rejected, .noBookLibrary, .serverTooOld, .twoFactorNeeded, .wrongCode, .badAddress, .server: true
        case .unreachable, .notAServer: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .rejected: String(localized: "The server refused that name and password.")
        case .unreachable: String(localized: "The server could not be reached. Check the address and your connection.")
        case .notAServer: String(localized: "That address does not answer as an own.audio or Audiobookshelf server.")
        case .noBookLibrary: String(localized: "This account reaches no book library on that server.")
        case .serverTooOld: String(localized: "This own.audio server is too old for the app; update it to 1.0.0-beta.20 or later.")
        case .twoFactorNeeded: String(localized: "A code from your authenticator is needed.")
        case .wrongCode: String(localized: "That code was not accepted.")
        case .badAddress: String(localized: "That doesn't look like a server address.")
        case .server(let message): message
        }
    }
}

extension Error {
    var isTwoFactorNeeded: Bool { (self as? AddServerError) == .twoFactorNeeded }
}

extension SourceError {
    var userMessage: String {
        switch self {
        case .signInRejected: String(localized: "The server refused the sign-in. Sign in again in Settings › Servers.")
        case .notAllowed: String(localized: "The server did not allow that.")
        case .notFound: String(localized: "The server no longer has that.")
        case .http(let status): String(localized: "The server answered with an error (\(status)).")
        case .unreadable: String(localized: "The server's answer could not be read.")
        case .network: String(localized: "The server could not be reached.")
        case .offline: String(localized: "Not available offline.")
        case .unsupported: String(localized: "This server does not offer that.")
        case .server(let message): message
        }
    }
}

// MARK: - The last book, back after a relaunch

/// The book in the player when the app went away. Shown in the mini player at its position, and
/// loaded only when played: loading it at launch would open a play session on Audiobookshelf
/// for a book nobody pressed play on. Stop and the end of the book clear it.
struct LastBook: Codable, Equatable {
    let serverId: UUID
    let book: Book
    let positionMs: Int64
    let durationMs: Int64

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("last-book.json")
    }

    static func load() -> LastBook? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(LastBook.self, from: $0) }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: file)
    }
}

extension AppModel {
    func forgetLastBook() {
        lastBook = nil
        LastBook.remove()
    }

    /// Plays the last book from where it was; offline, only if it is downloaded.
    func playLastBook() async {
        guard let last = lastBook else { return }
        await play(last.book, serverId: last.serverId, startAt: last.positionMs)
    }
}
