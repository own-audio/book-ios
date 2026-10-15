import Foundation

// Pictures chosen by the listener: a song's cover (an album's is its songs'), an artist's
// picture, a playlist's cover. These uploads are only in /api/v1 so far; the same access token
// works there.

extension OwnAudioClient {
    /// One of the caller's own tracks.
    public func uploadCover(trackId: String, image: Data, contentType: String = "image/jpeg") async throws {
        try await upload("music/tracks/\(trackId)/upload-cover", field: "cover", image: image, contentType: contentType)
    }

    /// The caller's picture for an artist, kept: the automatic lookup never replaces it.
    public func uploadArtistImage(name: String, image: Data, contentType: String = "image/jpeg") async throws {
        try await upload("music/artists/upload-image", query: ["artist": name], field: "image", image: image, contentType: contentType)
    }

    /// A multipart upload under `/api/v1`, with the access token; a `401` is answered once with
    /// a refresh, as every other request.
    func upload(_ path: String, query: [String: String?] = [:], field: String, image: Data, contentType: String) async throws {
        if isOffline() { throw OwnAudioError.offline }
        let boundary = "own-audio-\(UUID().uuidString)"
        let ext = contentType == "image/png" ? "png" : "jpg"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"picture.\(ext)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        body.append(image)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let build = { (token: String) throws -> URLRequest in
            var request = URLRequest(url: try url(path, query: query, api: "api/v1"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return request
        }
        let refresher = refresher()
        do {
            _ = try await Self.data(build(try await tokens.accessToken(using: refresher)), session: session)
        } catch OwnAudioError.http(401) {
            _ = try await Self.data(build(try await tokens.refresh(using: refresher).accessToken), session: session)
        } catch OwnAudioError.problem(let p) where p.status == 401 {
            _ = try await Self.data(build(try await tokens.refresh(using: refresher).accessToken), session: session)
        }
    }
}
