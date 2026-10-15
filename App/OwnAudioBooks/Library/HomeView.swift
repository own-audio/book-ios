import BookLibrary
import SwiftUI

/// The tab the app opens on: the server's shelves — Continue Listening first — and Settings
/// behind a gear.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var state: LoadState<[Shelf]> = .loading
    @State private var isShowingSettings = false

    var body: some View {
        ScrollView {
            LoadStateView(state: state, retry: load) { shelves in
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    if shelves.isEmpty {
                        ContentUnavailableView("No Books Yet", systemImage: "books.vertical", description: Text("This server's library is empty."))
                    }
                    ForEach(shelves) { shelf in
                        if let serverId = model.activeServerId { ShelfView(shelf: shelf, serverId: serverId) }
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
        }
        .navigationTitle(model.activeServer?.displayName ?? "Home")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { isShowingSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("home.settings")
            }
        }
        .sheet(isPresented: $isShowingSettings) { NavigationStack { SettingsView() } }
        .refreshable { await reload() }
        .task(id: model.activeServerId) { await reload() }
        .onChange(of: model.engine.isPlaying) { was, is_ in
            // A pause moves a book up the Continue Listening shelf.
            if was && !is_ { Task { await reload(quietly: true) } }
        }
    }

    private func load() {
        Task { await reload() }
    }

    private func reload(quietly: Bool = false) async {
        guard let source = model.activeSource else { return }
        if !quietly, case .loaded = state {} else if !quietly { state = .loading }
        do {
            state = .loaded(try await source.shelves())
        } catch let error as SourceError {
            if case .loaded = state, quietly { return }
            state = .failed(error.userMessage)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// One horizontal row of the home screen.
struct ShelfView: View {
    let shelf: Shelf
    let serverId: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(shelf.title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, Theme.Spacing.screenEdge)
                .accessibilityIdentifier("home.shelf.\(shelf.id)")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    switch shelf.kind {
                    case .books(let books):
                        ForEach(books) { book in
                            NavigationLink(value: LibraryRoute.book(book, serverId: serverId)) {
                                BookCard(book: book, serverId: serverId, width: 140)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("home.book.\(book.id)")
                        }
                    case .series(let series):
                        ForEach(series) { one in
                            NavigationLink(value: LibraryRoute.oneSeries(one, serverId: serverId)) {
                                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                    if let first = one.books?.first {
                                        CoverView(book: first, serverId: serverId, pointSize: 140)
                                    }
                                    Text(one.name).font(.subheadline.weight(.semibold)).lineLimit(2, reservesSpace: true)
                                    Text("\(one.bookCount) books").font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(width: 140, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    case .authors(let people):
                        ForEach(people) { person in
                            NavigationLink(value: LibraryRoute.books(title: person.name, query: BookQuery(authorId: person.id), serverId: serverId)) {
                                VStack(spacing: Theme.Spacing.xs) {
                                    Image(systemName: "person.circle.fill")
                                        .font(.system(size: 64))
                                        .foregroundStyle(.secondary)
                                    Text(person.name).font(.subheadline).lineLimit(2, reservesSpace: true).multilineTextAlignment(.center)
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
