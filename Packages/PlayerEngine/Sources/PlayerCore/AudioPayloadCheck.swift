import Foundation

/// Decides whether bytes fetched from a server are plausibly audio at all.
///
/// Subsonic reports failures as **HTTP 200** with a JSON body
/// (`{"subsonic-response":{"status":"failed","error":{"code":70,…}}}`). A download that only
/// checks the status code writes that error text to disk as if it were a track — which is
/// exactly what happens after Navidrome renumbers its ids and starts answering "data not found".
///
/// Phrased as "is this audio?" rather than "is this a Subsonic error?" on purpose: it is the
/// same question for every source, it needs no knowledge of a protocol this package sits below,
/// and it also catches an HTML error page from a reverse proxy, which the narrower check would
/// wave through.
public enum AudioPayloadCheck {
    /// Container and codec magic numbers, at their documented offsets. Deliberately a list of
    /// what audio *is* rather than what it isn't: a new error format nobody predicted should
    /// fail closed, not sail through.
    private static let signatures: [(offset: Int, bytes: [UInt8])] = [
        (0, Array("ID3".utf8)),       // MP3 with an ID3v2 tag
        (0, [0xFF]),                  // a bare MPEG frame (MP3/AAC-ADTS)
        (0, Array("fLaC".utf8)),
        (0, Array("OggS".utf8)),
        (0, Array("RIFF".utf8)),      // WAV
        (0, Array("FORM".utf8)),      // AIFF
        (4, Array("ftyp".utf8)),      // MP4/M4A/M4B
        (0, Array("\u{1A}\u{45}\u{DF}\u{A3}".utf8)),  // Matroska/WebM
    ]

    /// A body this small cannot be a track. The real failures were 182 bytes; a legitimate
    /// audio file, even a very short one, carries far more header than this on its own.
    private static let minimumPlausibleBytes = 1024

    /// `contentType` is advisory — some servers send `application/octet-stream` for perfectly
    /// good audio, so it can only ever reject, never approve on its own.
    public static func looksLikeAudio(contentType: String?, prefix: Data) -> Bool {
        if let contentType = contentType?.lowercased() {
            for rejected in ["application/json", "text/", "application/xml", "text/xml"]
            where contentType.hasPrefix(rejected) || contentType.contains(rejected) {
                return false
            }
        }
        // A JSON object or an XML/HTML document, whatever the declared type says.
        if let first = prefix.first, first == UInt8(ascii: "{") || first == UInt8(ascii: "<") {
            return false
        }
        return signatures.contains { signature in
            guard prefix.count >= signature.offset + signature.bytes.count else { return false }
            let start = prefix.index(prefix.startIndex, offsetBy: signature.offset)
            return Array(prefix[start...].prefix(signature.bytes.count)) == signature.bytes
        }
    }

    /// The same question for a file already written to disk — reads only the head, so it stays
    /// cheap on a multi-hundred-megabyte download.
    public static func looksLikeAudio(contentType: String?, fileURL: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 64)) ?? Data()
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        guard (size ?? 0) >= minimumPlausibleBytes else { return false }
        return looksLikeAudio(contentType: contentType, prefix: prefix)
    }
}
