import AVFoundation
import Foundation

/// A book as the app hands it to the engine: enough to play it and to show it on the lock
/// screen. The engine knows nothing about servers.
public struct SpokenBook: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let author: String?
    public let timeline: BookTimeline
    /// When the parts' links stop working; the engine asks the app for new ones before then.
    public var linksExpireAt: Date?

    public init(id: String, title: String, author: String?, parts: [SpokenPart], chapters: [SpokenChapter], linksExpireAt: Date? = nil) {
        self.id = id
        self.title = title
        self.author = author
        timeline = BookTimeline(parts: parts, chapters: chapters)
        self.linksExpireAt = linksExpireAt
    }

    /// The same book with one part's link replaced.
    public func replacing(partId: String, with url: URL) -> SpokenBook {
        var parts = timeline.parts
        if let index = parts.firstIndex(where: { $0.id == partId }) { parts[index].url = url }
        return SpokenBook(id: id, title: title, author: author, parts: parts, chapters: timeline.chapters, linksExpireAt: linksExpireAt)
    }
}

/// Chapter marks read from the files themselves (an M4B's chapter track, ID3 chapters), for
/// servers that know none. Works on a download and, over range requests, on a stream.
public enum EmbeddedChapters {
    /// The chapters of every part, moved to book time; empty when no part carries any.
    public static func read(_ parts: [SpokenPart]) async -> [SpokenChapter] {
        var out: [SpokenChapter] = []
        var start: Int64 = 0
        for part in parts {
            defer { start += part.durationMs }
            guard !part.isHLS else { continue }
            let asset = AVURLAsset(url: part.url)
            // The chapter track's own locale, whatever it is: asking for the device's locale
            // finds nothing in a file ffmpeg or a tagger marked as "und".
            guard let locales = try? await asset.load(.availableChapterLocales), let locale = locales.first,
                  let groups = try? await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: []),
                  !groups.isEmpty else { continue }
            for group in groups {
                let range = group.timeRange
                guard range.start.isNumeric else { continue }
                let startMs = start + Int64((range.start.seconds * 1000).rounded())
                let endMs = range.duration.isNumeric && range.duration.seconds > 0
                    ? startMs + Int64((range.duration.seconds * 1000).rounded())
                    : start + part.durationMs
                var title = "Chapter \(out.count + 1)"
                for item in group.items {
                    if let text = try? await item.load(.stringValue), !text.isEmpty { title = text; break }
                }
                out.append(SpokenChapter(title: title, startMs: startMs, endMs: endMs))
            }
        }
        return out
    }
}
