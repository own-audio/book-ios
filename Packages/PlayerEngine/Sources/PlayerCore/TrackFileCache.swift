import Foundation

/// Finds audio for a track id: a downloaded copy if there is one, otherwise the remote URL to
/// stream from, or a full download into a temporary cache.
///
/// `AVAudioFile` only reads local files, so gapless scheduling of the *next* track needs it
/// complete on disk; the current track can stream (`stream`). The temporary cache is separate
/// from the listener's own downloads: a track played once shouldn't count as downloaded.
public actor TrackFileCache {
    /// The remote URL for a track id. Supplied by the app, which knows which server a track
    /// belongs to; the engine doesn't.
    public typealias RemoteURLResolver = @Sendable (String) async throws -> URL
    /// A permanently downloaded copy, if any.
    public typealias LocalFileLookup = @Sendable (String) async -> URL?

    private let remoteURL: RemoteURLResolver
    private var localFile: LocalFileLookup?
    private let session: URLSession
    /// So a quick next/previous during a download doesn't start a second one.
    private var inFlight: [String: Task<URL, Error>] = [:]
    private let cacheDirectory: URL
    /// Where own.audio storage is blocked, its files come through the server's media proxy.
    public nonisolated let storageRoute: ProxyMemory?

    public init(remoteURL: @escaping RemoteURLResolver, session: URLSession = .shared, cacheDirectory: URL? = nil, storageRoute: ProxyMemory? = nil) {
        self.remoteURL = remoteURL
        self.session = session
        self.storageRoute = storageRoute
        self.cacheDirectory = cacheDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("player-engine-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }

    public func setLocalFileLookup(_ lookup: @escaping LocalFileLookup) {
        localFile = lookup
    }

    public func resolveRemoteURL(trackId: String) async throws -> URL {
        try await remoteURL(trackId)
    }

    /// The session downloads go through, for engines that stream with the same one.
    public nonisolated var urlSession: URLSession { session }

    /// A local file if one already exists, without starting a download; that is the decision
    /// between streaming and playing from disk.
    public func existingLocalURL(trackId: String) async -> URL? {
        if let downloaded = await localFile?(trackId) { return downloaded }
        guard let cached = existingCachedFile(trackId: trackId) else { return nil }
        // Found is used: `enforce` lets the oldest go first.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cached.path)
        return cached
    }

    /// A local file for `trackId`, downloading it into the cache first if needed.
    public func localURL(trackId: String) async throws -> URL {
        if let existing = await existingLocalURL(trackId: trackId) { return existing }
        if let task = inFlight[trackId] { return try await task.value }

        let task = Task { try await download(trackId: trackId) }
        inFlight[trackId] = task
        defer { inFlight[trackId] = nil }
        return try await task.value
    }

    /// Starts or joins a download without waiting for it.
    public func prefetch(trackId: String) {
        guard inFlight[trackId] == nil, existingCachedFile(trackId: trackId) == nil else { return }
        Task { _ = try? await localURL(trackId: trackId) }
    }

    /// What the cache holds, in bytes.
    public func totalBytes() -> Int64 {
        (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]))?
            .reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } ?? 0
    }

    /// Lets the least recently used files go until the cache fits `capBytes`; a file is "used"
    /// when it is found by `existingLocalURL`, which moves its date forward.
    public func enforce(capBytes: Int64) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var entries = files.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let size = values.fileSize else { return nil }
            return (url, Int64(size), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > capBytes {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }

    /// Empties the temporary cache, e.g. when a server is removed.
    public func clear() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private func cacheFileName(trackId: String) -> String {
        // Ids are opaque and may contain characters a file name can't.
        Data(trackId.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }

    private func existingCachedFile(trackId: String) -> URL? {
        let name = cacheFileName(trackId: trackId)
        return try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
            .first { $0.deletingPathExtension().lastPathComponent == name }
    }

    private func download(trackId: String) async throws -> URL {
        let url = try await remoteURL(trackId)
        let session = session
        let tempURL: URL, response: URLResponse
        if let storageRoute {
            (tempURL, response) = try await storageRoute.fetch(url) { try await session.download(from: $0) }
        } else {
            (tempURL, response) = try await session.download(from: url)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw PlaybackError.network("Could not download track \(trackId)")
        }
        // Subsonic servers report errors as HTTP 200 with a JSON body.
        guard AudioPayloadCheck.looksLikeAudio(contentType: http.mimeType, fileURL: tempURL) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw PlaybackError.network("Server sent an error instead of track \(trackId)")
        }
        // AVAudioFile picks its parser partly by extension, and Subsonic stream URLs end in
        // `stream.view`. The file's own magic bytes win over the content type, which servers
        // get wrong.
        let head = (try? FileHandle(forReadingFrom: tempURL)).flatMap { handle in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 12)
        } ?? Data()
        let ext = Self.fileExtension(prefix: head) ?? Self.fileExtension(mimeType: http.mimeType) ?? "audio"
        let destination = cacheDirectory.appendingPathComponent("\(cacheFileName(trackId: trackId)).\(ext)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    public static func fileExtension(prefix: Data) -> String? {
        let bytes = Array(prefix.prefix(12))
        func starts(_ text: String, at offset: Int = 0) -> Bool {
            let magic = Array(text.utf8)
            return bytes.count >= offset + magic.count && Array(bytes[offset..<offset + magic.count]) == magic
        }
        if starts("ftyp", at: 4) { return "m4a" }
        if starts("fLaC") { return "flac" }
        if starts("OggS") { return "ogg" }
        if starts("RIFF") { return "wav" }
        if starts("FORM") { return "aiff" }
        if starts("ID3") || (bytes.count >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) { return "mp3" }
        return nil
    }

    public static func fileExtension(mimeType: String?) -> String? {
        switch mimeType?.lowercased() {
        case "audio/mpeg", "audio/mp3": "mp3"
        case "audio/flac", "audio/x-flac": "flac"
        case "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac": "m4a"
        case "audio/ogg", "audio/opus": "ogg"
        case "audio/wav", "audio/x-wav", "audio/wave": "wav"
        case "audio/aiff", "audio/x-aiff": "aiff"
        default: nil
        }
    }
}
