import AVFoundation
import Foundation

/// What an audio file says about itself, to fill the import form before the listener types
/// anything: the tags, the duration, and the type the server is told.
public struct ImportMetadata: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var durationMs: Int64
    public var contentType: String
    public var artwork: Data?

    /// Reads `url` (a security-scoped file from the document picker included; the caller
    /// holds the access).
    public static func read(_ url: URL) async -> ImportMetadata {
        let asset = AVURLAsset(url: url)
        var out = ImportMetadata(title: nil, artist: nil, album: nil, durationMs: 0, contentType: contentType(for: url), artwork: nil)
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            out.durationMs = Int64((duration.seconds * 1000).rounded())
        }
        guard let items = try? await asset.load(.commonMetadata) else { return out }
        for item in items {
            switch item.commonKey {
            case .commonKeyTitle?: out.title = (try? await item.load(.stringValue)) ?? out.title
            case .commonKeyArtist?: out.artist = (try? await item.load(.stringValue)) ?? out.artist
            case .commonKeyAlbumName?: out.album = (try? await item.load(.stringValue)) ?? out.album
            case .commonKeyArtwork?: out.artwork = (try? await item.load(.dataValue)) ?? out.artwork
            default: break
            }
        }
        return out
    }

    /// The MIME type from the file's extension, which is what storage and the server go by.
    public static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": "audio/mpeg"
        case "m4a", "m4b", "mp4", "aac": "audio/mp4"
        case "flac": "audio/flac"
        case "wav": "audio/wav"
        case "aiff", "aif": "audio/aiff"
        case "ogg", "oga", "opus": "audio/ogg"
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        default: "application/octet-stream"
        }
    }

    public static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "mp4", "aac", "flac", "wav", "aiff", "aif", "ogg", "oga", "opus"]
}
