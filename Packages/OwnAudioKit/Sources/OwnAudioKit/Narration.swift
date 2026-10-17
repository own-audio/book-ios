import Foundation

// Narration (hosted servers with the `narration` module): an ebook or a text file becomes an
// audiobook read by an AI voice, paid from the family's credit. `/api/v2/narration/…`; the
// bodies are the hosted service's own.

public struct NarrationLanguage: Decodable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String { code }
    public let code: String
    public let label: String
}

public struct NarrationVoice: Decodable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let displayName: String
    public let language: String
    public let gender: String
    public let previewUrl: String?
    public let costPerMillionCharsCents: Int
}

/// The server's own count of the characters it would read, from the file as unpacked there.
public struct NarrationEstimate: Decodable, Sendable, Equatable {
    public let estimatedCharCount: Int
}

public struct NarrationQuote: Decodable, Sendable, Equatable {
    public let charCount: Int
    public let translationCostCents: Int
    public let ttsCostCents: Int
    public let quotedPriceCents: Int
    public let currency: String
}

/// `single_m4b` is one file; `multi_file` a file per chapter.
public enum NarrationOutput: String, Sendable, CaseIterable {
    case multiFile = "multi_file"
    case singleM4B = "single_m4b"
}

/// A narration under way, or finished. `stage` can be `failed`, which is not among `stages`.
public struct NarrationJob: Decodable, Sendable, Equatable, Identifiable {
    public struct Chapter: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let status: String
        public let blocksDone: Int
        public let blocksTotal: Int
    }

    public let id: String
    public let title: String
    public let stages: [String]
    public let stage: String
    public let error: String?
    public let chapters: [Chapter]
    /// The finished book's id once it is published; the change feed brings the book itself.
    public let bookId: String?
    public let quotedPriceCents: Int
    public let chargedPriceCents: Int?
    public let currency: String

    public var isTerminal: Bool { stage == "complete" || stage == "failed" }
    public var hasFailed: Bool { stage == "failed" }

    public init(id: String, title: String, stages: [String], stage: String, error: String?, chapters: [Chapter], bookId: String?, quotedPriceCents: Int, chargedPriceCents: Int?, currency: String) {
        self.id = id
        self.title = title
        self.stages = stages
        self.stage = stage
        self.error = error
        self.chapters = chapters
        self.bookId = bookId
        self.quotedPriceCents = quotedPriceCents
        self.chargedPriceCents = chargedPriceCents
        self.currency = currency
    }
}

extension OwnAudioClient {
    public func narrationLanguages() async throws -> [NarrationLanguage] {
        try await get("narration/languages")
    }

    public func narrationVoices() async throws -> [NarrationVoice] {
        try await get("narration/voices")
    }

    /// Uploads the file so the server can count what it would read. Nothing is charged.
    public func narrationEstimate(fileURL: URL) async throws -> NarrationEstimate {
        try await uploadMultipart("narration/estimate", fields: [], fileURL: fileURL)
    }

    public func narrationQuote(charCount: Int, sourceLanguage: String, targetLanguage: String, voiceId: String) async throws -> NarrationQuote {
        struct Body: Encodable { let charCount: Int; let sourceLanguage: String; let targetLanguage: String; let voiceProfileId: String }
        return try await call("POST", "narration/quote", body: Body(charCount: charCount, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, voiceProfileId: voiceId))
    }

    /// Starts the narration; the file goes up again, there is no handle to the estimate's copy.
    public func createNarration(fileURL: URL, title: String, sourceLanguage: String, targetLanguage: String, voiceId: String, output: NarrationOutput) async throws -> NarrationJob {
        try await uploadMultipart("narration/jobs", fields: [
            ("title", title), ("source_language", sourceLanguage), ("target_language", targetLanguage),
            ("voice_profile_id", voiceId), ("output_mode", output.rawValue), ("cover_mode", "auto"), ("cover_show_title", "true"),
        ], fileURL: fileURL)
    }

    public func narration(id: String) async throws -> NarrationJob {
        try await get("narration/jobs/\(id)")
    }

    /// A multipart POST with the file streamed from disk, signed like every other call; one
    /// refresh and retry on a 401, as `fetch` does.
    private func uploadMultipart<T: Decodable>(_ path: String, fields: [(String, String)], fileURL: URL) async throws -> T {
        let body = try Multipart.write(fields: fields, fileURL: fileURL)
        defer { try? FileManager.default.removeItem(at: body.url) }
        let build = { (token: String) throws -> URLRequest in
            var request = URLRequest(url: try self.url(path, query: [:]))
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("multipart/form-data; boundary=\(body.boundary)", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 600
            return request
        }
        let refresher = refresher()
        let token = try await tokens.accessToken(using: refresher)
        let data: Data
        do {
            data = try await Self.upload(build(token), fromFile: body.url, session: session)
        } catch OwnAudioError.problem(let p) where p.status == 401 {
            let fresh = try await tokens.refresh(using: refresher)
            data = try await Self.upload(build(fresh.accessToken), fromFile: body.url, session: session)
        }
        do {
            return try JSONDecoder.ownAudio.decode(T.self, from: data)
        } catch {
            throw OwnAudioError.decoding
        }
    }

    static func upload(_ request: URLRequest, fromFile file: URL, session: URLSession) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, fromFile: file)
        } catch {
            throw OwnAudioError.network
        }
        guard let http = response as? HTTPURLResponse else { throw OwnAudioError.network }
        guard (200..<300).contains(http.statusCode) else {
            if let problem = try? JSONDecoder.ownAudio.decode(Problem.self, from: data) { throw OwnAudioError.problem(problem) }
            throw OwnAudioError.http(http.statusCode)
        }
        return data
    }
}

/// A multipart body on disk, so an ebook of tens of megabytes never sits in memory twice.
enum Multipart {
    struct Body {
        let url: URL
        let boundary: String
    }

    static func write(fields: [(String, String)], fileURL: URL) throws -> Body {
        let boundary = "own-audio-" + UUID().uuidString
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("multipart-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        for (name, value) in fields {
            out.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        let fileName = fileURL.lastPathComponent.replacingOccurrences(of: "\"", with: "")
        out.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: \(mimeType(for: fileURL))\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { out.write(chunk) }
        out.write(Data("\r\n--\(boundary)--\r\n".utf8))
        return Body(url: url, boundary: boundary)
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "epub": "application/epub+zip"
        case "mobi": "application/x-mobipocket-ebook"
        case "txt", "md": "text/plain"
        default: "application/octet-stream"
        }
    }
}
