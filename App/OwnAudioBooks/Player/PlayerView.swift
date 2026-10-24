import BookLibrary
import SwiftUI

/// The full player: the cover, title and author, the current chapter as a button, the thin
/// book bar over the chapter slider, the transport with skip intervals, chapter steps, and the
/// speed, sleep timer and bookmarks tools.
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
            .background(Theme.Colors.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel("Close")
                        .accessibilityIdentifier("player.close")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.stopPlayback()
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
        return ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                CoverView(book: book, serverId: serverId, pointSize: 260)
                    .overlay(alignment: .topTrailing) {
                        if let remaining = engine.sleepTimer.remainingSecs {
                            Label(formatDuration(remaining), systemImage: "moon.zzz.fill")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .padding(.horizontal, Theme.Spacing.sm)
                                .padding(.vertical, Theme.Spacing.xs)
                                .background(.regularMaterial, in: Capsule())
                                .padding(Theme.Spacing.sm)
                                .accessibilityIdentifier("player.sleepBadge")
                        }
                    }
                    .padding(.top, Theme.Spacing.lg)
                VStack(spacing: Theme.Spacing.xs) {
                    Text(book.title)
                        .font(.title2.bold())
                        .foregroundStyle(Theme.Colors.foreground)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .accessibilityIdentifier("player.title")
                    if !book.authorLine.isEmpty {
                        Text(book.authorLine).font(.headline).foregroundStyle(Theme.Colors.muted).lineLimit(1)
                    }
                    Button { sheet = .chapters } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            Text(engine.currentChapter?.title ?? String(localized: "Chapters"))
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                        .foregroundStyle(Theme.Colors.accent)
                    }
                    .accessibilityIdentifier("player.chapter")
                    .accessibilityLabel("Chapter: \(engine.currentChapter?.title ?? "")")
                }
                .padding(.horizontal, Theme.Spacing.xl)
                scrubbers
                controls
                steps
                tools
            }
            .padding(.bottom, Theme.Spacing.xl)
        }
    }

    /// The thin book bar with the time left at the current speed; the chapter slider under it.
    private var scrubbers: some View {
        let engine = model.engine
        let chapter = engine.currentChapter
        let rangeStart = chapter?.startMs ?? 0
        let rangeEnd = chapter?.endMs ?? engine.durationMs
        let inChapter = Double(max(0, min(engine.positionMs - rangeStart, rangeEnd - rangeStart)))
        let fraction = engine.durationMs > 0 ? Double(engine.positionMs) / Double(engine.durationMs) : 0
        return VStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView(value: min(max(fraction, 0), 1)).tint(Theme.Colors.muted).accessibilityHidden(true)
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.Colors.muted)
            }
            HStack {
                Text(ProgressText.clock(engine.positionMs)).accessibilityIdentifier("player.elapsed")
                Spacer()
                Text(ProgressText.leftAtSpeed(engine.durationMs - engine.positionMs, rate: engine.rate)).accessibilityIdentifier("player.remaining")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(Theme.Colors.muted)
            VStack(spacing: Theme.Spacing.xs) {
                Slider(
                    value: Binding(get: { scrubbing ?? inChapter }, set: { scrubbing = $0 }),
                    in: 0...Double(max(rangeEnd - rangeStart, 1))
                ) { editing in
                    if !editing, let scrubbing {
                        engine.seek(to: rangeStart + Int64(scrubbing))
                        self.scrubbing = nil
                    }
                }
                .tint(Theme.Colors.accent)
                .accessibilityIdentifier("player.scrubber")
                .accessibilityValue("\(ProgressText.clock(Int64(scrubbing ?? inChapter))) of \(ProgressText.clock(rangeEnd - rangeStart))")
                HStack {
                    Text(ProgressText.clock(Int64(scrubbing ?? inChapter)))
                    Spacer()
                    Text("-" + ProgressText.clock(max(rangeEnd - rangeStart - Int64(scrubbing ?? inChapter), 0)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.Colors.muted)
            }
            if let saved = engine.savedAheadMs {
                // How long the book plays on with no signal: worth knowing before the metro.
                Label("\(saved / 60_000) min saved", systemImage: "arrow.down.circle")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.Colors.muted)
                    .accessibilityIdentifier("player.savedAhead")
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
    }

    private var controls: some View {
        let engine = model.engine
        return HStack(spacing: Theme.Spacing.xxl) {
            control("gobackward.\(Int(engine.skipBackwardSecs))", String(localized: "Back \(Int(engine.skipBackwardSecs)) seconds"), id: "player.skipBackward", font: .title) { engine.skipBackward() }
            Button {
                Haptics.impact(.medium)
                engine.togglePlayPause()
            } label: {
                Group {
                    if engine.isLoading || engine.isBuffering {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64))
                    }
                }
                .foregroundStyle(Theme.Colors.foreground)
                .frame(width: 72, height: 72)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("player.playPause")
            .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")
            control("goforward.\(Int(engine.skipForwardSecs))", String(localized: "Forward \(Int(engine.skipForwardSecs)) seconds"), id: "player.skipForward", font: .title) { engine.skipForward() }
        }
    }

    /// Chapter steps, or files where a book has no chapters.
    private var steps: some View {
        let engine = model.engine
        return HStack(spacing: Theme.Spacing.xxl) {
            control("backward.end.alt", String(localized: "Previous chapter"), id: "player.previousChapter", font: .title3) { engine.previousChapter() }
            control("forward.end.alt", String(localized: "Next chapter"), id: "player.nextChapter", font: .title3) { engine.nextChapter() }
        }
    }

    private func control(_ symbol: String, _ label: String, id: String, font: Font, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            Image(systemName: symbol)
                .font(font)
                .foregroundStyle(Theme.Colors.foreground)
                .frame(minWidth: Theme.minTarget, minHeight: Theme.minTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
    }

    private var tools: some View {
        let engine = model.engine
        let sleeping = engine.sleepTimer.isActive || engine.stopsAtEndOfChapter
        // The tools share the width: five at fixed gaps are wider than a phone.
        return HStack(spacing: 0) {
            tool(id: "player.speed", label: String(localized: "Speed \(engine.rate.speedNumber)"), caption: "Speed", tinted: engine.rate != 1) {
                Text(engine.rate.speedText).font(.subheadline.weight(.semibold).monospacedDigit())
            } action: { sheet = .speed }
            tool(id: "player.sleep", label: String(localized: "Sleep Timer"), caption: "Sleep", tinted: sleeping) {
                Image(systemName: sleeping ? "moon.zzz.fill" : "moon.zzz").font(.title3)
            } action: { sheet = .sleep }
            tool(id: "player.bookmarks", label: String(localized: "Bookmarks"), caption: "Bookmarks", tinted: false) {
                Image(systemName: "bookmark").font(.title3)
            } action: { sheet = .bookmarks }
            tool(id: "player.chapters", label: String(localized: "Chapters"), caption: "Chapters", tinted: false) {
                Image(systemName: "list.bullet").font(.title3)
            } action: { sheet = .chapters }
            VStack(spacing: Theme.Spacing.xs) {
                AirPlayRouteButton().frame(width: 28, height: 24)
                Text("AirPlay").font(.caption2).foregroundStyle(Theme.Colors.foreground)
            }
            .frame(maxWidth: .infinity, minHeight: Theme.minTarget)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("player.airplay")
        }
        .padding(.top, Theme.Spacing.sm)
    }

    private func tool<Icon: View>(id: String, label: String, caption: LocalizedStringKey, tinted: Bool, @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Theme.Spacing.xs) {
                icon().frame(height: 24)
                Text(caption).font(.caption2)
            }
            .foregroundStyle(tinted ? Theme.Colors.accent : Theme.Colors.foreground)
            .frame(maxWidth: .infinity, minHeight: Theme.minTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
    }
}
