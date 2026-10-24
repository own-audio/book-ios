import BookLibrary
import SwiftUI

/// The tab the app opens on: a greeting, then the server's shelves — Continue Listening first,
/// where a tap plays — and Settings behind a gear.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var state: LoadState<[Shelf]> = .loading
    @State private var isShowingSettings = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOnScreen = false
    /// A pause happened while Home was out of sight; the shelves are read again on return.
    @State private var shelvesStale = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                greeting
                LoadStateView(state: state, retry: load) { shelves in
                    VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        if shelves.isEmpty {
                            if model.isOffline {
                                // Offline, Home shows what is on the phone; empty means nothing downloaded.
                                ContentUnavailableView("Nothing Downloaded", systemImage: "wifi.slash", description: Text("Offline, only downloaded books are here. Turn Offline Mode off, or download books to listen with no network."))
                            } else {
                                ContentUnavailableView("No Books Yet", systemImage: "books.vertical", description: Text("This server's library is empty."))
                            }
                        }
                        ForEach(shelves) { shelf in
                            if let serverId = model.activeServerId { ShelfView(shelf: shelf, serverId: serverId) }
                        }
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
        .background(Theme.Colors.background)
        .toolbar {
            if choices.count > 1 {
                ToolbarItem(placement: .topBarLeading) { serverMenu }
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: Binding(get: { model.settings.offlineMode }, set: { model.setOfflineMode($0) })) {
                    Label("Offline Mode", systemImage: model.settings.offlineMode ? "wifi.slash" : "wifi")
                }
                .toggleStyle(.button)
                .accessibilityIdentifier("home.offlineMode")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { isShowingSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("home.settings")
            }
        }
        .sheet(isPresented: $isShowingSettings) { NavigationStack { SettingsView() } }
        .refreshable { await reload() }
        .task(id: "\(model.activeServerId?.uuidString ?? "")|\(model.isOffline)") { await reload() }
        .onChange(of: model.engine.isPlaying) { was, now in
            // A pause moves a book up the Continue Listening shelf. Out of sight (another tab,
            // the lock screen, CarPlay) the request waits until Home is seen again.
            guard was && !now else { return }
            if isVisible { Task { await reload(quietly: true) } } else { shelvesStale = true }
        }
        .onAppear { isOnScreen = true; reloadIfStale() }
        .onDisappear { isOnScreen = false }
        .onChange(of: scenePhase) { _, _ in reloadIfStale() }
    }

    /// The switch's entries: one per server, and on an Audiobookshelf account with several book
    /// libraries, one per library instead, since the shelves show one library at a time.
    private struct Choice: Hashable {
        let serverId: UUID
        let libraryId: String?
    }

    private var choices: [(choice: Choice, name: String, kind: ServerKind)] {
        model.serversInOrder.flatMap { server -> [(choice: Choice, name: String, kind: ServerKind)] in
            if server.kind == .audiobookshelf, let libraries = server.libraries, libraries.count > 1 {
                return libraries.map { (Choice(serverId: server.id, libraryId: $0.id), "\(server.displayName) · \($0.name)", server.kind) }
            }
            return [(Choice(serverId: server.id, libraryId: nil), server.displayName, server.kind)]
        }
    }

    private var currentChoice: Choice? {
        guard let server = model.activeServer else { return nil }
        let several = server.kind == .audiobookshelf && (server.libraries?.count ?? 0) > 1
        return Choice(serverId: server.id, libraryId: several ? server.libraryId : nil)
    }

    /// With more than one server or library, which one the shelves and the library show is a tap away.
    private var serverMenu: some View {
        Menu {
            Picker("Server", selection: Binding(
                get: { currentChoice },
                set: { choice in
                    guard let choice else { return }
                    Task { await model.select(serverId: choice.serverId, libraryId: choice.libraryId) }
                }
            )) {
                ForEach(choices, id: \.choice) { entry in
                    Label(entry.name, systemImage: entry.kind == .ownAudio ? "person.3" : "server.rack")
                        .tag(Optional(entry.choice))
                }
            }
        } label: {
            Label(choices.first { $0.choice == currentChoice }?.name ?? model.activeServer?.displayName ?? "", systemImage: "server.rack")
                .labelStyle(.titleAndIcon)
        }
        .accessibilityIdentifier("home.serverMenu")
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(Self.greetingText())
                .font(.title2.bold())
                .foregroundStyle(Theme.Colors.foreground)
                .accessibilityIdentifier("home.greeting")
            Group {
                if let server = model.activeServer {
                    Text("\(server.displayName) · ready for your next chapter?")
                } else {
                    Text("Ready for your next chapter?")
                }
            }
            .font(.subheadline)
            .foregroundStyle(Theme.Colors.muted)
        }
        .padding(.horizontal, Theme.Spacing.screenEdge)
    }

    static func greetingText(hour: Int = Calendar.current.component(.hour, from: Date())) -> String {
        switch hour {
        case 5..<12: String(localized: "Good morning")
        case 12..<18: String(localized: "Good afternoon")
        default: String(localized: "Good evening")
        }
    }

    private func load() {
        Task { await reload() }
    }

    private var isVisible: Bool { isOnScreen && scenePhase == .active }

    private func reloadIfStale() {
        guard shelvesStale, isVisible else { return }
        shelvesStale = false
        Task { await reload(quietly: true) }
    }

    private func reload(quietly: Bool = false) async {
        guard let source = model.activeSource, let serverId = model.activeServerId else { return }
        if model.isOffline {
            let books = model.offlineBooks(serverId: serverId)
            let started = books.filter { model.knownProgress($0, serverId: serverId).map { $0.positionMs > 0 && !$0.finished } ?? false }
            state = .loaded([
                Shelf(id: "continue-listening", title: String(localized: "Continue Listening"), kind: .books(started)),
                Shelf(id: "downloaded", title: String(localized: "On This iPhone"), kind: .books(books)),
            ].filter { !$0.isEmpty })
            return
        }
        if !quietly, case .loaded = state {} else if !quietly { state = .loading }
        do {
            let shelves = try await source.shelves()
            state = .loaded(shelves)
            model.noteShelves(shelves, serverId: serverId)
        } catch let error as SourceError {
            if case .loaded = state, quietly { return }
            state = .failed(error.userMessage)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// One horizontal rail of the home screen.
struct ShelfView: View {
    @Environment(AppModel.self) private var model
    let shelf: Shelf
    let serverId: UUID

    private var playsOnTap: Bool { shelf.id == "continue-listening" }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title: LocalizedStringKey(shelf.title))
                .accessibilityIdentifier("home.shelf.\(shelf.id)")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                    switch shelf.kind {
                    case .books(let books):
                        ForEach(books) { book in
                            if playsOnTap {
                                Button {
                                    Haptics.impact(.light)
                                    Task { await model.play(book, serverId: serverId) }
                                } label: {
                                    BookCard(book: book, serverId: serverId, showsPlayOverlay: true)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("home.book.\(book.id)")
                                .contextMenu {
                                    NavigationLink(value: LibraryRoute.book(book, serverId: serverId)) { Label("Show Book", systemImage: "info.circle") }
                                }
                            } else {
                                NavigationLink(value: LibraryRoute.book(book, serverId: serverId)) {
                                    BookCard(book: book, serverId: serverId)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("home.book.\(book.id)")
                            }
                        }
                    case .series(let series):
                        ForEach(series) { one in
                            NavigationLink(value: LibraryRoute.oneSeries(one, serverId: serverId)) {
                                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                    if let first = one.books?.first {
                                        CoverView(book: first, serverId: serverId, pointSize: 140)
                                    } else {
                                        RoundedRectangle(cornerRadius: Theme.Radius.cover).fill(Theme.Colors.backgroundAlt).frame(width: 140, height: 140)
                                    }
                                    Text(one.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.Colors.foreground).lineLimit(2, reservesSpace: true)
                                    Text("\(one.bookCount) books").font(.caption).foregroundStyle(Theme.Colors.muted)
                                }
                                .frame(width: 140, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    case .authors(let people):
                        ForEach(people) { person in
                            NavigationLink(value: LibraryRoute.books(title: person.name, query: BookQuery(authorId: person.id), serverId: serverId)) {
                                VStack(spacing: Theme.Spacing.sm) {
                                    Image(systemName: "person.circle.fill")
                                        .font(.system(size: 64))
                                        .foregroundStyle(Theme.Colors.muted)
                                    Text(person.name).font(.subheadline).foregroundStyle(Theme.Colors.foreground).lineLimit(2, reservesSpace: true).multilineTextAlignment(.center)
                                }
                                .frame(width: 120)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.screenEdge)
            }
        }
    }
}
