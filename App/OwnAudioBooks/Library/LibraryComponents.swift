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

/// A book's cover at a point size, from the app's cache; a closed book stands in until it comes.
struct CoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale
    let book: Book
    let serverId: UUID
    let pointSize: CGFloat
    var radius: CGFloat = Theme.Radius.cover
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.Colors.backgroundAlt)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity.animation(.easeOut(duration: Theme.coverCrossfade)))
            } else {
                Image(systemName: "book.closed")
                    .font(.system(size: pointSize * 0.35))
                    .foregroundStyle(Theme.Colors.muted)
            }
        }
        .frame(width: pointSize, height: pointSize)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
        .task(id: "\(book.id)|\(book.coverURL?.absoluteString ?? "")") {
            image = await model.coverImage(book, serverId: serverId, size: Int(pointSize * scale))
        }
    }
}

/// A card in a grid or on a shelf: the cover with its badges in the corners, a progress bar
/// below when the book is started, then title and author.
struct BookCard: View {
    @Environment(AppModel.self) private var model
    let book: Book
    let serverId: UUID
    var width: CGFloat = 140
    /// For Continue Listening, where a tap plays rather than opens.
    var showsPlayOverlay = false
    var isFavourite = false

    var body: some View {
        let progress = model.knownProgress(book, serverId: serverId)
        let fraction = Self.fraction(book: book, progress: progress)
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            CoverView(book: book, serverId: serverId, pointSize: width)
                .overlay(alignment: .topTrailing) {
                    if book.visibility == .family { FamilyBadge().padding(6) }
                }
                .overlay(alignment: .topLeading) {
                    if isFavourite { FavouriteBadge().padding(6) }
                }
                .overlay(alignment: .bottomTrailing) {
                    DownloadBadge(state: model.downloadState(book, serverId: serverId)).padding(6)
                }
                .overlay {
                    if showsPlayOverlay {
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(.black.opacity(0.45), in: Circle())
                            .allowsHitTesting(false)
                    }
                }
            if let fraction {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView(value: fraction).tint(Theme.Colors.accent)
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.Colors.muted)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Colors.foreground)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(book.authorLine)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.muted)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.title), \(book.authorLine)")
    }

    static func fraction(book: Book, progress: ListeningProgress?) -> Double? {
        guard let progress, book.durationMs > 0, progress.positionMs > 0 || progress.finished else { return nil }
        return progress.finished ? 1 : min(1, Double(progress.positionMs) / Double(book.durationMs))
    }
}

/// A row in a list: a 56-pt cover, title, author, and how far along the book is.
struct BookRow: View {
    @Environment(AppModel.self) private var model
    let book: Book
    let serverId: UUID

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            CoverView(book: book, serverId: serverId, pointSize: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).font(.body.weight(.semibold)).foregroundStyle(Theme.Colors.foreground).lineLimit(2)
                Text(book.authorLine).font(.subheadline).foregroundStyle(Theme.Colors.muted).lineLimit(1)
                Text(ProgressText.summary(book: book, progress: model.knownProgress(book, serverId: serverId)))
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.muted)
            }
            Spacer(minLength: 0)
            if model.isNowPlaying(book, serverId: serverId) {
                NowPlayingIndicator(isPlaying: model.engine.isPlaying)
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
