import SwiftUI

/// Sits above the tab bar while a book is loaded, on material: cover, title, the time left,
/// play/pause and skip forward.
struct MiniPlayerBar: View {
    @Environment(AppModel.self) private var model
    let onTap: () -> Void

    var body: some View {
        if let book = model.nowPlayingBook, let serverId = model.nowPlayingServerId {
            let engine = model.engine
            Button {
                Haptics.impact(.medium)
                onTap()
            } label: {
                HStack(spacing: Theme.Spacing.md) {
                    CoverView(book: book, serverId: serverId, pointSize: 40, radius: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.Colors.foreground).lineLimit(1)
                        Text(ProgressText.leftAtSpeed(engine.durationMs - engine.positionMs, rate: engine.rate))
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.muted)
                            .lineLimit(1)
                    }
                    Spacer()
                    if engine.isLoading || engine.isBuffering {
                        ProgressView().frame(minWidth: Theme.minTarget, minHeight: Theme.minTarget)
                    } else {
                        Button {
                            Haptics.impact(.medium)
                            engine.togglePlayPause()
                        } label: {
                            Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3)
                                .foregroundStyle(Theme.Colors.foreground)
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
                            .foregroundStyle(Theme.Colors.foreground)
                            .frame(minWidth: Theme.minTarget, minHeight: Theme.minTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("miniPlayer.skipForward")
                    .accessibilityLabel("Skip forward \(Int(engine.skipForwardSecs)) seconds")
                }
                .padding(Theme.Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("miniPlayer")
            .accessibilityHint("Opens the player")
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.miniPlayer, style: .continuous))
            .overlay(alignment: .bottom) {
                // The book's progress as a thin line along the bottom edge.
                GeometryReader { geometry in
                    let fraction = engine.durationMs > 0 ? CGFloat(engine.positionMs) / CGFloat(engine.durationMs) : 0
                    Theme.Colors.accent.frame(width: geometry.size.width * min(max(fraction, 0), 1), height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.miniPlayer, style: .continuous))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, Theme.Spacing.screenEdge)
            .padding(.bottom, Theme.Spacing.xs)
        }
    }
}

extension ProgressText {
    /// "2 h 10 min left" at the speed the book plays at.
    static func leftAtSpeed(_ ms: Int64, rate: Float) -> String {
        let atSpeed = Int64(Double(max(ms, 0)) / Double(max(rate, 0.1)))
        return String(localized: "\(length(atSpeed)) left")
    }
}
