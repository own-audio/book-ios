import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The player on the lock screen and in the Dynamic Island: cover, title, chapter, how far,
/// and the three buttons that matter while the phone is locked.
struct BookLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BookActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color(light: 0xF7F7F8, dark: 0x0C0C0E))
                .widgetURL(URL(string: "ownbook://play/\(context.attributes.bookId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Cover(url: context.attributes.coverURL, size: 52)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(Remaining.text(context.state)).font(.caption).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let chapter = context.state.chapter { Text(chapter).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        ProgressBar(state: context.state)
                        Controls(state: context.state)
                    }
                }
            } compactLeading: {
                Cover(url: context.attributes.coverURL, size: 22)
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill").foregroundStyle(accent)
            } minimal: {
                Image(systemName: "book.closed.fill").foregroundStyle(accent)
            }
        }
    }
}

private let accent = Color(light: 0x7A4A2B, dark: 0xD7A97C)

private struct LockScreenView: View {
    let context: ActivityViewContext<BookActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Cover(url: context.attributes.coverURL, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(context.attributes.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(context.state.chapter ?? context.attributes.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                ProgressBar(state: context.state)
                HStack {
                    Text(Remaining.text(context.state)).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Controls(state: context.state)
                }
            }
        }
        .padding(14)
    }
}

/// The play/pause and skip buttons; each runs an intent in the app without opening it.
private struct Controls: View {
    let state: BookActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 18) {
            Button(intent: PlaybackControlIntent(.back)) { Image(systemName: "gobackward.15") }
                .accessibilityLabel("Skip back")
            Button(intent: PlaybackControlIntent(.toggle)) { Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").font(.title3) }
                .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
            Button(intent: PlaybackControlIntent(.forward)) { Image(systemName: "goforward.30") }
                .accessibilityLabel("Skip forward")
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent)
    }
}

private struct ProgressBar: View {
    let state: BookActivityAttributes.ContentState

    var body: some View {
        let fraction = state.durationMs > 0 ? min(max(Double(state.positionMs) / Double(state.durationMs), 0), 1) : 0
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(accent.opacity(0.2))
                Capsule().fill(accent).frame(width: max(geometry.size.width * fraction, 3))
            }
        }
        .frame(height: 4)
    }
}

private struct Cover: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        if let url, let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill().frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size / 6))
        } else {
            RoundedRectangle(cornerRadius: size / 6).fill(accent.opacity(0.15)).frame(width: size, height: size)
                .overlay { Image(systemName: "book.closed").font(.system(size: size / 2.5)).foregroundStyle(accent) }
        }
    }
}

private enum Remaining {
    static func text(_ state: BookActivityAttributes.ContentState) -> String {
        let minutes = Int((Double(max(state.durationMs - state.positionMs, 0)) / 60_000).rounded())
        let text = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        return String(localized: "\(text) left")
    }
}
