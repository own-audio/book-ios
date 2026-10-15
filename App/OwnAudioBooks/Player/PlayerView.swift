import BookLibrary
import SwiftUI

/// The full player: cover, title and chapter, a book-level bar with the time left at the
/// current speed, a chapter scrubber, skip buttons with their intervals, chapter buttons, and
/// the speed, sleep timer, chapters and bookmarks sheets.
struct PlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: Sheet?
    @State private var scrubbing: Double?

    private enum Sheet: Identifiable {
        case speed, sleep, chapters, bookmarks
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let book = model.nowPlayingBook, let serverId = model.nowPlayingServerId {
                    content(book: book, serverId: serverId)
                } else {
                    ContentUnavailableView("Nothing Playing", systemImage: "book.closed")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel("Close")
                        .accessibilityIdentifier("player.close")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.engine.stop()
                        dismiss()
                    } label: { Image(systemName: "xmark.circle") }
                        .accessibilityLabel("Stop")
                        .accessibilityIdentifier("player.stop")
                }
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .speed: SpeedSheet()
                case .sleep: SleepTimerSheet()
                case .chapters: ChaptersSheet()
                case .bookmarks: BookmarksSheet()
                }
            }
        }
    }

    private func content(book: Book, serverId: UUID) -> some View {
        let engine = model.engine
        return VStack(spacing: Theme.Spacing.lg) {
            Spacer(minLength: 0)
            CoverView(book: book, serverId: serverId, pointSize: 260)
                .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                .overlay(alignment: .topTrailing) {
                    if let remaining = engine.sleepTimer.remainingSecs {
                        Label(formatDuration(remaining), systemImage: "moon.zzz.fill")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, Theme.Spacing.sm)
                            .padding(.vertical, Theme.Spacing.xs)
                            .background(.thinMaterial, in: Capsule())
                            .padding(Theme.Spacing.sm)
                            .accessibilityIdentifier("player.sleepBadge")
                    }
                }
            VStack(spacing: Theme.Spacing.xs) {
                Text(book.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .accessibilityIdentifier("player.title")
                Text(engine.currentChapter?.title ?? book.authorLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("player.chapter")
            }
            .padding(.horizontal, Theme.Spacing.xl)
            scrubbers
            controls
            bottomBar
            Spacer(minLength: 0)
        }
        .padding(.bottom, Theme.Spacing.lg)
    }

    /// The thin book bar above; the chapter (or whole book) scrubber below.
    private var scrubbers: some View {
        let engine = model.engine
        let chapter = engine.currentChapter
        let rangeStart = chapter?.startMs ?? 0
        let rangeEnd = chapter?.endMs ?? engine.durationMs
        let inChapter = Double(max(0, min(engine.positionMs - rangeStart, rangeEnd - rangeStart)))
        let left = Double(max(engine.durationMs - engine.positionMs, 0)) / 1000 / Double(max(engine.rate, 0.1))
        return VStack(spacing: Theme.Spacing.sm) {
            VStack(spacing: 2) {
                ProgressView(value: Double(engine.positionMs), total: Double(max(engine.durationMs, 1)))
                    .tint(.secondary)
                    .accessibilityHidden(true)
                HStack {
                    Text(ProgressText.clock(engine.positionMs)).accessibilityIdentifier("player.elapsed")
                    Spacer()
                    Text(String(localized: "\(ProgressText.clock(Int64(left * 1000))) left"))
                        .accessibilityIdentifier("player.remaining")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                Slider(
                    value: Binding(get: { scrubbing ?? inChapter }, set: { scrubbing = $0 }),
                    in: 0...Double(max(rangeEnd - rangeStart, 1))
                ) { editing in
                    if !editing, let scrubbing {
                        engine.seek(to: rangeStart + Int64(scrubbing))
                        self.scrubbing = nil
                    }
                }
                .accessibilityIdentifier("player.scrubber")
                .accessibilityValue("\(ProgressText.clock(Int64(scrubbing ?? inChapter))) of \(ProgressText.clock(rangeEnd - rangeStart))")
                HStack {
                    Text(ProgressText.clock(Int64(scrubbing ?? inChapter)))
                    Spacer()
                    Text("-" + ProgressText.clock(max(rangeEnd - rangeStart - Int64(scrubbing ?? inChapter), 0)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
    }

    private var controls: some View {
        let engine = model.engine
        return HStack(spacing: Theme.Spacing.lg) {
            control("backward.end.fill", "Previous chapter", id: "player.previousChapter", size: 22, enabled: engine.hasChapters) { engine.previousChapter() }
            control("gobackward.\(Int(engine.skipBackwardSecs))", "Back \(Int(engine.skipBackwardSecs)) seconds", id: "player.skipBackward", size: 30) { engine.skipBackward() }
            Button {
                Haptics.impact(.medium)
                engine.togglePlayPause()
            } label: {
                Group {
                    if engine.isLoading {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 72))
                    }
                }
                .frame(width: 80, height: 80)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("player.playPause")
            .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")
            control("goforward.\(Int(engine.skipForwardSecs))", "Forward \(Int(engine.skipForwardSecs)) seconds", id: "player.skipForward", size: 30) { engine.skipForward() }
            control("forward.end.fill", "Next chapter", id: "player.nextChapter", size: 22, enabled: engine.hasChapters) { engine.nextChapter() }
        }
    }

    private func control(_ symbol: String, _ label: String, id: String, size: CGFloat, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(minWidth: Theme.minTarget, minHeight: Theme.minTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
    }

    private var bottomBar: some View {
        let engine = model.engine
        return HStack {
            Button { sheet = .speed } label: {
                Text(String(format: "%.2g×", engine.rate)).font(.subheadline.weight(.semibold).monospacedDigit())
            }
            .accessibilityIdentifier("player.speed")
            .accessibilityLabel("Speed \(String(format: "%.2g", engine.rate))")
            Spacer()
            Button { sheet = .sleep } label: {
                Image(systemName: engine.sleepTimer.isActive || engine.stopsAtEndOfChapter ? "moon.zzz.fill" : "moon.zzz")
            }
            .accessibilityIdentifier("player.sleep")
            .accessibilityLabel("Sleep timer")
            Spacer()
            Button { sheet = .chapters } label: { Image(systemName: "list.bullet") }
                .accessibilityIdentifier("player.chapters")
                .accessibilityLabel("Chapters")
            Spacer()
            Button { sheet = .bookmarks } label: { Image(systemName: "bookmark") }
                .accessibilityIdentifier("player.bookmarks")
                .accessibilityLabel("Bookmarks")
        }
        .font(.title3)
        .padding(.horizontal, Theme.Spacing.xxl)
        .frame(minHeight: Theme.minTarget)
    }
}
