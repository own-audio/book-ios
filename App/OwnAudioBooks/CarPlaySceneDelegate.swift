import BookLibrary
import CarPlay
import SpokenEngine
import UIKit

/// The car's screen. It runs in the same process as the phone UI and drives the same model and
/// player, so a book started here shows on the phone and the lock screen, and the other way
/// round. Now Playing is the system's own template, with the chapters behind its Up Next button
/// and the speed on its rate button; the skip buttons come from the remote commands the player
/// already registers.
///
/// Lists are short on purpose: CarPlay is for a glance and a tap. Continue Listening comes
/// first and downloads next, because a car often has no signal.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPNowPlayingTemplateObserver {
    private var interfaceController: CPInterfaceController?
    private var model: AppModel { AppModel.shared }

    private static var maxItems: Int { CarPlayContent.maxItems }
    private static let title = "own.book"

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        interfaceController.setRootTemplate(CPListTemplate(title: Self.title, sections: []), animated: false) { _, _ in }
        CPNowPlayingTemplate.shared.add(self)
        configureNowPlaying()
        Task {
            // CarPlay can start the app without the phone UI ever appearing.
            if !model.hasLoaded { await model.load() }
            showRoot()
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        CPNowPlayingTemplate.shared.remove(self)
        self.interfaceController = nil
    }

    // MARK: - Root

    private func showRoot() {
        guard let serverId = model.activeServerId, !CarPlayContent.rootEntries(hasServer: model.activeSource != nil).isEmpty else {
            let item = CPListItem(text: String(localized: "Add a server on your iPhone"), detailText: nil)
            item.isEnabled = false
            interfaceController?.setRootTemplate(
                CPListTemplate(title: Self.title, sections: [CPListSection(items: [item])]), animated: true
            ) { _, _ in }
            return
        }
        let items = CarPlayContent.rootEntries(hasServer: true).map { entry -> CPListItem in
            let item = CPListItem(text: entry.title, detailText: nil, image: UIImage(systemName: entry.symbol))
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                Task {
                    switch entry {
                    case .continueListening: await self?.pushContinueListening(serverId)
                    case .downloads: self?.pushDownloads(serverId)
                    case .library: await self?.pushBooks(BookQuery(), title: entry.title, serverId: serverId)
                    case .series: await self?.pushSeries(serverId)
                    case .authors: await self?.pushAuthors(serverId)
                    }
                    completion()
                }
            }
            return item
        }
        let root = CPListTemplate(title: model.activeServer?.displayName ?? Self.title, sections: [CPListSection(items: items)])
        interfaceController?.setRootTemplate(root, animated: true) { _, _ in }
    }

    // MARK: - Lists

    private func pushContinueListening(_ serverId: UUID) async {
        var books: [Book] = []
        if model.isOffline {
            books = CarPlayContent.continueListening(offline: model.offlineBooks(serverId: serverId)) { self.model.knownProgress($0, serverId: serverId) }
        } else if let shelves = try? await model.activeSource?.shelves() {
            books = CarPlayContent.continueListening(fromShelves: shelves)
        }
        pushBookList(books, title: String(localized: "Continue Listening"), serverId: serverId, emptyText: String(localized: "Nothing started yet"))
    }

    /// From the download index alone, so it works with no signal.
    private func pushDownloads(_ serverId: UUID) {
        pushBookList(model.offlineBooks(serverId: serverId), title: String(localized: "Downloads"), serverId: serverId, emptyText: String(localized: "Nothing downloaded"))
    }

    private func pushBooks(_ query: BookQuery, title: String, serverId: UUID) async {
        guard let source = model.source(for: serverId) else { return }
        let books = model.isOffline && !model.showsWholeLibraryOffline(serverId: serverId)
            ? model.offlineBooks(serverId: serverId)
            : ((try? await source.books(query, cursor: nil, limit: Self.maxItems).books) ?? [])
        pushBookList(books, title: title, serverId: serverId, emptyText: String(localized: "Nothing here yet"))
    }

    private func pushSeries(_ serverId: UUID) async {
        guard let source = model.source(for: serverId) else { return }
        let series = (try? await source.series()) ?? []
        push(title: String(localized: "Series"), items: series.prefix(Self.maxItems).map { one in
            let item = CPListItem(text: one.name, detailText: String(localized: "\(one.bookCount) books"))
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                Task {
                    var books = one.books ?? []
                    if books.isEmpty { books = (try? await source.series(id: one.id).books) ?? [] }
                    self?.pushBookList(books, title: one.name, serverId: serverId, emptyText: String(localized: "Nothing here yet"))
                    completion()
                }
            }
            return item
        }, emptyText: String(localized: "No series yet."))
    }

    private func pushAuthors(_ serverId: UUID) async {
        guard let source = model.source(for: serverId) else { return }
        let authors = (try? await source.authors()) ?? []
        push(title: String(localized: "Authors"), items: authors.prefix(Self.maxItems).map { person in
            let item = CPListItem(text: person.name, detailText: person.bookCount.map { String(localized: "\($0) books") })
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.pushBooks(BookQuery(authorId: person.id), title: person.name, serverId: serverId)
                    completion()
                }
            }
            return item
        }, emptyText: String(localized: "Nobody here yet."))
    }

    private func pushBookList(_ books: [Book], title: String, serverId: UUID, emptyText: String) {
        push(title: title, items: books.prefix(Self.maxItems).map { book in
            let item = CPListItem(text: book.title, detailText: book.authorLine.isEmpty ? nil : book.authorLine)
            item.isPlaying = model.isNowPlaying(book, serverId: serverId)
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.play(book, serverId: serverId)
                    completion()
                }
            }
            loadCover(for: item, book: book, serverId: serverId)
            return item
        }, emptyText: emptyText)
    }

    // MARK: - Playing

    private func play(_ book: Book, serverId: UUID) async {
        await model.play(book, serverId: serverId)
        // No question in the car: the newer position wins, as on the phone when nothing was
        // known here.
        if let pending = model.pendingResume {
            model.pendingResume = nil
            await model.play(pending.book, serverId: pending.serverId, startAt: pending.otherMs)
        }
        showNowPlaying()
    }

    private func configureNowPlaying() {
        let template = CPNowPlayingTemplate.shared
        let rate = CPNowPlayingPlaybackRateButton { [weak self] _ in self?.cycleRate() }
        template.updateNowPlayingButtons([rate])
        template.isUpNextButtonEnabled = true
        template.upNextTitle = String(localized: "Chapters")
    }

    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in self.pushChapters() }
    }

    /// 1× → 1.25× → … → 2× → 0.75× → 1×, remembered for the book as the phone's speed sheet does.
    private func cycleRate() {
        let next = CarPlayContent.nextRate(after: model.engine.rate)
        model.engine.setRate(next)
        if let book = model.nowPlayingBook, let serverId = model.nowPlayingServerId {
            model.settings.remember(rate: next, for: BookID.make(serverId: serverId, bookId: book.id))
        }
    }

    private func pushChapters() {
        guard let book = model.engine.book else { return }
        let current = model.engine.currentChapter
        let items = book.timeline.chapters.enumerated().map { index, chapter -> CPListItem in
            let item = CPListItem(text: CarPlayContent.chapterTitle(chapter.title, index: index), detailText: ProgressText.clock(chapter.startMs))
            item.isPlaying = chapter == current
            item.handler = { [weak self] _, completion in
                guard let self else { completion(); return }
                self.model.engine.seek(to: chapter.startMs)
                if !self.model.engine.isPlaying { self.model.engine.play() }
                self.interfaceController?.popTemplate(animated: true) { _, _ in }
                completion()
            }
            return item
        }
        push(title: String(localized: "Chapters"), items: items, emptyText: String(localized: "No chapters"))
    }

    // MARK: - Helpers

    /// A tapped row should visibly start something, not leave the driver on the list.
    private func showNowPlaying() {
        guard interfaceController?.topTemplate !== CPNowPlayingTemplate.shared else { return }
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true) { _, _ in }
    }

    private func push(title: String, items: [CPListItem], emptyText: String) {
        interfaceController?.pushTemplate(CarPlayContent.listTemplate(title: title, items: items, emptyText: emptyText), animated: true) { _, _ in }
    }

    /// The row appears at once; its cover fills in when loaded.
    private func loadCover(for item: CPListItem, book: Book, serverId: UUID) {
        Task {
            if let image = await model.coverImage(book, serverId: serverId, size: 120) { item.setImage(image) }
        }
    }
}
