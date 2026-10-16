import AppIntents
import BookLibrary
import Foundation

/// A book as Siri and Shortcuts see it: the composite id, so the same title on two servers stays
/// two books.
struct BookEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Book")
    static let defaultQuery = BookEntityQuery()

    let id: String
    let title: String
    let author: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: author.map { "\($0)" })
    }

    init(_ book: Book, serverId: UUID) {
        id = BookID.make(serverId: serverId, bookId: book.id)
        title = book.title
        author = book.authorLine.isEmpty ? nil : book.authorLine
    }
}

/// Finds books by what was said: the active server's library first (the copy on the phone for
/// own.audio, the server for Audiobookshelf), the downloads when nothing can be asked.
struct BookEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [BookEntity] {
        let model = await loadedModel()
        var found: [BookEntity] = []
        for id in identifiers {
            guard let (serverId, bookId) = BookID.parse(id) else { continue }
            if let book = model.downloads.downloaded(id)?.book {
                found.append(BookEntity(book, serverId: serverId))
            } else if let source = model.source(for: serverId), let book = try? await source.book(id: bookId) {
                found.append(BookEntity(book, serverId: serverId))
            }
        }
        return found
    }

    @MainActor
    func entities(matching string: String) async throws -> [BookEntity] {
        let model = await loadedModel()
        guard let serverId = model.activeServerId, let source = model.source(for: serverId) else { return [] }
        let needle = string.trimmingCharacters(in: .whitespaces)
        if model.isOffline, !model.showsWholeLibraryOffline(serverId: serverId) {
            return model.offlineBooks(serverId: serverId)
                .filter { $0.title.localizedCaseInsensitiveContains(needle) || $0.authorLine.localizedCaseInsensitiveContains(needle) }
                .map { BookEntity($0, serverId: serverId) }
        }
        let books = (try? await source.search(needle).books) ?? []
        return books.prefix(10).map { BookEntity($0, serverId: serverId) }
    }

    @MainActor
    func suggestedEntities() async throws -> [BookEntity] {
        let model = await loadedModel()
        guard let serverId = model.activeServerId else { return [] }
        return model.offlineBooks(serverId: serverId).prefix(10).map { BookEntity($0, serverId: serverId) }
    }

    @MainActor
    private func loadedModel() async -> AppModel {
        let model = AppModel.shared
        if !model.hasLoaded { await model.load() }
        return model
    }
}

/// "Play The Time Machine in own.book."
struct PlayBookIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play a Book"
    static let description = IntentDescription("Plays an audiobook from your library, from where you left off.")

    @Parameter(title: "Book")
    var book: BookEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$book)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        if !model.hasLoaded { await model.load() }
        guard let (serverId, bookId) = BookID.parse(book.id), let source = model.source(for: serverId) else { throw IntentError.noServer }
        let record: Book
        if let local = model.downloads.downloaded(book.id)?.book {
            record = local
        } else {
            do { record = try await source.book(id: bookId) } catch { throw IntentError.notFound }
        }
        await model.play(record, serverId: serverId)
        // Siri can't be asked where to continue: the newer position wins.
        if let pending = model.pendingResume {
            model.pendingResume = nil
            await model.play(pending.book, serverId: pending.serverId, startAt: pending.otherMs)
        }
        return .result()
    }
}

/// "Continue listening in own.book": the book that was playing, else the one listened to last.
struct ContinueListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Continue Listening"
    static let description = IntentDescription("Goes on with the book you were listening to.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        if !model.hasLoaded { await model.load() }
        if model.engine.book != nil {
            if !model.engine.isPlaying { model.engine.play() }
            return .result()
        }
        guard let serverId = model.activeServerId, let source = model.source(for: serverId) else { throw IntentError.noServer }
        var next: Book?
        if model.isOffline {
            next = model.offlineBooks(serverId: serverId).first { book in
                model.knownProgress(book, serverId: serverId).map { $0.positionMs > 0 && !$0.finished } ?? false
            }
        } else if let shelves = try? await source.shelves(),
                  let shelf = shelves.first(where: { $0.id == "continue-listening" }), case .books(let books) = shelf.kind {
            next = books.first
        }
        guard let next else { throw IntentError.nothingStarted }
        await model.play(next, serverId: serverId)
        if let pending = model.pendingResume {
            model.pendingResume = nil
            await model.play(pending.book, serverId: pending.serverId, startAt: pending.otherMs)
        }
        return .result()
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case noServer, notFound, nothingStarted

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noServer: "Add a server in own.book first."
        case .notFound: "That book is not in the library any more."
        case .nothingStarted: "No book is under way; start one in own.book."
        }
    }
}

/// The phrases Siri answers to without any setup in Shortcuts.
struct BookShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ContinueListeningIntent(),
            phrases: [
                "Continue listening in \(.applicationName)",
                "Continue my book in \(.applicationName)",
                "Resume my audiobook in \(.applicationName)",
            ],
            shortTitle: "Continue Listening",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: PlayBookIntent(),
            phrases: [
                "Play \(\.$book) in \(.applicationName)",
                "Listen to \(\.$book) in \(.applicationName)",
            ],
            shortTitle: "Play a Book",
            systemImageName: "book"
        )
    }
}
