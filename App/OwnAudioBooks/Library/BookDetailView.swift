import BookLibrary
import SwiftUI

/// One book: cover, metadata, where the listener is, Play, and its chapters, files and
/// bookmarks.
struct BookDetailView: View {
    @Environment(AppModel.self) private var model
    @State var book: Book
    let serverId: UUID
    @State private var progress: ListeningProgress?
    @State private var bookmarks: [Bookmark] = []
    @State private var isFavourite = false
    @State private var isStarting = false
    @State private var tab: Tab = .chapters
    @State private var isConfirmingReset = false

    private enum Tab: Hashable { case chapters, files, bookmarks }

    private var source: (any BookSource)? { model.source(for: serverId) }
    private var isPlayingThis: Bool { model.isNowPlaying(book, serverId: serverId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header
                playRow
                if let description = book.description, !description.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        SectionHeader(title: "Description")
                        Text(description.strippingHTML)
                            .font(.body)
                            .foregroundStyle(Theme.Colors.foreground)
                            .lineLimit(6)
                            .padding(.horizontal, Theme.Spacing.screenEdge)
                    }
                }
                metadata
                Picker("Section", selection: $tab) {
                    Text("Chapters").tag(Tab.chapters)
                    Text("Files").tag(Tab.files)
                    Text("Bookmarks").tag(Tab.bookmarks)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.Spacing.screenEdge)
                .accessibilityIdentifier("detail.sections")
                sectionContent
            }
            .padding(.vertical, Theme.Spacing.md)
        }
        .background(Theme.Colors.background)
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if model.capabilitiesFor(serverId).contains(.favourites) {
                        Button {
                            toggleFavourite()
                        } label: {
                            Label(isFavourite ? "Remove Favourite" : "Add to Favourites", systemImage: isFavourite ? "heart.slash" : "heart")
                        }
                    }
                    if model.canShare(book, serverId: serverId) {
                        Button {
                            setShared(book.visibility != .family)
                        } label: {
                            Label(book.visibility == .family ? "Keep to Myself" : "Share with the Family", systemImage: book.visibility == .family ? "person.2.slash" : "person.2")
                        }
                        .accessibilityIdentifier("detail.share")
                    }
                    if progress?.finished == true {
                        Button { Task { await model.markFinished(book, serverId: serverId, false); await refresh() } } label: { Label("Mark as Not Finished", systemImage: "arrow.uturn.backward") }
                    } else {
                        Button { Task { await model.markFinished(book, serverId: serverId, true); await refresh() } } label: { Label("Mark as Finished", systemImage: "checkmark.circle") }
                    }
                    if progress != nil {
                        Button(role: .destructive) { isConfirmingReset = true } label: { Label("Reset Progress", systemImage: "trash") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
                .accessibilityIdentifier("detail.more")
            }
        }
        .confirmationDialog("Reset Progress?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
            Button("Reset Progress", role: .destructive) { Task { await model.clearProgress(book, serverId: serverId); await refresh() } }
        } message: {
            Text("The position is forgotten on every device.")
        }
        .task { await load() }
        .onChange(of: model.knownProgress(book, serverId: serverId)) { _, known in if let known { progress = known } }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            CoverView(book: book, serverId: serverId, pointSize: 120)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(book.title).font(.title2.bold()).foregroundStyle(Theme.Colors.foreground).accessibilityIdentifier("detail.title")
                if let subtitle = book.subtitle, !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(Theme.Colors.muted) }
                if !book.authors.isEmpty {
                    Text(book.authorLine).font(.headline).foregroundStyle(Theme.Colors.muted)
                }
                ForEach(book.series, id: \.id) { series in
                    NavigationLink(value: LibraryRoute.oneSeries(SeriesSummary(id: series.id, name: series.name, bookCount: 0), serverId: serverId)) {
                        Text(series.sequence.map { "\(series.name) #\($0)" } ?? series.name).font(.caption).foregroundStyle(.tint)
                    }
                }
                if book.visibility == .family {
                    Label("Shared with the family", systemImage: "person.2.fill").font(.caption).foregroundStyle(.tint)
                }
                Spacer(minLength: 0)
                Text(ProgressText.summary(book: book, progress: progress))
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.muted)
                    .accessibilityIdentifier("detail.progress")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Spacing.screenEdge)
    }

    private var playRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            playButton
            DownloadButton(book: book, serverId: serverId)
        }
        .padding(.horizontal, Theme.Spacing.screenEdge)
    }

    private var playButton: some View {
        let fraction = BookCard.fraction(book: book, progress: progress) ?? 0
        return Button {
            play()
        } label: {
            Group {
                if isStarting {
                    ProgressView().tint(.white)
                } else if isPlayingThis {
                    Label(model.engine.isPlaying ? "Pause" : "Resume", systemImage: model.engine.isPlaying ? "pause.fill" : "play.fill")
                } else if let progress, progress.positionMs > 0, !progress.finished {
                    Label("Continue Listening", systemImage: "play.fill")
                } else if progress?.finished == true {
                    Label("Listen Again", systemImage: "play.fill")
                } else {
                    Label("Play", systemImage: "play.fill")
                }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background {
                // The button's own background is the progress bar.
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.tint.opacity(0.55))
                        Rectangle().fill(.tint).frame(width: geometry.size.width * (fraction >= 0.01 ? fraction : 0))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isStarting)
        .accessibilityIdentifier("detail.play")
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Details").padding(.horizontal, -Theme.Spacing.screenEdge).padding(.bottom, Theme.Spacing.sm)
            if !book.narrators.isEmpty { metadataRow("mic.fill", "Narrator", book.narratorLine) }
            metadataRow("clock", "Length", ProgressText.length(book.durationMs))
            if let year = book.publishedYear { metadataRow("calendar", "Published", year) }
            if let publisher = book.publisher { metadataRow("building.2", "Publisher", publisher) }
            if !book.genres.isEmpty { metadataRow("tag", "Genres", book.genres.joined(separator: ", ")) }
            if let files = book.files, !files.isEmpty {
                let bytes = files.compactMap(\.sizeBytes).reduce(0, +)
                metadataRow("internaldrive", "Files", bytes > 0 ? "\(files.count) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))" : "\(files.count)")
            }
        }
        .padding(.horizontal, Theme.Spacing.screenEdge)
    }

    private func metadataRow(_ symbol: String, _ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Label(label, systemImage: symbol).font(.subheadline).foregroundStyle(Theme.Colors.foreground)
                Spacer()
                Text(value).font(.subheadline).foregroundStyle(Theme.Colors.muted).multilineTextAlignment(.trailing)
            }
            .padding(.vertical, Theme.Spacing.sm)
            Divider()
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch tab {
        case .chapters:
            if let chapters = book.chapters, !chapters.isEmpty {
                VStack(spacing: 0) {
                    ForEach(chapters) { chapter in
                        Button {
                            jump(to: chapter.startMs)
                        } label: {
                            let isCurrent = isPlayingThis && model.engine.currentChapter?.startMs == chapter.startMs
                            HStack {
                                if isCurrent { NowPlayingIndicator(isPlaying: model.engine.isPlaying) }
                                Text(chapter.title).font(.subheadline.weight(isCurrent ? .semibold : .regular)).foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.Colors.foreground)).lineLimit(2)
                                Spacer()
                                Text(ProgressText.clock(chapter.durationMs)).font(.caption.monospacedDigit()).foregroundStyle(Theme.Colors.muted)
                            }
                            .padding(.horizontal, Theme.Spacing.screenEdge)
                            .frame(minHeight: Theme.minTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, Theme.Spacing.screenEdge)
                    }
                }
            } else if book.files == nil {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Text("No chapter marks. The files are the chapters.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Colors.muted)
                    .padding(Theme.Spacing.md)
            }
        case .files:
            if let files = book.files {
                VStack(spacing: 0) {
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                        Button {
                            jump(to: file.startMs)
                        } label: {
                            HStack {
                                Text(file.title ?? String(localized: "File \(index + 1)")).font(.subheadline).foregroundStyle(Theme.Colors.foreground).lineLimit(1)
                                Spacer()
                                Text(ProgressText.clock(file.durationMs)).font(.caption.monospacedDigit()).foregroundStyle(Theme.Colors.muted)
                            }
                            .padding(.horizontal, Theme.Spacing.screenEdge)
                            .frame(minHeight: Theme.minTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, Theme.Spacing.screenEdge)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        case .bookmarks:
            if bookmarks.isEmpty {
                Text("No bookmarks yet. Add one from the player.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Colors.muted)
                    .padding(Theme.Spacing.md)
            } else {
                VStack(spacing: 0) {
                    ForEach(bookmarks) { bookmark in
                        Button {
                            jump(to: bookmark.positionMs)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(bookmark.label ?? String(localized: "Bookmark")).font(.subheadline).foregroundStyle(Theme.Colors.foreground).lineLimit(1)
                                    Text(ProgressText.clock(bookmark.positionMs)).font(.caption.monospacedDigit()).foregroundStyle(Theme.Colors.muted)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, Theme.Spacing.screenEdge)
                            .frame(minHeight: Theme.minTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                model.perform { try await source?.deleteBookmark(bookmark); await refresh() }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                        Divider().padding(.leading, Theme.Spacing.screenEdge)
                    }
                }
            }
        }
    }

    private func load() async {
        if let local = model.downloadedBook(book, serverId: serverId), book.files == nil || model.isOffline {
            book = local
        } else if book.files == nil, !model.isOffline, let source, let detail = try? await source.book(id: book.id) {
            book = detail
        }
        await refresh()
    }

    private func refresh() async {
        progress = await model.progress(for: book, serverId: serverId)
        guard let source, !model.isOffline else { return }
        bookmarks = (try? await source.bookmarks(bookId: book.id)) ?? []
        if source.capabilities.contains(.favourites) {
            isFavourite = (try? await source.favourites().contains(book.id)) ?? model.isFavourite(book, serverId: serverId)
            model.noteFavourite(book, serverId: serverId, isFavourite)
        }
    }

    private func play() {
        if isPlayingThis {
            model.engine.togglePlayPause()
            return
        }
        isStarting = true
        Task {
            await model.play(book, serverId: serverId)
            isStarting = false
        }
    }

    /// A chapter, file or bookmark: play from there.
    private func jump(to positionMs: Int64) {
        if isPlayingThis {
            model.engine.seek(to: positionMs)
            if !model.engine.isPlaying { model.engine.play() }
            return
        }
        isStarting = true
        Task {
            await model.play(book, serverId: serverId)
            model.engine.seek(to: positionMs)
            isStarting = false
        }
    }

    /// The listener's own book, shared with the family or kept to themselves; put back if the
    /// server refuses.
    private func setShared(_ shared: Bool) {
        let before = book.visibility
        book.visibility = shared ? .family : .private
        model.perform {
            do { try await model.setShared(book, serverId: serverId, shared) } catch { book.visibility = before; throw error }
        }
    }

    private func toggleFavourite() {
        let wanted = !isFavourite
        isFavourite = wanted
        model.noteFavourite(book, serverId: serverId, wanted)
        model.perform {
            do {
                try await source?.setFavourite(bookId: book.id, wanted)
            } catch {
                isFavourite = !wanted
                model.noteFavourite(book, serverId: serverId, !wanted)
                throw error
            }
        }
    }
}

extension AppModel {
    func capabilitiesFor(_ serverId: UUID) -> Capabilities { source(for: serverId)?.capabilities ?? [] }
}

extension String {
    /// Descriptions arrive as HTML from some servers.
    var strippingHTML: String {
        guard contains("<") else { return self }
        let data = Data(utf8)
        if let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) {
            return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}
