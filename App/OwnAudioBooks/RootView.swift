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
        .alert("Position Moved", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.notice ?? "")
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
                NavigationStack { LibraryView().libraryDestinations() }
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
