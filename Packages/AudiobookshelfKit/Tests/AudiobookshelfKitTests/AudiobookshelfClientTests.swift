import Foundation
import Testing

@testable import AudiobookshelfKit

@Suite("AudiobookshelfClient")
struct AudiobookshelfClientTests {
    private let host = URL(string: "http://books.example.com:13378")!

    private func json(_ text: String, status: Int = 200, type: String = "application/json") -> MockURLProtocol.StubbedResponse {
        .init(statusCode: status, body: Data(text.utf8), headers: ["Content-Type": type])
    }

    private func text(_ text: String, status: Int = 200) -> MockURLProtocol.StubbedResponse {
        .init(statusCode: status, body: Data(text.utf8), headers: ["Content-Type": "text/html; charset=utf-8"])
    }

    /// A JWT whose `exp` is `expiresIn` seconds from now; the signature is not checked by anyone.
    private func jwt(expiresIn: TimeInterval, id: String = "a1") -> String {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let exp = Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970)
        return "\(b64(#"{"alg":"HS256","typ":"JWT"}"#)).\(b64(#"{"userId":"u1","username":"booktest","jti":"\#(id)","type":"access","iat":\#(exp - 3600),"exp":\#(exp)}"#)).sig"
    }

    private func userJSON(access: String?, refresh: String? = "r1", legacy: String? = nil) -> String {
        let a = access.map { #""accessToken":"\#($0)","# } ?? ""
        let r = refresh.map { #""refreshToken":"\#($0)","# } ?? ""
        let l = legacy.map { #""token":"\#($0)","# } ?? ""
        return #"{"user":{"id":"u1","username":"booktest","type":"user",\#(a)\#(r)\#(l)"mediaProgress":[{"id":"p1","userId":"u1","libraryItemId":"li1","episodeId":null,"mediaItemId":"b1","mediaItemType":"book","duration":3780.85,"progress":0.0318,"currentTime":120.25,"isFinished":false,"hideFromContinueListening":false,"ebookLocation":null,"ebookProgress":0,"lastUpdate":1792091696595,"startedAt":1792091696595,"finishedAt":null}],"bookmarks":[{"libraryItemId":"li1","time":90,"title":"probe","createdAt":1792091696595}],"permissions":{"download":true,"update":false,"delete":false,"upload":false,"accessAllLibraries":true},"librariesAccessible":[]},"userDefaultLibraryId":"lib1","serverSettings":{"id":"s","version":"2.37.1"},"ereaderDevices":[],"Source":"docker"}"#
    }

    private func body(_ request: URLRequest) -> [String: Any] {
        let data = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        } ?? Data()
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    actor Kept: TokenKeeper {
        var saved: [Tokens?] = []
        func save(_ tokens: Tokens?) async { saved.append(tokens) }
    }

    // MARK: - Before signing in

    @Test("status names the server, its version and its sign-in methods")
    func status() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            #expect(request.url?.path == "/status")
            return json(#"{"app":"audiobookshelf","serverVersion":"2.37.1","isInit":true,"language":"cs","authMethods":["local"],"authFormData":{"authLoginCustomMessage":""}}"#)
        }
        let s = try await AudiobookshelfClient.status(host: host, session: mock.urlSession)
        #expect(s.version == ServerVersion("2.37.1"))
        #expect(s.version >= ServerVersion.rotatingTokens)
        #expect(s.authMethods == ["local"])
    }

    @Test("a server that is not Audiobookshelf is refused")
    func notAudiobookshelf() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in json(#"{"app":"navidrome"}"#) }
        await #expect(throws: AudiobookshelfError.decoding) {
            _ = try await AudiobookshelfClient.status(host: host, session: mock.urlSession)
        }
    }

    @Test("typed addresses: bare hosts get http, a scheme is kept, a slash is dropped")
    func typedAddress() {
        #expect(AudiobookshelfClient.url(fromTyped: "nas.local:13378")?.absoluteString == "http://nas.local:13378")
        #expect(AudiobookshelfClient.url(fromTyped: " https://books.example.com/ ")?.absoluteString == "https://books.example.com")
        #expect(AudiobookshelfClient.url(fromTyped: "") == nil)
    }

    @Test("sign-in on 2.26+: tokens asked for in the body, the JWT's exp becomes the expiry")
    func signInRotating() async throws {
        let access = jwt(expiresIn: 3600)
        let mock = await MockURLProtocol.makeStubbedSession { request in
            #expect(request.url?.path == "/login")
            #expect(request.value(forHTTPHeaderField: "x-return-tokens") == "true")
            #expect(body(request)["username"] as? String == "booktest")
            return json(userJSON(access: access))
        }
        let s = try await AudiobookshelfClient.signIn(host: host, username: "booktest", password: "pw", session: mock.urlSession)
        #expect(s.tokens.accessToken == access)
        #expect(s.tokens.refreshToken == "r1")
        #expect(abs(s.tokens.expiresAt.timeIntervalSinceNow - 3600) < 5)
        #expect(s.user.mediaProgress.first?.currentTime == 120.25)
        #expect(s.user.bookmarks.first?.time == 90)
        #expect(s.defaultLibraryId == "lib1")
        #expect(s.serverVersion == ServerVersion("2.37.1"))
    }

    @Test("sign-in before 2.26: the one token never expires and there is nothing to refresh with")
    func signInLegacy() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in json(userJSON(access: nil, refresh: nil, legacy: "legacy1")) }
        let s = try await AudiobookshelfClient.signIn(host: host, username: "booktest", password: "pw", session: mock.urlSession)
        #expect(s.tokens.accessToken == "legacy1")
        #expect(s.tokens.refreshToken == nil)
        #expect(s.tokens.expiresAt == .distantFuture)
    }

    @Test("a wrong password is invalidCredentials")
    func wrongPassword() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in text("Unauthorized", status: 401) }
        await #expect(throws: AudiobookshelfError.invalidCredentials) {
            _ = try await AudiobookshelfClient.signIn(host: host, username: "booktest", password: "no", session: mock.urlSession)
        }
    }

    // MARK: - Tokens

    @Test("a 401 is answered with one refresh (x-refresh-token) and one retry; the rotated tokens are kept")
    func refreshOn401() async throws {
        let fresh = jwt(expiresIn: 3600, id: "a2")
        let mock = await MockURLProtocol.makeStubbedSession { request in
            switch request.url?.path {
            case "/auth/refresh":
                #expect(request.value(forHTTPHeaderField: "x-refresh-token") == "r1")
                return json(userJSON(access: fresh, refresh: "r2"))
            case "/api/libraries":
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fresh)" {
                    return json(#"{"libraries":[{"id":"lib1","name":"Books","mediaType":"book"},{"id":"lib2","name":"Pods","mediaType":"podcast"}]}"#)
                }
                return text("Unauthorized", status: 401)
            default:
                return text("Not Found", status: 404)
            }
        }
        let kept = Kept()
        let tokens = TokenSession(Tokens(accessToken: jwt(expiresIn: 3600), refreshToken: "r1", expiresAt: Date().addingTimeInterval(3600)), keeper: kept)
        let client = AudiobookshelfClient(host: host, tokens: tokens, session: mock.urlSession)
        let libraries = try await client.bookLibraries()
        #expect(libraries.map(\.id) == ["lib1"])
        #expect(await kept.saved.last??.refreshToken == "r2")
        #expect(await mock.requestLog().map { $0.url!.path } == ["/api/libraries", "/auth/refresh", "/api/libraries"])
    }

    @Test("requests that find the token about to expire share one refresh")
    func singleFlightRefresh() async throws {
        let fresh = jwt(expiresIn: 3600, id: "a2")
        let mock = await MockURLProtocol.makeStubbedSession { request in
            switch request.url?.path {
            case "/auth/refresh":
                try await Task.sleep(for: .milliseconds(50))
                return json(userJSON(access: fresh, refresh: "r2"))
            default:
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fresh)")
                return json(#"{"libraries":[]}"#)
            }
        }
        let tokens = TokenSession(Tokens(accessToken: "old", refreshToken: "r1", expiresAt: Date().addingTimeInterval(10)))
        let client = AudiobookshelfClient(host: host, tokens: tokens, session: mock.urlSession)
        async let a = client.bookLibraries()
        async let b = client.bookLibraries()
        async let c = client.bookLibraries()
        _ = try await (a, b, c)
        let refreshes = await mock.requestLog().filter { $0.url?.path == "/auth/refresh" }.count
        #expect(refreshes == 1)
    }

    @Test("a refused refresh signs out")
    func refusedRefresh() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            request.url?.path == "/auth/refresh" ? text("Unauthorized", status: 401) : text("Unauthorized", status: 401)
        }
        let kept = Kept()
        let tokens = TokenSession(Tokens(accessToken: "old", refreshToken: "r1", expiresAt: Date().addingTimeInterval(3600)), keeper: kept)
        let client = AudiobookshelfClient(host: host, tokens: tokens, session: mock.urlSession)
        await #expect(throws: AudiobookshelfError.signedOut) { _ = try await client.bookLibraries() }
        #expect(await kept.saved.last! == nil)
        #expect(await tokens.current == nil)
    }

    @Test("a legacy token that gets a 401 is signed out, not refreshed")
    func legacy401() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in text("Unauthorized", status: 401) }
        let tokens = TokenSession(Tokens(accessToken: "legacy", refreshToken: nil, expiresAt: .distantFuture))
        let client = AudiobookshelfClient(host: host, tokens: tokens, session: mock.urlSession)
        await #expect(throws: AudiobookshelfError.signedOut) { _ = try await client.bookLibraries() }
        #expect(await mock.requestLog().count == 1)
    }

    // MARK: - Lists

    @Test("items: page, sort, direction and a URL-safe base64 filter")
    func itemsQuery() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            json(#"{"results":[],"total":71,"limit":50,"page":1,"sortBy":"media.metadata.title","sortDesc":true,"mediaType":"book","minified":false,"collapseseries":false}"#)
        }
        let client = AudiobookshelfClient(host: host, tokens: TokenSession(Tokens(accessToken: "t", refreshToken: nil, expiresAt: .distantFuture)), session: mock.urlSession)
        let page = try await client.items(libraryId: "lib1", page: 1, limit: 50, sort: .title, descending: true, filter: .progress(.inProgress))
        #expect(page.total == 71 && page.hasMore == false)
        let q = Dictionary(uniqueKeysWithValues: await mock.firstQuery().map { ($0.name, $0.value ?? "") })
        #expect(q["page"] == "1" && q["limit"] == "50" && q["sort"] == "media.metadata.title" && q["desc"] == "1")
        #expect(q["filter"] == "progress.aW4tcHJvZ3Jlc3M")
        #expect(q["collapseseries"] == nil)
        #expect(AudiobookshelfClient.ItemFilter.series(id: "8b5e58af").value == "series.OGI1ZTU4YWY")
    }

    @Test("a list row decodes with its strings, a detail with chapters, tracks, authors and series")
    func itemShapes() throws {
        let row = #"{"id":"li1","ino":"1234","libraryId":"lib1","folderId":"f","path":"/books/x","relPath":"x","isFile":false,"mtimeMs":1,"ctimeMs":1,"birthtimeMs":1,"addedAt":1792000000000,"updatedAt":1792000000000,"isMissing":false,"isInvalid":false,"mediaType":"book","media":{"id":"b1","metadata":{"title":"1984","titleIgnorePrefix":"1984","subtitle":null,"authorName":"George Orwell","authorNameLF":"Orwell, George","narratorName":"","seriesName":"","genres":["Fiction"],"publishedYear":"1949","publishedDate":null,"publisher":null,"description":"d","isbn":null,"asin":null,"language":null,"explicit":false,"abridged":false},"coverPath":"/c.jpg","tags":[],"numTracks":10,"numAudioFiles":10,"numChapters":10,"duration":3780.85,"size":97160062},"numFiles":11,"size":97160062}"#
        let item = try JSONDecoder.audiobookshelf.decode(LibraryItem.self, from: Data(row.utf8))
        #expect(item.media.metadata.authorName == "George Orwell")
        #expect(item.media.metadata.publishedYear == "1949")
        #expect(item.media.chapters == nil)

        let detail = #"{"id":"li1","ino":1234,"libraryId":"lib1","addedAt":1,"updatedAt":1,"isMissing":false,"isInvalid":false,"mediaType":"book","media":{"id":"b1","metadata":{"title":"Ender","authors":[{"id":"a1","name":"Orson Scott Card"}],"narrators":["Stefan Rudnicki"],"series":[{"id":"s1","name":"Ender's Game Series","sequence":"1.5"}],"genres":[],"explicit":false,"abridged":false},"coverPath":null,"tags":[],"duration":100.5,"chapters":[{"id":0,"start":0,"end":50.25,"title":"One"},{"id":1,"start":50.25,"end":100.5,"title":"Two"}],"audioFiles":[{"index":1,"ino":17088,"duration":100.5,"mimeType":"audio/mpeg","metadata":{"filename":"a.mp3","ext":".mp3","size":1000}}],"tracks":[{"index":1,"startOffset":0,"duration":100.5,"title":"a.mp3","contentUrl":"/api/items/li1/file/17088","mimeType":"audio/mpeg","ino":17088,"codec":"mp3","bitRate":128000,"metadata":{"ext":".mp3","size":1000}}]},"userMediaProgress":{"id":"p1","userId":"u1","libraryItemId":"li1","episodeId":null,"duration":100.5,"progress":0.5,"currentTime":50.25,"isFinished":false,"hideFromContinueListening":false,"lastUpdate":1,"startedAt":1,"finishedAt":null}}"#
        let book = try JSONDecoder.audiobookshelf.decode(LibraryItem.self, from: Data(detail.utf8))
        #expect(book.ino == "1234")
        #expect(book.media.chapters?.map(\.title) == ["One", "Two"])
        #expect(book.media.tracks?.first?.ino == "17088")
        #expect(book.media.tracks?.first?.contentUrl == "/api/items/li1/file/17088")
        #expect(book.media.metadata.series?.first?.sequence == "1.5")
        #expect(book.media.metadata.narrators == ["Stefan Rudnicki"])
        #expect(book.userMediaProgress?.currentTime == 50.25)

        // Filtered by a series, a row carries that series as one object.
        let bySeries = #"{"id":"li2","libraryId":"lib1","addedAt":1,"updatedAt":1,"isMissing":false,"isInvalid":false,"mediaType":"book","media":{"metadata":{"title":"Speaker","series":{"id":"s1","name":"Ender's Game Series","sequence":"2"},"genres":[],"explicit":false,"abridged":false},"coverPath":null,"tags":[],"duration":1},"sequence":"2"}"#
        let second = try JSONDecoder.audiobookshelf.decode(LibraryItem.self, from: Data(bySeries.utf8))
        #expect(second.media.metadata.series?.map(\.sequence) == ["2"] && second.sequence == "2")
    }

    @Test("shelves decode each by their type; search answers its sections")
    func shelvesAndSearch() throws {
        let shelves = #"[{"id":"continue-listening","label":"Continue Listening","type":"book","entities":[]},{"id":"newest-authors","label":"Newest Authors","type":"authors","entities":[{"id":"a1","name":"X","numBooks":2}]},{"id":"continue-series","label":"Continue Series","type":"series","entities":[]}]"#
        let decoded = try JSONDecoder.audiobookshelf.decode([Shelf].self, from: Data(shelves.utf8))
        #expect(decoded.map(\.id) == ["continue-listening", "newest-authors", "continue-series"])
        #expect(decoded[1].authors.first?.name == "X")
        let search = #"{"book":[],"narrators":[{"name":"N","numBooks":1}],"tags":[],"genres":[],"series":[],"authors":[]}"#
        let s = try JSONDecoder.audiobookshelf.decode(SearchAnswer.self, from: Data(search.utf8))
        #expect(s.narrators.first?.name == "N")
    }

    // MARK: - Progress, bookmarks, sessions

    @Test("progress goes as a PATCH with the fraction worked out; a 404 read is nil; delete uses the progress id")
    func progressCalls() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            switch (request.httpMethod, request.url?.path) {
            case ("PATCH", "/api/me/progress/li1"):
                let b = body(request)
                #expect(b["currentTime"] as? Double == 120.25 && b["isFinished"] as? Bool == false)
                #expect(abs((b["progress"] as? Double ?? 0) - 120.25 / 3780.85) < 0.0001)
                return text("OK")
            case ("GET", "/api/me/progress/li1"): return text("Not Found", status: 404)
            case ("DELETE", "/api/me/progress/p1"): return text("OK")
            case ("PATCH", "/api/me/progress/batch/update"): return text("OK")
            default: return text("Not Found", status: 404)
            }
        }
        let client = AudiobookshelfClient(host: host, tokens: TokenSession(Tokens(accessToken: "t", refreshToken: nil, expiresAt: .distantFuture)), session: mock.urlSession)
        try await client.updateProgress(itemId: "li1", .init(currentTime: 120.25, duration: 3780.85, isFinished: false))
        #expect(try await client.progress(itemId: "li1") == nil)
        try await client.deleteProgress(progressId: "p1")
        try await client.updateProgress(batch: [("li1", .init(currentTime: 1, duration: 2, isFinished: true))])
    }

    @Test("bookmarks: create and rename by time, delete by time in the path")
    func bookmarkCalls() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/me/item/li1/bookmark"), ("PATCH", "/api/me/item/li1/bookmark"):
                let b = body(request)
                return json(#"{"libraryItemId":"li1","time":\#(b["time"] ?? 0),"title":"\#(b["title"] ?? "")","createdAt":1}"#)
            case ("DELETE", "/api/me/item/li1/bookmark/90"): return text("OK")
            default: return text("Not Found", status: 404)
            }
        }
        let client = AudiobookshelfClient(host: host, tokens: TokenSession(Tokens(accessToken: "t", refreshToken: nil, expiresAt: .distantFuture)), session: mock.urlSession)
        #expect(try await client.createBookmark(itemId: "li1", time: 90, title: "probe").title == "probe")
        #expect(try await client.updateBookmark(itemId: "li1", time: 90, title: "renamed").title == "renamed")
        try await client.deleteBookmark(itemId: "li1", time: 90)
    }

    @Test("a play session: the body names the device and what plays; sync and close report seconds; local sessions go in one batch")
    func sessionCalls() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/items/li1/play"):
                let b = body(request)
                #expect((b["deviceInfo"] as? [String: Any])?["clientName"] as? String == "own.audio Books")
                #expect(b["mediaPlayer"] as? String == "AVPlayer")
                #expect((b["supportedMimeTypes"] as? [String])?.contains("audio/mpeg") == true)
                return json(#"{"id":"s1","userId":"u1","libraryId":"lib1","libraryItemId":"li1","episodeId":null,"mediaType":"book","chapters":[],"displayTitle":"T","displayAuthor":"A","duration":3780.85,"playMethod":0,"mediaPlayer":"AVPlayer","date":"2026-10-15","dayOfWeek":"Thursday","timeListening":0,"startTime":61.5,"currentTime":61.5,"startedAt":1,"updatedAt":1,"audioTracks":[{"index":1,"startOffset":0,"duration":86.9,"title":"01.mp3","contentUrl":"/api/items/li1/file/17088","mimeType":"audio/mpeg"}]}"#)
            case ("POST", "/api/session/s1/sync"):
                let b = body(request)
                #expect(b["currentTime"] as? Double == 70 && b["timeListened"] as? Double == 8.5)
                return text("OK")
            case ("POST", "/api/session/s1/close"): return text("OK")
            case ("POST", "/api/session/local-all"):
                let sessions = body(request)["sessions"] as? [[String: Any]]
                #expect(sessions?.first?["playMethod"] as? Int == 3)
                #expect(sessions?.first?["date"] as? String == "2026-10-15")
                return json(#"{"results":[{"id":"local_1","success":true,"progressSynced":true}]}"#)
            default: return text("Not Found", status: 404)
            }
        }
        let client = AudiobookshelfClient(host: host, tokens: TokenSession(Tokens(accessToken: "t", refreshToken: nil, expiresAt: .distantFuture)), session: mock.urlSession)
        let device = DeviceInfo(deviceId: "d1", clientName: "own.audio Books", clientVersion: "0.1.0")
        let s = try await client.play(itemId: "li1", device: device)
        #expect(s.startTime == 61.5 && s.isHLS == false && s.audioTracks.count == 1)
        #expect(client.mediaURL(contentUrl: s.audioTracks[0].contentUrl, token: "t").absoluteString == "http://books.example.com:13378/api/items/li1/file/17088?token=t")
        try await client.syncSession(id: "s1", currentTime: 70, timeListened: 8.5, duration: s.duration)
        try await client.closeSession(id: "s1", currentTime: 70, timeListened: 0, duration: s.duration)
        var started = DateComponents(); started.year = 2026; started.month = 10; started.day = 15; started.hour = 12
        let startedAt = Calendar(identifier: .gregorian).date(from: started)!
        let local = LocalSession(id: "local_1", userId: "u1", libraryId: "lib1", libraryItemId: "li1", displayTitle: "T", displayAuthor: "A", duration: s.duration, deviceInfo: device, timeListening: 20, startTime: 130, currentTime: 150, startedAt: startedAt, updatedAt: startedAt.addingTimeInterval(20))
        let results = try await client.sendLocalSessions([local], device: device)
        #expect(results.first?.progressSynced == true)
    }

    // MARK: - Cache and URLs

    @Test("library reads are kept and answer offline; search and me are not")
    func cacheRules() {
        #expect(AudiobookshelfClient.keeps("api/libraries"))
        #expect(AudiobookshelfClient.keeps("api/libraries/lib1/items"))
        #expect(AudiobookshelfClient.keeps("api/items/li1"))
        #expect(!AudiobookshelfClient.keeps("api/libraries/lib1/search"))
        #expect(!AudiobookshelfClient.keeps("api/me"))
        #expect(!AudiobookshelfClient.keeps("api/authorize"))
        #expect(!AudiobookshelfClient.keeps("api/session/s1/sync"))
    }

    @Test("file and cover URLs carry the token in the query, the cover its width")
    func mediaURLs() {
        let client = AudiobookshelfClient(host: host, tokens: TokenSession(nil))
        #expect(client.fileURL(itemId: "li1", ino: "17088", token: "tok").absoluteString == "http://books.example.com:13378/api/items/li1/file/17088?token=tok")
        #expect(client.coverURL(itemId: "li1", width: 300).absoluteString == "http://books.example.com:13378/api/items/li1/cover?width=300&format=jpeg")
        #expect(client.mediaURL(contentUrl: "/hls/s1/output.m3u8", token: "tok").absoluteString == "http://books.example.com:13378/hls/s1/output.m3u8?token=tok")
    }

    @Test("mojibake: UTF-8 read as Latin-1 is put back; clean text is untouched")
    func mojibake() {
        #expect(Mojibake.repair("1984 - Ã¨Ã¡st 1") == "1984 - èást 1")
        #expect(Mojibake.repair("PÅ™Ã­bÄ›h") == "Příběh")
        #expect(Mojibake.repair("Příběh") == "Příběh")
        #expect(Mojibake.repair("Ender's Game") == "Ender's Game")
    }

    @Test("versions compare by part")
    func versions() {
        #expect(ServerVersion("2.37.1") > ServerVersion("2.26.0"))
        #expect(ServerVersion("2.9.0") < ServerVersion("2.26"))
        #expect(ServerVersion("2.26.0") == ServerVersion("2.26"))
    }
}
