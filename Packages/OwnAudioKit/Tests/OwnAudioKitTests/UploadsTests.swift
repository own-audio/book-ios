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
