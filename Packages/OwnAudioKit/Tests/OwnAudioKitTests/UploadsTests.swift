import Foundation
import Testing

@testable import OwnAudioKit

@Suite("Uploads")
struct UploadsTests {
    @Test("an upload link is asked for with the exact size; the book names the upload ids with an idempotency key")
    func uploadAndBook() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/v2/uploads"):
                return .init(statusCode: 201, body: Data(#"{"upload_id":"u1","url":"https://storage.example.com/put/u1","method":"PUT","headers":{"Content-Type":"audio/mpeg"},"expires_at":"2026-10-16T01:00:00Z"}"#.utf8), headers: ["Content-Type": "application/json"])
            case ("POST", "/api/v2/books"):
                #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "import-1")
                return .init(statusCode: 201, body: Data(#"{"id":"b9","title":"Imported","credits":[],"visibility":"private","owner_id":"me","created_at":"2026-10-16T00:00:00Z","updated_at":"2026-10-16T00:00:00Z"}"#.utf8), headers: ["Content-Type": "application/json"])
            default:
                return .init(statusCode: 404, body: Data())
            }
        }
        let client = OwnAudioClient(host: URL(string: "https://books.example.com")!, tokens: TokenSession(Tokens(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600), scope: "")), session: mock.urlSession)
        let link = try await client.createUpload(kind: "book_file", filename: "01.mp3", contentType: "audio/mpeg", sizeBytes: 12345)
        #expect(link.uploadId == "u1" && link.method == "PUT" && link.headers["Content-Type"] == "audio/mpeg")
        let book = try await client.createBook(NewBook(title: "Imported", author: "A; B", narrator: nil, visibility: "private", files: [.init(uploadId: "u1", relativePath: "001 - 01.mp3", title: nil)]), idempotencyKey: "import-1")
        #expect(book.id == "b9")
        // Stubbed requests carry their body as a stream.
        let bodies = await mock.requestLog().map { request -> String in
            guard let stream = request.httpBodyStream else { return request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "" }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return String(decoding: data, as: UTF8.self)
        }
        #expect(bodies.first?.contains(#""size_bytes":12345"#) == true)
        #expect(bodies.last?.contains(#""relative_path":"001 - 01.mp3""#) == true)
    }
}

@Suite("Encoding")
struct EncodingDeterminismTests {
    /// The server keys idempotent requests on the body bytes: the same book must encode to the
    /// same bytes every time, or a retry is refused as "a different request".
    @Test("the same book encodes to the same bytes every time")
    func stableBytes() throws {
        let book = NewBook(title: "own.audio Books live test", author: "Test Author", narrator: "Test Narrator", visibility: "private", files: [.init(uploadId: "u/1", relativePath: "001 - silence.wav", title: "Silence")])
        let first = try JSONEncoder.ownAudio.encode(book)
        for _ in 0..<200 {
            let again = try JSONEncoder.ownAudio.encode(book)
            #expect(again == first, "\(String(decoding: first, as: UTF8.self)) vs \(String(decoding: again, as: UTF8.self))")
            if again != first { break }
        }
    }
}

@Suite("Narration")
struct NarrationTests {
    @Test("the estimate and the job go up as multipart; the body carries the fields and the file")
    func multipart() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("book-\(UUID().uuidString).txt")
        try "Chapter one. It was a dark and stormy night.".write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }
        let mock = await MockURLProtocol.makeStubbedSession { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/v2/narration/estimate"):
                #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
                return .init(statusCode: 200, body: Data(#"{"estimated_char_count":44}"#.utf8), headers: ["Content-Type": "application/json"])
            case ("POST", "/api/v2/narration/jobs"):
                return .init(statusCode: 201, body: Data(#"{"id":"j1","title":"Night","stages":["extracting","narrating","assembling"],"stage":"queued","error":null,"chapters":[],"download_url":null,"book_id":null,"quoted_price_cents":600,"actual_cost_cents":null,"charged_price_cents":null,"currency":"USD"}"#.utf8), headers: ["Content-Type": "application/json"])
            default:
                return .init(statusCode: 404, body: Data())
            }
        }
        let client = OwnAudioClient(host: URL(string: "https://books.example.com")!, tokens: TokenSession(Tokens(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600), scope: "")), session: mock.urlSession)
        let estimate = try await client.narrationEstimate(fileURL: source)
        #expect(estimate.estimatedCharCount == 44)
        let job = try await client.createNarration(fileURL: source, title: "Night", sourceLanguage: "en", targetLanguage: "en", voiceId: "v", output: .multiFile)
        #expect(job.id == "j1" && job.stage == "queued" && !job.isTerminal)

        // A file upload's body never reaches URLProtocol; the multipart file itself is checked.
        let body = try Multipart.write(fields: [("voice_profile_id", "v"), ("output_mode", "multi_file")], fileURL: source)
        defer { try? FileManager.default.removeItem(at: body.url) }
        let text = String(decoding: try Data(contentsOf: body.url), as: UTF8.self)
        #expect(text.hasPrefix("--\(body.boundary)\r\n"))
        #expect(text.contains("name=\"voice_profile_id\"\r\n\r\nv\r\n") && text.contains("name=\"output_mode\"\r\n\r\nmulti_file\r\n"))
        #expect(text.contains("name=\"file\"; filename=\"\(source.lastPathComponent)\"\r\nContent-Type: text/plain\r\n\r\nChapter one. It was a dark and stormy night."))
        #expect(text.hasSuffix("\r\n--\(body.boundary)--\r\n"))
    }
}
