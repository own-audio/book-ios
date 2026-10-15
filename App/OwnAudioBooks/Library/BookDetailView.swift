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
                    Text(description.strippingHTML)
                        .font(.body)
                        .lineLimit(6)
                        .padding(.horizontal, Theme.Spacing.screenEdge)
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
            CoverView(book: book, serverId: serverId, pointSize: 140)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(book.title).font(.title3.weight(.semibold)).accessibilityIdentifier("detail.title")
                if let subtitle = book.subtitle, !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                if !book.authors.isEmpty {
                    Text(book.authorLine).font(.subheadline).foregroundStyle(.secondary)
                }
                if !book.narrators.isEmpty {
                    Label(book.narratorLine, systemImage: "waveform").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(book.series, id: \.id) { series in
                    NavigationLink(value: LibraryRoute.oneSeries(SeriesSummary(id: series.id, name: series.name, bookCount: 0), serverId: serverId)) {
                        Text(series.sequence.map { "\(series.name) #\($0)" } ?? series.name).font(.caption)
                    }
                }
                Spacer(minLength: 0)
                Text(ProgressText.summary(book: book, progress: progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("detail.progress")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Spacing.screenEdge)
    }

    private var playRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button {
                play()
            } label: {
                Group {
                    if isStarting {
                        ProgressView().tint(.white)
                    } else if isPlayingThis {
                        Label(model.engine.isPlaying ? "Pause" : "Resume", systemImage: model.engine.isPlaying ? "pause.fill" : "play.fill")
                    } else if let progress, progress.positionMs > 0, !progress.finished {
                        Label("Resume", systemImage: "play.fill")
                    } else if progress?.finished == true {
                        Label("Play Again", systemImage: "play.fill")
                    } else {
                        Label("Play", systemImage: "play.fill")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.xs)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isStarting)
            .accessibilityIdentifier("detail.play")
            if let progress, progress.positionMs > 0, !progress.finished, book.durationMs > 0 {
                ProgressView(value: Double(progress.positionMs), total: Double(book.durationMs))
                    .frame(width: 80)
                    .accessibilityLabel("Progress")
            }
        }
        .padding(.horizontal, Theme.Spacing.screenEdge)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            metadataRow("Length", ProgressText.length(book.durationMs))
            if let year = book.publishedYear { metadataRow("Published", year) }
            if let publisher = book.publisher { metadataRow("Publisher", publisher) }
            if !book.genres.isEmpty { metadataRow("Genres", book.genres.joined(separator: ", ")) }
            if let files = book.files, !files.isEmpty {
                let bytes = files.compactMap(\.sizeBytes).reduce(0, +)
                metadataRow("Files", bytes > 0 ? "\(files.count) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))" : "\(files.count)")
            }
            if let visibility = book.visibility {
                metadataRow("Sharing", visibility == .family ? String(localized: "Shared with the family") : String(localized: "Only you"))
            }
        }
        .font(.footnote)
        .padding(.horizontal, Theme.Spacing.screenEdge)
    }

    private func metadataRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(value)
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
                            HStack {
                                Text(chapter.title).lineLimit(2)
                                Spacer()
                                Text(ProgressText.clock(chapter.durationMs)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.screenEdge)
            }
        case .files:
            if let files = book.files {
                VStack(spacing: 0) {
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                        Button {
                            jump(to: file.startMs)
                        } label: {
                            HStack {
                                Text(file.title ?? String(localized: "File \(index + 1)")).lineLimit(1)
                                Spacer()
                                Text(ProgressText.clock(file.durationMs)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.screenEdge)
            } else {
                VStack(spacing: 0) {
                    ForEach(bookmarks) { bookmark in
                        Button {
                            jump(to: bookmark.positionMs)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(bookmark.label ?? String(localized: "Bookmark")).lineLimit(1)
                                    Text(ProgressText.clock(bookmark.positionMs)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
        if book.files == nil, let source, let detail = try? await source.book(id: book.id) { book = detail }
        await refresh()
    }

    private func refresh() async {
        progress = await model.progress(for: book, serverId: serverId)
        if let source {
            bookmarks = (try? await source.bookmarks(bookId: book.id)) ?? []
            if source.capabilities.contains(.favourites) { isFavourite = (try? await source.favourites().contains(book.id)) ?? false }
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

    private func toggleFavourite() {
        let wanted = !isFavourite
        isFavourite = wanted
        model.perform {
            do { try await source?.setFavourite(bookId: book.id, wanted) } catch { isFavourite = !wanted; throw error }
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
