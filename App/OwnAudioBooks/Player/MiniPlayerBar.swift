import SwiftUI

/// Sits above the tab bar while a book is loaded: a thin progress line, cover, title, chapter,
/// play/pause and skip forward.
struct MiniPlayerBar: View {
    @Environment(AppModel.self) private var model
    let onTap: () -> Void

    var body: some View {
        if let book = model.nowPlayingBook, let serverId = model.nowPlayingServerId {
            let engine = model.engine
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    let fraction = engine.durationMs > 0 ? CGFloat(engine.positionMs) / CGFloat(engine.durationMs) : 0
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color(.secondarySystemFill))
                        Rectangle().fill(Color.accentColor).frame(width: geometry.size.width * min(max(fraction, 0), 1))
                    }
                }
                .frame(height: 2)
                .accessibilityHidden(true)
                Button {
                    Haptics.impact(.medium)
                    onTap()
                } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        CoverView(book: book, serverId: serverId, pointSize: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(engine.currentChapter?.title ?? book.authorLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if engine.isLoading {
                            ProgressView().frame(minWidth: Theme.minTarget, minHeight: Theme.minTarget)
                        } else {
                            Button {
                                Haptics.impact(.medium)
                                engine.togglePlayPause()
                            } label: {
                                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title3)
                                    .frame(minWidth: Theme.minTarget, minHeight: Theme.minTarget)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("miniPlayer.playPause")
                            .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")
                        }
                        Button {
                            Haptics.impact(.light)
                            engine.skipForward()
                        } label: {
                            Image(systemName: "goforward.\(Int(engine.skipForwardSecs))")
                                .font(.title3)
                                .frame(minWidth: Theme.minTarget, minHeight: Theme.minTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("miniPlayer.skipForward")
                        .accessibilityLabel("Skip forward \(Int(engine.skipForwardSecs)) seconds")
                    }
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("miniPlayer")
                .accessibilityHint("Opens the player")
            }
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.miniPlayer)
                    .fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.miniPlayer).fill(Color.accentColor.opacity(0.15)))
            }
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.miniPlayer).strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.miniPlayer))
            .padding(.horizontal, Theme.Spacing.screenEdge)
            .padding(.bottom, Theme.Spacing.xs)
        }
    }
}
