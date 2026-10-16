import BookLibrary
import SwiftUI

/// First run: add a server. After that three tabs — Home, Library, Search — with the mini
/// player above the tab bar and the full player as a cover.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingPlayer = false
    @State private var tab: AppTab = .home

    private enum AppTab: Hashable { case home, library, search }

    var body: some View {
        Group {
            if !model.hasLoaded {
                ProgressView()
            } else if model.servers.isEmpty {
                OnboardingView()
            } else {
                tabs
            }
        }
        .fullScreenCover(isPresented: $isShowingPlayer) { PlayerView() }
        .alert("That Didn't Work", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
        .confirmationDialog(
            Text(model.pendingResume.map { "Continue from \($0.otherDevice ?? String(localized: "another device"))?" } ?? ""),
            isPresented: Binding(get: { model.pendingResume != nil }, set: { if !$0 { model.pendingResume = nil } }),
            titleVisibility: .visible,
            presenting: model.pendingResume
        ) { pending in
            Button("Continue from \(pending.otherDevice ?? String(localized: "there")) (\(ProgressText.clock(pending.otherMs)))") {
                model.pendingResume = nil
                Task { await model.play(pending.book, serverId: pending.serverId, startAt: pending.otherMs) }
            }
            .accessibilityIdentifier("resume.other")
            Button("Keep this iPhone's position (\(ProgressText.clock(pending.localMs)))") {
                model.pendingResume = nil
                Task { await model.play(pending.book, serverId: pending.serverId, startAt: pending.localMs) }
            }
            .accessibilityIdentifier("resume.local")
        } message: { pending in
            Text("\(pending.otherDevice ?? String(localized: "Another device")) got to \(ProgressText.clock(pending.otherMs)); this iPhone was at \(ProgressText.clock(pending.localMs)).")
        }
        .onChange(of: model.engine.errorMessage) { _, message in
            if let message, !isShowingPlayer { model.actionError = message }
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack { HomeView().libraryDestinations() }
                    .miniPlayerInset { isShowingPlayer = true }
            }
            Tab("Library", systemImage: "books.vertical", value: AppTab.library) {
                LibraryTab()
                    .miniPlayerInset { isShowingPlayer = true }
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                NavigationStack { SearchView().libraryDestinations() }
                    .miniPlayerInset { isShowingPlayer = true }
            }
        }
        // Switching servers starts every tab over: their screens belong to the old library.
        .id(model.activeServerId)
    }
}

/// The library's sections behind chips on iPhone; on iPad, a sidebar beside the open section.
private struct LibraryTab: View {
    private enum SidebarItem: Hashable { case books, series, authors, narrators, collections, downloads }

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: SidebarItem? = .books

    var body: some View {
        if sizeClass == .regular, let serverId = model.activeServerId {
            NavigationSplitView {
                List(selection: $selection) {
                    Label("All Books", systemImage: "books.vertical").tag(SidebarItem.books)
                        .accessibilityIdentifier("sidebar.books")
                    if model.capabilitiesFor(serverId).contains(.series) || model.server(serverId)?.kind == .ownAudio {
                        Label("Series", systemImage: "square.stack.3d.up").tag(SidebarItem.series)
                            .accessibilityIdentifier("sidebar.series")
                    }
                    Label("Authors", systemImage: "person.2").tag(SidebarItem.authors)
                        .accessibilityIdentifier("sidebar.authors")
                    Label("Narrators", systemImage: "waveform").tag(SidebarItem.narrators)
                        .accessibilityIdentifier("sidebar.narrators")
                    if model.capabilitiesFor(serverId).contains(.collections) {
                        Label("Collections", systemImage: "rectangle.stack").tag(SidebarItem.collections)
                            .accessibilityIdentifier("sidebar.collections")
                    }
                    Label("Downloads", systemImage: "arrow.down.circle").tag(SidebarItem.downloads)
                        .accessibilityIdentifier("sidebar.downloads")
                }
                .navigationTitle("Library")
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
            } detail: {
                NavigationStack { detail(serverId).libraryDestinations() }
                    .id(selection)
            }
        } else {
            NavigationStack { LibraryView().libraryDestinations() }
        }
    }

    @ViewBuilder
    private func detail(_ serverId: UUID) -> some View {
        switch selection {
        case .books, nil: BooksListView(title: String(localized: "All Books"), query: BookQuery(), serverId: serverId, isRoot: true, showsSections: false)
        case .series: SeriesListView(serverId: serverId)
        case .authors: PeopleView(kind: .authors, serverId: serverId)
        case .narrators: PeopleView(kind: .narrators, serverId: serverId)
        case .collections: CollectionsView(serverId: serverId)
        case .downloads: DownloadsView()
        }
    }
}

private extension View {
    func miniPlayerInset(onTap: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                OfflineBanner()
                MiniPlayerBar(onTap: onTap)
            }
        }
    }
}
