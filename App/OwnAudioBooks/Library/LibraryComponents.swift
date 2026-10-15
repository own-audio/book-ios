import BookLibrary
import SwiftUI

/// What a screen is doing with the data it shows.
enum LoadState<Value> {
    case loading
    case loaded(Value)
    case failed(String)
}

struct LoadStateView<Value, Content: View>: View {
    let state: LoadState<Value>
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { retry() }.accessibilityIdentifier("load.retry")
            }
        case .loaded(let value):
            content(value)
        }
    }
}

/// A book's cover at a point size, from the app's cache.
struct CoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale
    let book: Book
    let serverId: UUID
    let pointSize: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous)
                .fill(Color(.secondarySystemFill))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity.animation(.easeOut(duration: Theme.coverCrossfade)))
            } else {
                Image(systemName: "book.closed")
                    .font(.system(size: pointSize * 0.35))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: pointSize, height: pointSize)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))
        .accessibilityHidden(true)
        .task(id: "\(book.id)|\(book.coverURL?.absoluteString ?? "")") {
            image = await model.coverImage(book, serverId: serverId, size: Int(pointSize * scale))
        }
    }
}

/// A card in a grid or a shelf: cover, title, author, and how far along the book is.
struct BookCard: View {
    @Environment(AppModel.self) private var model
    let book: Book
    let serverId: UUID
    var width: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            CoverView(book: book, serverId: serverId, pointSize: width)
                .overlay(alignment: .bottom) { progressBar }
            Text(book.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            Text(book.authorLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.title), \(book.authorLine)")
    }

    @ViewBuilder
    private var progressBar: some View {
        if let progress = model.knownProgress(book, serverId: serverId), book.durationMs > 0, !progress.finished, progress.positionMs > 0 {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.35))
                    Rectangle().fill(Color.accentColor).frame(width: geometry.size.width * CGFloat(progress.positionMs) / CGFloat(book.durationMs))
                }
            }
            .frame(height: 4)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: Theme.Radius.cover, bottomTrailingRadius: Theme.Radius.cover))
        }
    }
}

/// A row in a list: cover, title, author, length and time left.
struct BookRow: View {
    @Environment(AppModel.self) private var model
    let book: Book
    let serverId: UUID

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            CoverView(book: book, serverId: serverId, pointSize: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).font(.body).lineLimit(2)
                Text(book.authorLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(ProgressText.summary(book: book, progress: model.knownProgress(book, serverId: serverId)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if model.isNowPlaying(book, serverId: serverId) {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint).accessibilityLabel("Playing")
            }
        }
        .contentShape(Rectangle())
    }
}

/// Durations and positions as the screens say them.
enum ProgressText {
    /// "4 h 12 min", "38 min".
    static func length(_ ms: Int64) -> String {
        let minutes = Int((Double(ms) / 60_000).rounded())
        let hours = minutes / 60
        if hours > 0 {
            return minutes % 60 == 0 ? String(localized: "\(hours) h") : String(localized: "\(hours) h \(minutes % 60) min")
        }
        return String(localized: "\(max(minutes, 1)) min")
    }

    /// "4 h 12 min · 1 h 3 min left", "Finished", or the length alone.
    static func summary(book: Book, progress: ListeningProgress?) -> String {
        guard let progress, progress.positionMs > 0 || progress.finished else { return length(book.durationMs) }
        if progress.finished { return String(localized: "Finished") }
        let left = max(book.durationMs - progress.positionMs, 0)
        return String(localized: "\(length(book.durationMs)) · \(length(left)) left")
    }

    /// "1:02:07" or "3:07".
    static func clock(_ ms: Int64) -> String {
        formatDuration(Double(max(ms, 0)) / 1000)
    }
}
