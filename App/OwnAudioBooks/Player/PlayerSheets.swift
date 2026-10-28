import BookLibrary
import PlayerCore
import SwiftUI

/// Speed: a stepper in 0.05 steps, with the common speeds one tap away.
struct SpeedSheet: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AccentChoice.storageKey) private var accent: AccentChoice = .app
    @Environment(\.dismiss) private var dismiss

    private let presets: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.xl) {
                Text(model.engine.rate.speedText)
                    .font(.system(size: 48, weight: .semibold, design: .rounded).monospacedDigit())
                    .accessibilityIdentifier("speed.value")
                HStack(spacing: Theme.Spacing.xl) {
                    Button { model.setRate(model.engine.rate - 0.05) } label: { Image(systemName: "minus.circle.fill").font(.system(size: 44)) }
                        .accessibilityLabel("Slower")
                        .accessibilityIdentifier("speed.slower")
                    Button { model.setRate(model.engine.rate + 0.05) } label: { Image(systemName: "plus.circle.fill").font(.system(size: 44)) }
                        .accessibilityLabel("Faster")
                        .accessibilityIdentifier("speed.faster")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: Theme.Spacing.sm) {
                    ForEach(presets, id: \.self) { preset in
                        Button {
                            model.setRate(preset)
                        } label: {
                            Text(preset.speedText)
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: Theme.minTarget)
                        }
                        .buttonStyle(.bordered)
                        .tint(abs(model.engine.rate - preset) < 0.01 ? accent.color : .secondary)
                        .accessibilityIdentifier("speed.preset.\(preset)")
                    }
                }
                Text("Pitch stays the same at any speed. The speed is remembered for this book.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding(Theme.Spacing.xl)
            .navigationTitle("Speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

/// The sleep timer: a countdown, the end of the chapter, or the end of the book.
struct SleepTimerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let engine = model.engine
        let timer = engine.sleepTimer
        NavigationStack {
            List {
                if timer.isActive || engine.stopsAtEndOfChapter {
                    Section {
                        if let remaining = timer.remainingSecs {
                            LabeledContent("Stops in", value: formatDuration(remaining))
                            Button("Add 10 Minutes") { timer.extend(bySecs: 600) }
                        } else if engine.stopsAtEndOfChapter {
                            Text("Stops at the end of this chapter")
                        } else {
                            Text("Stops at the end of the book")
                        }
                        Button("Turn Off", role: .destructive) {
                            timer.cancel()
                            engine.stopAtEndOfChapter(false)
                            dismiss()
                        }
                        .accessibilityIdentifier("sleep.off")
                    }
                }
                Section {
                    ForEach(SleepTimer.Preset.allCases) { preset in
                        Button(preset.label) {
                            engine.stopAtEndOfChapter(false)
                            timer.start(preset: preset)
                            dismiss()
                        }
                        .accessibilityIdentifier("sleep.\(Int(preset.secs / 60))")
                    }
                    Button("End of Chapter") {
                        timer.cancel()
                        engine.stopAtEndOfChapter(true)
                        dismiss()
                    }
                    .disabled(!engine.hasChapters && engine.book == nil)
                    .accessibilityIdentifier("sleep.endOfChapter")
                    Button("End of Book") {
                        engine.stopAtEndOfChapter(false)
                        timer.startUntilEndOfItem()
                        dismiss()
                    }
                    .accessibilityIdentifier("sleep.endOfBook")
                }
            }
            .navigationTitle("Sleep Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The book's chapters, the current one marked; a tap plays from there.
struct ChaptersSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let engine = model.engine
        let chapters = engine.book?.timeline.chapters ?? []
        let current = engine.currentChapter
        NavigationStack {
            ScrollViewReader { proxy in
                List(chapters) { chapter in
                    Button {
                        engine.seek(to: chapter.startMs)
                        if !engine.isPlaying { engine.play() }
                        dismiss()
                    } label: {
                        HStack {
                            if chapter == current {
                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint).accessibilityLabel("Playing")
                            }
                            Text(chapter.title).foregroundStyle(.primary).lineLimit(2)
                            Spacer()
                            Text(ProgressText.clock(chapter.durationMs)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .id(chapter.id)
                    .accessibilityIdentifier("chapters.\(chapter.startMs)")
                }
                .listStyle(.plain)
                .onAppear { if let current { proxy.scrollTo(current.id, anchor: .center) } }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Bookmarks of the book in the engine: add one here, jump to one, rename or delete it.
struct BookmarksSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var bookmarks: [Bookmark] = []
    @State private var isLoading = true
    @State private var editing: Bookmark?
    @State private var label = ""
    @State private var isAdding = false

    private var context: (source: any BookSource, book: Book)? {
        guard let book = model.nowPlayingBook, let serverId = model.nowPlayingServerId, let source = model.source(for: serverId) else { return nil }
        return (source, book)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        label = ""
                        isAdding = true
                    } label: {
                        Label("Add Bookmark at \(ProgressText.clock(model.engine.positionMs))", systemImage: "bookmark.fill")
                    }
                    .accessibilityIdentifier("bookmarks.add")
                }
                Section {
                    if isLoading {
                        ProgressView()
                    } else if bookmarks.isEmpty {
                        Text("No bookmarks in this book yet.").foregroundStyle(.secondary)
                    }
                    ForEach(bookmarks) { bookmark in
                        Button {
                            model.engine.seek(to: bookmark.positionMs)
                            if !model.engine.isPlaying { model.engine.play() }
                            dismiss()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(bookmark.label ?? String(localized: "Bookmark")).foregroundStyle(.primary)
                                Text(ProgressText.clock(bookmark.positionMs)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("bookmarks.\(bookmark.positionMs)")
                        // Words, not icons: on a row this short iOS would draw the icons alone.
                        .swipeActions {
                            Button("Delete", role: .destructive) { delete(bookmark) }
                            Button("Rename") { label = bookmark.label ?? ""; editing = bookmark }
                        }
                    }
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .alert("New Bookmark", isPresented: $isAdding) {
                TextField("Label (optional)", text: $label).accessibilityIdentifier("bookmarks.label")
                Button("Cancel", role: .cancel) {}
                Button("Add") { add() }
            }
            .alert("Rename Bookmark", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("Label", text: $label)
                Button("Cancel", role: .cancel) { editing = nil }
                Button("Save") { rename() }
            }
        }
    }

    private func load() async {
        guard let (source, book) = context else { isLoading = false; return }
        bookmarks = (try? await source.bookmarks(bookId: book.id)) ?? []
        isLoading = false
    }

    private func add() {
        guard let (source, book) = context else { return }
        let position = model.engine.positionMs
        let text = label.trimmingCharacters(in: .whitespaces)
        model.perform {
            let made = try await source.addBookmark(bookId: book.id, positionMs: position, label: text.isEmpty ? nil : text)
            bookmarks = (bookmarks + [made]).sorted { $0.positionMs < $1.positionMs }
            Haptics.impact(.light)
        }
    }

    private func rename() {
        guard let (source, _) = context, let bookmark = editing else { return }
        let text = label.trimmingCharacters(in: .whitespaces)
        editing = nil
        model.perform {
            let renamed = try await source.renameBookmark(bookmark, label: text.isEmpty ? nil : text)
            if let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) { bookmarks[index] = renamed }
        }
    }

    private func delete(_ bookmark: Bookmark) {
        guard let (source, _) = context else { return }
        bookmarks.removeAll { $0.id == bookmark.id }
        model.perform { try await source.deleteBookmark(bookmark) }
    }
}
