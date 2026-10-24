import Foundation

/// One file of a book as the engine plays it.
public struct SpokenPart: Sendable, Equatable, Identifiable {
    public let id: String
    public var url: URL
    public let durationMs: Int64
    /// An HLS playlist rather than a file (a server transcoding on the fly).
    public let isHLS: Bool
    /// The link is the original file and answers Range, so it can stream through the
    /// look-ahead window (`StreamWindow`); a transcode made as it goes can't.
    public let streamsByRange: Bool
    /// The server's content type for the file, for when its first bytes don't tell.
    public let contentType: String?

    public init(id: String, url: URL, durationMs: Int64, isHLS: Bool = false, streamsByRange: Bool = false, contentType: String? = nil) {
        self.id = id
        self.url = url
        self.durationMs = durationMs
        self.isHLS = isHLS
        self.streamsByRange = streamsByRange && !isHLS
        self.contentType = contentType
    }

    /// A part with no copy on the phone and no link yet (a partly downloaded book started with
    /// no network): the engine asks the app's locator and refresher when its turn comes.
    public static func unresolved(id: String, durationMs: Int64) -> SpokenPart {
        var components = URLComponents()
        components.scheme = unresolvedScheme
        components.path = id
        return SpokenPart(id: id, url: components.url ?? URL(string: "\(unresolvedScheme):part")!, durationMs: durationMs)
    }

    public static let unresolvedScheme = "spoken-unresolved"

    public var isUnresolved: Bool { url.scheme == Self.unresolvedScheme }
}

public struct SpokenChapter: Sendable, Equatable, Identifiable {
    public let title: String
    public let startMs: Int64
    public let endMs: Int64

    public init(title: String, startMs: Int64, endMs: Int64) {
        self.title = title
        self.startMs = startMs
        self.endMs = endMs
    }

    public var id: Int64 { startMs }
    public var durationMs: Int64 { endMs - startMs }
}

/// A book's files laid end to end, and the maths between book time and (part, offset). All
/// times are milliseconds of book time unless named otherwise.
public struct BookTimeline: Sendable, Equatable {
    public let parts: [SpokenPart]
    public let chapters: [SpokenChapter]
    /// Where each part begins.
    public let starts: [Int64]
    public let durationMs: Int64

    public init(parts: [SpokenPart], chapters: [SpokenChapter] = []) {
        self.parts = parts
        var starts: [Int64] = []
        var total: Int64 = 0
        for part in parts {
            starts.append(total)
            total += part.durationMs
        }
        self.starts = starts
        durationMs = total
        self.chapters = chapters.sorted { $0.startMs < $1.startMs }
    }

    public var isEmpty: Bool { parts.isEmpty }

    /// The part playing at `positionMs` and the offset in it. Past the end: the last part at
    /// its end; before the start: the first at 0.
    public func locate(_ positionMs: Int64) -> (index: Int, offsetMs: Int64)? {
        guard !parts.isEmpty else { return nil }
        let clamped = clamp(positionMs)
        var index = starts.lastIndex { $0 <= clamped } ?? 0
        // A position exactly at the end of the book stays in the last part.
        if index == parts.count { index = parts.count - 1 }
        return (index, clamped - starts[index])
    }

    public func position(partIndex: Int, offsetMs: Int64) -> Int64 {
        guard parts.indices.contains(partIndex) else { return 0 }
        return clamp(starts[partIndex] + offsetMs)
    }

    public func clamp(_ positionMs: Int64) -> Int64 {
        max(0, min(positionMs, durationMs))
    }

    public func index(ofPart id: String) -> Int? {
        parts.firstIndex { $0.id == id }
    }

    // MARK: - Chapters

    public func chapterIndex(at positionMs: Int64) -> Int? {
        guard !chapters.isEmpty else { return nil }
        let index = chapters.lastIndex { $0.startMs <= positionMs } ?? 0
        return index
    }

    public func chapter(at positionMs: Int64) -> SpokenChapter? {
        chapterIndex(at: positionMs).map { chapters[$0] }
    }

    /// Where the next chapter starts, or nil in the last one (the caller goes to the end).
    public func nextChapterStart(from positionMs: Int64) -> Int64? {
        chapters.first { $0.startMs > positionMs }?.startMs
    }

    /// The start of the current chapter — or of the one before it when the current one only
    /// just began (`graceMs`), as a track button does.
    public func previousChapterStart(from positionMs: Int64, graceMs: Int64 = 3000) -> Int64 {
        guard let index = chapterIndex(at: positionMs) else { return 0 }
        let current = chapters[index]
        if positionMs - current.startMs <= graceMs, index > 0 { return chapters[index - 1].startMs }
        return current.startMs
    }

    /// Where the current chapter — or, with no chapters, the current part — ends.
    public func endOfChapter(at positionMs: Int64) -> Int64 {
        if let chapter = chapter(at: positionMs) { return min(chapter.endMs, durationMs) }
        guard let (index, _) = locate(positionMs) else { return durationMs }
        return starts[index] + parts[index].durationMs
    }

    // MARK: - Skipping

    public func skipped(from positionMs: Int64, bySeconds seconds: Double) -> Int64 {
        clamp(positionMs + Int64((seconds * 1000).rounded()))
    }

    /// With no chapters, every part counts as one, so the chapter list and buttons still work.
    public static func chaptersFromParts(_ parts: [SpokenPart], titles: [String]? = nil) -> [SpokenChapter] {
        var start: Int64 = 0
        return parts.enumerated().map { index, part in
            defer { start += part.durationMs }
            let title = titles.flatMap { index < $0.count ? $0[index] : nil } ?? "Part \(index + 1)"
            return SpokenChapter(title: title, startMs: start, endMs: start + part.durationMs)
        }
    }
}
