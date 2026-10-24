import SwiftUI
import WidgetKit

@main
struct OwnAudioBooksWidgets: WidgetBundle {
    var body: some Widget {
        ContinueListeningWidget()
    }
}

/// The last books, a tap away: one on the small widget, three on the medium. Everything comes
/// from the snapshot the app keeps in the App Group; a tap opens the app on that book.
struct ContinueListeningWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "audio.own.bookplayer.continue", provider: Provider()) { entry in
            ContinueListeningView(entry: entry)
                .containerBackground(for: .widget) { Color(light: 0xF7F7F8, dark: 0x0C0C0E) }
        }
        .configurationDisplayName("Continue Listening")
        .description("Your last books, a tap away.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let books: [WidgetSnapshot.Entry]
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, books: [.init(id: "placeholder", title: "The Time Machine", author: "H. G. Wells", fraction: 0.4, remainingMs: 2 * 3_600_000, cover: nil)])
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, books: WidgetSnapshot.load()?.entries ?? placeholder(in: context).books))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // The app reloads the timeline itself when something changes; nothing to schedule.
        completion(Timeline(entries: [Entry(date: .now, books: WidgetSnapshot.load()?.entries ?? [])], policy: .never))
    }
}

private let accent = Color(light: 0x7A4A2B, dark: 0xD7A97C)
private let muted = Color(light: 0x6E6E73, dark: 0x98989D)

struct ContinueListeningView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        if entry.books.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "book").font(.title2).foregroundStyle(accent)
                Text("Nothing started yet").font(.caption).foregroundStyle(muted).multilineTextAlignment(.center)
            }
        } else if family == .systemSmall, let book = entry.books[0] as WidgetSnapshot.Entry? {
            small(book).widgetURL(WidgetSnapshot.playURL(for: book.id))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(entry.books.prefix(3)) { book in
                    Link(destination: WidgetSnapshot.playURL(for: book.id) ?? URL(string: "\(WidgetSnapshot.scheme)://")!) { row(book) }
                }
            }
        }
    }

    private func small(_ book: WidgetSnapshot.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            cover(book, size: 56)
            Spacer(minLength: 0)
            Text(book.title).font(.caption.weight(.semibold)).lineLimit(2)
            bar(book)
            Text(remaining(book)).font(.caption2).foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func row(_ book: WidgetSnapshot.Entry) -> some View {
        HStack(spacing: 10) {
            cover(book, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title).font(.caption.weight(.semibold)).lineLimit(1)
                if !book.author.isEmpty { Text(book.author).font(.caption2).foregroundStyle(muted).lineLimit(1) }
                bar(book)
            }
            Spacer(minLength: 0)
            Text(remaining(book)).font(.caption2).foregroundStyle(muted)
        }
    }

    @ViewBuilder
    private func cover(_ book: WidgetSnapshot.Entry, size: CGFloat) -> some View {
        if let data = book.cover, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill().frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.15)).frame(width: size, height: size)
                .overlay { Image(systemName: "book.closed").foregroundStyle(accent) }
        }
    }

    private func bar(_ book: WidgetSnapshot.Entry) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(accent.opacity(0.2))
                Capsule().fill(accent).frame(width: max(geometry.size.width * book.fraction, 3))
            }
        }
        .frame(height: 4)
    }

    private func remaining(_ book: WidgetSnapshot.Entry) -> String {
        let minutes = Int((Double(book.remainingMs) / 60_000).rounded())
        let text = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        return String(localized: "\(text) left")
    }
}

extension Color {
    /// One colour for each appearance, as the app's theme has them.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}
