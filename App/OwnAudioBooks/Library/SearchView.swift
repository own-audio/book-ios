import BookLibrary
import SwiftUI

/// Books, authors, narrators and series: on the server where it searches, else over the
/// catalogue on the phone.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var result: SearchResult?
    @State private var isSearching = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else if let result, let serverId = model.activeServerId {
                if result.books.isEmpty && result.authors.isEmpty && result.narrators.isEmpty && result.series.isEmpty {
                    ContentUnavailableView.search(text: text)
                }
                if !result.books.isEmpty {
                    Section("Books") {
                        ForEach(result.books) { book in
                            NavigationLink(value: LibraryRoute.book(book, serverId: serverId)) { BookRow(book: book, serverId: serverId) }
                                .accessibilityIdentifier("search.book.\(book.id)")
                        }
                    }
                }
                if !result.series.isEmpty {
                    Section("Series") {
                        ForEach(result.series) { one in
                            NavigationLink(value: LibraryRoute.oneSeries(one, serverId: serverId)) { Text(one.name) }
                        }
                    }
                }
                if !result.authors.isEmpty {
                    Section("Authors") {
                        ForEach(result.authors) { person in
                            NavigationLink(value: LibraryRoute.books(title: person.name, query: BookQuery(authorId: person.id), serverId: serverId)) { Text(person.name) }
                        }
                    }
                }
                if !result.narrators.isEmpty {
                    Section("Narrators") {
                        ForEach(result.narrators) { person in
                            NavigationLink(value: LibraryRoute.books(title: person.name, query: BookQuery(narratorId: person.id), serverId: serverId)) { Text(person.name) }
                        }
                    }
                }
            } else if text.isEmpty {
                ContentUnavailableView("Search the Library", systemImage: "magnifyingglass", description: Text("Titles, authors, narrators and series."))
            }
        }
        .listStyle(.plain)
        .overlay { if isSearching { ProgressView() } }
        .searchable(text: $text, prompt: Text("Books, authors, narrators"))
        .navigationTitle("Search")
        .task(id: text) {
            let needle = text.trimmingCharacters(in: .whitespaces)
            guard needle.count >= 2, let source = model.activeSource else { result = nil; return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            isSearching = true
            errorMessage = nil
            do {
                result = try await source.search(needle)
            } catch let error as SourceError {
                errorMessage = error.userMessage
            } catch {
                errorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }
}
