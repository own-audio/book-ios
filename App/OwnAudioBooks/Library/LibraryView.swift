import BookLibrary
import SwiftUI

/// Every book of the active server, as a grid or a list, sorted and filtered; and, where the
/// server offers them, ways in by series, author, narrator and collection.
struct LibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let serverId = model.activeServerId {
            BooksListView(title: String(localized: "Library"), query: BookQuery(), serverId: serverId, isRoot: true)
        } else {
            ContentUnavailableView("No Server", systemImage: "books.vertical")
        }
    }
}

/// A list of books from one query, paged as the listener scrolls.
struct BooksListView: View {
    @Environment(AppModel.self) private var model
    let title: String
    @State var query: BookQuery
    let serverId: UUID
    var isRoot = false

    @AppStorage("library.grid") private var isGrid = true
    @State private var books: [Book] = []
    @State private var next: String?
    @State private var total: Int?
    @State private var state: LoadState<Void> = .loading
    @State private var isLoadingMore = false

    private var source: (any BookSource)? { model.source(for: serverId) }

    var body: some View {
        Group {
            if isGrid { grid } else { list }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Sort", selection: $query.sort) {
                        Text("Title").tag(BookSort.title)
                        Text("Author").tag(BookSort.author)
                        Text("Recently Added").tag(BookSort.added)
                        Text("Length").tag(BookSort.duration)
                    }
                    Toggle("Descending", isOn: $query.descending)
                    Divider()
                    Picker("Show", selection: $query.filter) {
                        Text("All").tag(BookFilter.all)
                        Text("Not Started").tag(BookFilter.notStarted)
                        Text("In Progress").tag(BookFilter.inProgress)
                        Text("Finished").tag(BookFilter.finished)
                    }
                    Divider()
                    Toggle("Grid", isOn: $isGrid)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Sort and filter")
                .accessibilityIdentifier("library.sortFilter")
            }
        }
        .task(id: "\(serverId)|\(query.sort.rawValue)|\(query.descending)|\(query.filter.rawValue)") { await reload() }
        .refreshable { await reload() }
    }

    private var grid: some View {
        ScrollView {
            LoadStateView(state: state, retry: { Task { await reload() } }) { _ in
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    if isRoot { sections }
                    if books.isEmpty {
                        ContentUnavailableView("No Books", systemImage: "books.vertical", description: Text(emptyText))
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: Theme.Spacing.md, alignment: .top)], alignment: .leading, spacing: Theme.Spacing.lg) {
                        ForEach(books) { book in
                            NavigationLink(value: LibraryRoute.book(book, serverId: serverId)) {
                                BookCard(book: book, serverId: serverId, width: 140)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("library.book.\(book.id)")
                            .onAppear { if book.id == books.last?.id { Task { await loadMore() } } }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.screenEdge)
                    if isLoadingMore { ProgressView().frame(maxWidth: .infinity) }
                }
                .padding(.vertical, Theme.Spacing.md)
            }
        }
    }

    private var list: some View {
        List {
            if isRoot { Section { sectionLinks } }
            Section {
                switch state {
                case .loading: ProgressView()
                case .failed(let message): Text(message).foregroundStyle(.red)
                case .loaded:
                    if books.isEmpty { Text(emptyText).foregroundStyle(.secondary) }
                    ForEach(books) { book in
                        NavigationLink(value: LibraryRoute.book(book, serverId: serverId)) { BookRow(book: book, serverId: serverId) }
                            .accessibilityIdentifier("library.book.\(book.id)")
                            .onAppear { if book.id == books.last?.id { Task { await loadMore() } } }
                    }
                    if isLoadingMore { ProgressView() }
                }
            } header: {
                if let total { Text("\(total) books") }
            }
        }
        .listStyle(.plain)
    }

    private var emptyText: String {
        switch query.filter {
        case .all: String(localized: "This library has no books yet.")
        case .notStarted: String(localized: "Every book has been started.")
        case .inProgress: String(localized: "No book is in progress.")
        case .finished: String(localized: "No book is finished yet.")
        }
    }

    /// Series, authors, narrators, collections — those the server has.
    private var sections: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) { sectionLinks }
                .padding(.horizontal, Theme.Spacing.screenEdge)
        }
    }

    @ViewBuilder
    private var sectionLinks: some View {
        let capabilities = source?.capabilities ?? []
        if capabilities.contains(.series) || serverKind == .ownAudio {
            sectionLink("Series", "square.stack.3d.up", .series(serverId: serverId), id: "series")
        }
        sectionLink("Authors", "person.2", .authors(serverId: serverId), id: "authors")
        sectionLink("Narrators", "waveform", .narrators(serverId: serverId), id: "narrators")
        if capabilities.contains(.collections) {
            sectionLink("Collections", "rectangle.stack", .collections(serverId: serverId), id: "collections")
        }
    }

    private var serverKind: ServerKind? { model.server(serverId)?.kind }

    private func sectionLink(_ title: LocalizedStringKey, _ symbol: String, _ route: LibraryRoute, id: String) -> some View {
        NavigationLink(value: route) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(Color(.secondarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.\(id)")
    }

    private func reload() async {
        guard let source else { return }
        if books.isEmpty { state = .loading }
        do {
            let page = try await source.books(query, cursor: nil, limit: 60)
            books = page.books
            next = page.next
            total = page.total
            state = .loaded(())
        } catch let error as SourceError {
            state = .failed(error.userMessage)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func loadMore() async {
        guard let source, let cursor = next, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let page = try? await source.books(query, cursor: cursor, limit: 60) {
            books += page.books.filter { new in !books.contains { $0.id == new.id } }
            next = page.next
        }
    }
}

/// Authors or narrators of the active server; each opens their books.
struct PeopleView: View {
    enum Kind { case authors, narrators }
    @Environment(AppModel.self) private var model
    let kind: Kind
    let serverId: UUID
    @State private var state: LoadState<[Person]> = .loading
    @State private var filter = ""

    var body: some View {
        List {
            LoadStateView(state: state, retry: load) { people in
                let shown = filter.isEmpty ? people : people.filter { $0.name.localizedCaseInsensitiveContains(filter) }
                if shown.isEmpty { Text("Nobody here yet.").foregroundStyle(.secondary) }
                ForEach(shown) { person in
                    NavigationLink(value: LibraryRoute.books(title: person.name, query: kind == .authors ? BookQuery(authorId: person.id) : BookQuery(narratorId: person.id), serverId: serverId)) {
                        HStack {
                            Text(person.name)
                            Spacer()
                            if let count = person.bookCount { Text("\(count)").foregroundStyle(.secondary) }
                        }
                    }
                    .accessibilityIdentifier("people.\(person.id)")
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $filter, prompt: Text("Filter"))
        .navigationTitle(kind == .authors ? "Authors" : "Narrators")
        .task(id: serverId) { load() }
    }

    private func load() {
        Task {
            guard let source = model.source(for: serverId) else { return }
            do {
                state = .loaded(try await (kind == .authors ? source.authors() : source.narrators()))
            } catch let error as SourceError {
                state = .failed(error.userMessage)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

struct SeriesListView: View {
    @Environment(AppModel.self) private var model
    let serverId: UUID
    @State private var state: LoadState<[SeriesSummary]> = .loading

    var body: some View {
        List {
            LoadStateView(state: state, retry: load) { series in
                if series.isEmpty { Text("No series yet.").foregroundStyle(.secondary) }
                ForEach(series) { one in
                    NavigationLink(value: LibraryRoute.oneSeries(one, serverId: serverId)) {
                        HStack {
                            Text(one.name)
                            Spacer()
                            Text("\(one.bookCount)").foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("series.\(one.id)")
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Series")
        .task(id: serverId) { load() }
    }

    private func load() {
        Task {
            guard let source = model.source(for: serverId) else { return }
            do { state = .loaded(try await source.series()) } catch let error as SourceError { state = .failed(error.userMessage) } catch { state = .failed(error.localizedDescription) }
        }
    }
}

struct SeriesDetailView: View {
    @Environment(AppModel.self) private var model
    let series: SeriesSummary
    let serverId: UUID
    @State private var books: [Book]?

    var body: some View {
        List {
            if let books {
                ForEach(books) { book in
                    NavigationLink(value: LibraryRoute.book(book, serverId: serverId)) {
                        HStack(spacing: Theme.Spacing.sm) {
                            if let sequence = book.series.first(where: { $0.id == series.id })?.sequence {
                                Text(sequence).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 24)
                            }
                            BookRow(book: book, serverId: serverId)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .listStyle(.plain)
        .navigationTitle(series.name)
        .task {
            if let known = series.books { books = known }
            if let source = model.source(for: serverId), let loaded = try? await source.series(id: series.id).books { books = loaded }
        }
    }
}

struct CollectionsView: View {
    @Environment(AppModel.self) private var model
    let serverId: UUID
    @State private var state: LoadState<[Collection]> = .loading

    var body: some View {
        List {
            LoadStateView(state: state, retry: load) { collections in
                if collections.isEmpty { Text("No collections yet.").foregroundStyle(.secondary) }
                ForEach(collections) { collection in
                    NavigationLink(value: LibraryRoute.collection(collection, serverId: serverId)) {
                        HStack {
                            Text(collection.name)
                            Spacer()
                            Text("\(collection.books.count)").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Collections")
        .task(id: serverId) { load() }
    }

    private func load() {
        Task {
            guard let source = model.source(for: serverId) else { return }
            do { state = .loaded(try await source.collections()) } catch let error as SourceError { state = .failed(error.userMessage) } catch { state = .failed(error.localizedDescription) }
        }
    }
}

struct CollectionDetailView: View {
    let collection: Collection
    let serverId: UUID

    var body: some View {
        List(collection.books) { book in
            NavigationLink(value: LibraryRoute.book(book, serverId: serverId)) { BookRow(book: book, serverId: serverId) }
        }
        .listStyle(.plain)
        .navigationTitle(collection.name)
    }
}
