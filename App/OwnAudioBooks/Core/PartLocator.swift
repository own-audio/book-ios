import BookLibrary
import Foundation
import SpokenEngine

/// Where one file of a book plays from, decided per file every time it is needed — at play, on
/// a seek into another file, when the one before ends: the listener's download first, then the
/// listening cache, then the stream. A partly downloaded book plays what it has from the phone.
struct PartLocator {
    enum Source: Equatable {
        case downloaded(URL)
        case cached(URL)
        case stream

        var localURL: URL? {
            switch self {
            case .downloaded(let url), .cached(let url): url
            case .stream: nil
            }
        }
    }

    /// The listener's download of a file (`DownloadManager.fileURL`).
    var downloaded: @MainActor (_ compositeId: String, _ fileId: String) -> URL?
    /// A copy in the listening cache.
    var cached: @Sendable (_ compositeId: String, _ fileId: String) async -> URL?

    @MainActor
    func locate(compositeId: String, fileId: String) async -> Source {
        if let url = downloaded(compositeId, fileId) { return .downloaded(url) }
        if let url = await cached(compositeId, fileId) { return .cached(url) }
        return .stream
    }

    /// The engine's parts for a book: each file from the phone where it is there, else from
    /// `streams` (the play plan's links). With no streams (no network), a file not on the phone
    /// is left unresolved; the engine asks for it when its turn comes. An HLS part is the
    /// server's transcode of the whole book, never a copy on the phone.
    @MainActor
    func parts(compositeId: String, files: [(id: String, durationMs: Int64)], streams: [PlayPlan.Part]?) async -> [SpokenPart] {
        if let streams {
            var out: [SpokenPart] = []
            for part in streams {
                if !part.isHLS, let local = await locate(compositeId: compositeId, fileId: part.fileId).localURL {
                    out.append(SpokenPart(id: part.fileId, url: local, durationMs: part.durationMs))
                } else {
                    out.append(SpokenPart(id: part.fileId, url: part.url, durationMs: part.durationMs, isHLS: part.isHLS))
                }
            }
            return out
        }
        var out: [SpokenPart] = []
        for file in files {
            if let local = await locate(compositeId: compositeId, fileId: file.id).localURL {
                out.append(SpokenPart(id: file.id, url: local, durationMs: file.durationMs))
            } else {
                out.append(.unresolved(id: file.id, durationMs: file.durationMs))
            }
        }
        return out
    }
}

/// The engine asked for a file that is not on the phone while there is no network.
struct PartNotOnPhone: LocalizedError {
    var errorDescription: String? {
        String(localized: "This part of the book is not on this iPhone. It plays when there is a network again.")
    }
}
