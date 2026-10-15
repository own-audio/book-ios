import Foundation
import Testing

@testable import OwnAudioKit

@Suite("The listener's own pictures")
struct ArtworkTests {
    private let host = URL(string: "https://music.example.com")!

    private func client(_ session: URLSession) -> OwnAudioClient {
        OwnAudioClient(host: host, tokens: TokenSession(Tokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture, scope: "")), session: session)
    }

    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    @Test("a song's cover: a multipart `cover` to the song, with the access token")
    func songCover() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 200, body: Data("{}".utf8)) }
        try await client(mock.urlSession).uploadCover(trackId: "t1", image: Data([0xFF, 0xD8, 0xFF, 0xE0]))
        let request = try #require(await mock.requestLog().first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/music/tracks/t1/upload-cover")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer a")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let text = String(decoding: Self.body(request), as: UTF8.self)
        #expect(text.contains("name=\"cover\"") && text.contains("Content-Type: image/jpeg"))
    }

    @Test("an artist's picture goes by the artist's name, as `image`")
    func artistPicture() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 201, body: Data()) }
        try await client(mock.urlSession).uploadArtistImage(name: "Kai Engel", image: Data([1, 2, 3]))
        let request = try #require(await mock.requestLog().first)
        #expect(request.url?.path == "/api/v1/music/artists/upload-image")
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "artist" }?.value == "Kai Engel")
        #expect(String(decoding: Self.body(request), as: UTF8.self).contains("name=\"image\""))
    }

    @Test("someone else's song is refused, and says so")
    func refused() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 404, body: Data(#"{"error":"not_found"}"#.utf8), headers: ["Content-Type": "application/json"])
        }
        await #expect(throws: OwnAudioError.self) { try await client(mock.urlSession).uploadCover(trackId: "x", image: Data([1])) }
    }
}
