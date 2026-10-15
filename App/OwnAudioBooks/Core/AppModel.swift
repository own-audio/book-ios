import BookLibrary
import Foundation
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
    /// The book in the engine, with the server it came from.
    private(set) var nowPlayingBook: Book?
    private(set) var nowPlayingServerId: UUID?
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
    private let pendingProgress = PendingProgress()
    private let resumeStore = UserDefaultsResumeStore(key: "books.resume")
    private var loadTask: Task<Void, Never>?
    private var liveUpdates: Task<Void, Never>?
    private var isInForeground = true
    private var flushing = false

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
        applyPlaybackSettings()
        network.onChange = { [weak self] _ in
            Task { await self?.chooseAddresses(); await self?.flushPendingProgress() }
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
        !network.isConnected || (network.isExpensive && settings.mobileData == .downloadedOnly) || Self.isSimulatingOffline
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
        }
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
        Task {
            await chooseAddresses()
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
              let libraries = try? await source.client.bookLibraries() else { return [] }
        let list = libraries.map { ($0.id, $0.name) }
        audiobookshelfLibraries[serverId] = list
        return list
    }

    func setLibrary(serverId: UUID, libraryId: String) async throws {
        guard var record = server(serverId) else { return }
        record.libraryId = libraryId
        try await update(record)
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

    func sceneBecame(active: Bool) {
        guard isInForeground != active else { return }
        isInForeground = active
        followLibraryChanges()
        if active {
            Task {
                await syncCatalogues()
                await flushPendingProgress()
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

    /// Starts `book` where the listener left it: the server's position, else the one this phone
    /// remembers, else the start (and the start again for a finished book).
    func play(_ book: Book, serverId: UUID) async {
        guard let source = sources[serverId] else { return }
        let composite = BookID.make(serverId: serverId, bookId: book.id)
        do {
            let detail = book.files == nil ? try await source.book(id: book.id) : book
            let plan = try await source.playPlan(for: detail, maxBitrateKbps: maxBitrateKbps)
            let serverProgress = try? await source.progress(bookId: book.id)
            if let serverProgress { progress[composite] = serverProgress }
            let parts = plan.parts.map { SpokenPart(id: $0.fileId, url: $0.url, durationMs: $0.durationMs, isHLS: $0.isHLS) }
            let chapters = await chapters(for: detail, parts: parts)
            let spoken = SpokenBook(id: composite, title: detail.title, author: detail.authorLine.isEmpty ? nil : detail.authorLine, parts: parts, chapters: chapters, linksExpireAt: plan.expiresAt)
            let start: Int64
            if let serverProgress, !serverProgress.finished {
                start = serverProgress.positionMs
            } else if let local = resumeStore.loadResume(containerId: composite), serverProgress?.finished != true {
                start = Int64(local.positionSecs * 1000)
            } else {
                start = plan.startPositionMs ?? 0
            }
            nowPlayingBook = detail
            nowPlayingServerId = serverId
            nowPlayingPlan = plan
            applyPlaybackSettings()
            engine.setRate(settings.rate(for: composite))
            engine.load(spoken, at: start, autoplay: true)
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
        engine.skipForwardSecs = settings.skipForwardSecs
        engine.skipBackwardSecs = settings.skipBackwardSecs
        engine.smartRewind = SmartRewind(isEnabled: settings.smartRewind)
    }

    func setRate(_ rate: Float) {
        engine.setRate(rate)
        if let book = engine.book { settings.remember(rate: engine.rate, for: book.id) }
    }

    private func freshPartURL(serverId: UUID, bookId: String, partId: String) async throws -> URL {
        guard let source = sources[serverId], let book = nowPlayingBook, book.id == bookId else { throw SourceError.notFound }
        let part = try await source.partURL(for: book, fileId: partId, startMs: nil, maxBitrateKbps: maxBitrateKbps)
        return part.url
    }

    var isNowPlaying: Bool { engine.book != nil }

    func isNowPlaying(_ book: Book, serverId: UUID) -> Bool {
        engine.book?.id == BookID.make(serverId: serverId, bookId: book.id)
    }

    // MARK: - ListeningProgress

    /// Every position the engine reports: to disk first, then to the server.
    private func positionReported(_ position: SpokenEngine.Position) {
        guard let (serverId, bookId) = BookID.parse(position.bookId) else { return }
        let composite = position.bookId
        progress[composite] = ListeningProgress(positionMs: position.positionMs, finished: position.finished, updatedAt: position.at, devices: progress[composite]?.devices ?? [])
        let closes = position.reason == .stop || position.reason == .finished || position.reason == .teardown
        pendingProgress.record(.init(
            id: UUID().uuidString, serverId: serverId, bookId: bookId, sessionId: nowPlayingPlan?.sessionId,
            positionMs: position.positionMs, listenedMs: position.listenedMs, durationMs: engine.durationMs,
            finished: position.finished, at: position.at, closes: closes
        ))
        Task { await flushPendingProgress() }
    }

    /// Sends what is on disk, oldest first; what the server refuses for good is dropped, what
    /// could not reach it stays for the next try.
    func flushPendingProgress() async {
        guard !flushing, !isOffline else { return }
        flushing = true
        defer { flushing = false }
        for entry in pendingProgress.all().sorted(by: { $0.at < $1.at }) {
            guard let source = sources[entry.serverId] else { continue }
            do {
                let answer = try await source.report(PlaybackReport(
                    bookId: entry.bookId, sessionId: entry.sessionId, positionMs: entry.positionMs, listenedMs: entry.listenedMs,
                    durationMs: entry.durationMs, finished: entry.finished, at: entry.at, closes: entry.closes
                ))
                pendingProgress.remove(id: entry.id)
                let composite = BookID.make(serverId: entry.serverId, bookId: entry.bookId)
                if let answer, engine.book?.id != composite { progress[composite] = answer }
            } catch SourceError.network, SourceError.offline {
                return
            } catch SourceError.notFound {
                // The session is over or the book is gone: the position goes without a session.
                if entry.sessionId != nil {
                    pendingProgress.remove(id: entry.id)
                    pendingProgress.record(.init(id: UUID().uuidString, serverId: entry.serverId, bookId: entry.bookId, sessionId: nil, positionMs: entry.positionMs, listenedMs: entry.listenedMs, durationMs: entry.durationMs, finished: entry.finished, at: entry.at, closes: false))
                } else {
                    pendingProgress.remove(id: entry.id)
                }
            } catch SourceError.signInRejected {
                signInRefused.insert(entry.serverId)
                return
            } catch {
                pendingProgress.remove(id: entry.id)
            }
        }
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
    case server(String)

    /// Errors that mean the address was right and trying another scheme is pointless.
    var isFinal: Bool {
        switch self {
        case .rejected, .noBookLibrary, .serverTooOld, .twoFactorNeeded, .wrongCode, .server: true
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
