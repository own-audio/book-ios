import AudiobookshelfKit
import Foundation
import OwnAudioKit
import Testing

@testable import BookLibrary

@Suite("Models")
struct ModelTests {
    @Test("a timeline lays files end to end; a position finds its file and offset, and back")
    func timeline() {
        let files = BookFile.timeline([("a", "One", 1000, nil, "audio/mpeg"), ("b", "Two", 2000, nil, "audio/mpeg"), ("c", "Three", 500, nil, nil)])
        #expect(files.map(\.startMs) == [0, 1000, 3000])
        let book = Book(id: "x", title: "X", durationMs: 3500, addedAt: Date(), files: files)
        #expect(book.file(at: 0)?.file.id == "a")
        #expect(book.file(at: 999)?.file.id == "a" && book.file(at: 999)?.offsetMs == 999)
        #expect(book.file(at: 1000)?.file.id == "b" && book.file(at: 1000)?.offsetMs == 0)
        #expect(book.file(at: 3400)?.file.id == "c" && book.file(at: 3400)?.offsetMs == 400)
        #expect(book.file(at: 9000)?.file.id == "c" && book.file(at: 9000)?.offsetMs == 500)
        #expect(book.position(fileId: "b", offsetMs: 10) == 1010)
        #expect(book.position(fileId: "zz", offsetMs: 10) == nil)
    }

    @Test("a series sequence is read as a number where it has one", arguments: [
        ("1", 1.0), ("1.5", 1.5), ("2,5", 2.5), ("1-3", 1.0), ("Book 2", nil), ("", nil),
    ] as [(String, Double?)])
    func sequence(text: String, position: Double?) {
        #expect(SeriesRef(id: "s", name: "S", sequence: text).position == position)
    }

    @Test("address scopes: home, VPN and public")
    func scopes() {
        #expect(AddressScope.infer(URL(string: "http://192.168.1.5:13378")!) == .lan)
        #expect(AddressScope.infer(URL(string: "http://nas.local")!) == .lan)
        #expect(AddressScope.infer(URL(string: "http://100.100.3.4")!) == .vpn)
        #expect(AddressScope.infer(URL(string: "https://nas.tail1234.ts.net")!) == .vpn)
        #expect(AddressScope.infer(URL(string: "https://books.example.com")!) == .public)
    }

    @Test("a record's candidates: the added address first, no repeats, no plain-http public address the server named")
    func candidates() {
        var record = ServerRecord(displayName: "S", kind: .ownAudio, host: URL(string: "https://books.example.com")!, auth: .ownAudio(username: "me", tokens: nil))
        record.learn([
            ServerAddress(url: URL(string: "https://books.example.com/")!, origin: .server),
            ServerAddress(url: URL(string: "http://192.168.1.5:8080")!, origin: .server),
            ServerAddress(url: URL(string: "http://public.example.org")!, origin: .server),
        ])
        #expect(record.candidateAddresses.map(\.url.absoluteString) == ["https://books.example.com", "http://192.168.1.5:8080"])
    }

    @Test("records round-trip through JSON with either kind of tokens")
    func recordCoding() throws {
        let abs = ServerRecord(displayName: "ABS", kind: .audiobookshelf, host: URL(string: "http://nas.local:13378")!, auth: .audiobookshelf(username: "u", tokens: AudiobookshelfKit.Tokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1))), libraryId: "lib1", userId: "u1")
        let own = ServerRecord(displayName: "own", kind: .ownAudio, host: URL(string: "https://demo.example.com")!, auth: .ownAudio(username: "me@example.com", tokens: OwnAudioKit.Tokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1), scope: "playback")), userId: "u2", serverId: "s1")
        let data = try JSONEncoder().encode([abs, own])
        let back = try JSONDecoder().decode([ServerRecord].self, from: data)
        #expect(back == [abs, own])
        #expect(back[0].auth.isSignedIn && back[0].libraryId == "lib1")
    }

    @Test("the hosted service's browser addresses point at its API")
    func apiAddress() {
        #expect(ServerSetup.ownAudioAPIAddress("https://app.own.audio/") == "https://api.own.audio")
        #expect(ServerSetup.ownAudioAPIAddress("http://nas.local:8080") == "http://nas.local:8080")
    }
}

@Suite("Audiobookshelf records to books")
struct AudiobookshelfMappingTests {
    private let source = AudiobookshelfSource(
        client: AudiobookshelfClient(host: URL(string: "http://books.example.com:13378")!, tokens: AudiobookshelfKit.TokenSession(nil)),
        libraryId: "lib1", userId: "u1", device: DeviceIdentity(id: "d", name: "iPhone", model: "iPhone", appVersion: "0.1", systemVersion: "18")
    )

    private func item(_ json: String) throws -> LibraryItem {
        try JSONDecoder().decode(LibraryItem.self, from: Data(json.utf8))
    }

    @Test("a list row: names split from the strings, the series name parsed, the cover URL made")
    func listRow() throws {
        let row = try item(#"{"id":"li1","libraryId":"lib1","addedAt":1792000000000,"updatedAt":1,"isMissing":false,"isInvalid":false,"mediaType":"book","media":{"metadata":{"title":"Ender's Game","authorName":"Orson Scott Card, Someone Else","narratorName":"Stefan Rudnicki","seriesName":"Ender's Game Series #1, Enderverse #3.5","genres":["Sci-Fi"],"publishedYear":"1985","explicit":false,"abridged":false},"coverPath":"/c.jpg","tags":[],"duration":3780.85,"size":1}}"#)
        let book = source.book(row)
        #expect(book.authors.map(\.name) == ["Orson Scott Card", "Someone Else"])
        #expect(book.narrators.map(\.id) == ["Stefan Rudnicki"])
        #expect(book.series.map(\.name) == ["Ender's Game Series", "Enderverse"])
        #expect(book.series.map(\.sequence) == ["1", "3.5"])
        #expect(book.series[1].position == 3.5)
        #expect(book.durationMs == 3_780_850)
        #expect(book.coverURL?.absoluteString == "http://books.example.com:13378/api/items/li1/cover?width=600&format=jpeg")
        #expect(book.files == nil && book.chapters == nil)
        #expect(abs(book.addedAt.timeIntervalSince1970 - 1_792_000_000) < 1)
    }

    @Test("a detail: files from the tracks with their offsets, chapters in milliseconds, authors with ids, mojibake repaired")
    func detail() throws {
        let detail = try item(#"{"id":"li1","libraryId":"lib1","addedAt":1,"updatedAt":1,"isMissing":false,"isInvalid":false,"mediaType":"book","media":{"metadata":{"title":"1984 - Ã¨Ã¡st 1","authors":[{"id":"a1","name":"George Orwell"}],"narrators":["N"],"series":[{"id":"s1","name":"Classics","sequence":"2"}],"genres":[],"explicit":false,"abridged":false},"coverPath":null,"tags":[],"duration":100.5,"chapters":[{"id":0,"start":0,"end":50.25,"title":"One"},{"id":1,"start":50.25,"end":100.5,"title":"Two"}],"tracks":[{"index":1,"startOffset":0,"duration":60,"title":"a.mp3","contentUrl":"/api/items/li1/file/11","mimeType":"audio/mpeg","ino":"11"},{"index":2,"startOffset":60,"duration":40.5,"title":"b.mp3","contentUrl":"/api/items/li1/file/12","mimeType":"audio/mpeg","ino":12}]}}"#)
        let book = source.book(detail)
        #expect(book.title == "1984 - èást 1")
        #expect(book.authors == [Person(id: "a1", name: "George Orwell")])
        #expect(book.series.first?.id == "s1" && book.series.first?.position == 2)
        #expect(book.files?.map(\.id) == ["11", "12"])
        #expect(book.files?.map(\.startMs) == [0, 60_000])
        #expect(book.files?.last?.durationMs == 40_500)
        #expect(book.chapters?.map(\.endMs) == [50_250, 100_500])
        #expect(book.coverURL == nil)
        #expect(book.file(at: 70_000)?.file.id == "12")
    }

    @Test("progress and bookmarks: seconds to milliseconds, the bookmark keyed by its time")
    func progressAndBookmarks() throws {
        let p = try JSONDecoder().decode(MediaProgress.self, from: Data(#"{"id":"p1","userId":"u","libraryItemId":"li1","episodeId":null,"duration":100,"progress":0.5,"currentTime":50.25,"isFinished":false,"hideFromContinueListening":false,"lastUpdate":1792091696595,"startedAt":1,"finishedAt":null}"#.utf8))
        let progress = AudiobookshelfSource.progress(p)
        #expect(progress.positionMs == 50_250 && !progress.finished)
        #expect(abs(progress.updatedAt.timeIntervalSince1970 - 1_792_091_696.595) < 0.001)
        let b = AudiobookshelfSource.bookmark(AudiobookshelfKit.Bookmark(libraryItemId: "li1", time: 90, title: "", createdAt: 1000))
        #expect(b.id == "90" && b.positionMs == 90_000 && b.label == nil)
        #expect(AudiobookshelfSource.timeKey(90.5) == "90.5")
    }

    @Test("errors become the screens' errors")
    func errors() {
        #expect(AudiobookshelfSource.sourceError(.invalidCredentials) == .signInRejected)
        #expect(AudiobookshelfSource.sourceError(.http(403, message: nil)) == .notAllowed)
        #expect(AudiobookshelfSource.sourceError(.http(500, message: "boom")) == .server("boom"))
        #expect(AudiobookshelfSource.sourceError(.offline) == .offline)
    }
}

@Suite("own.audio records to books")
struct OwnAudioMappingTests {
    private func state() -> FeedState {
        func data(_ json: String) -> Data { Data(json.utf8) }
        return FeedState(cursor: "c1", records: [
            "contributor": [
                "a1": data(#"{"id":"a1","name":"Lewis Carroll","kind":"person","image":"https://s.example.com/api/v2/images/i1?e=1&s=sig"}"#),
                "n1": data(#"{"id":"n1","name":"LibriVox volunteers","kind":"group"}"#),
                "m1": data(#"{"id":"m1","name":"A Musician","kind":"person"}"#),
            ],
            "book": [
                "b1": data(#"{"id":"b1","title":"Alice","credits":[{"contributor_id":"a1","role":"author","position":0,"join_phrase":""},{"contributor_id":"n1","role":"narrator","position":0,"join_phrase":""}],"duration_ms":3000,"visibility":"family","owner_id":"u1","image":"https://s.example.com/api/v2/images/i2?e=1&s=sig","created_at":"2026-10-14T18:06:13.792347Z","updated_at":"2026-10-14T18:06:15Z","files":[{"id":"f2","position":2,"title":"ch 02","duration_ms":2000,"size_bytes":2,"content_type":"audio/mpeg"},{"id":"f1","position":1,"title":"ch 01","duration_ms":1000,"size_bytes":1,"content_type":"audio/mpeg"}],"chapters":[{"id":"c2","position":1,"title":null,"start_ms":1500},{"id":"c1","position":0,"title":"Down the Rabbit-Hole","start_ms":0}],"series":[{"series_id":"s1","name":"Alice books","position":1.5}]}"#),
                "b2": data(#"{"id":"b2","title":"Looking-Glass","credits":[{"contributor_id":"a1","role":"author","position":0,"join_phrase":""}],"duration_ms":1000,"visibility":"private","owner_id":"u1","created_at":"2026-10-15T18:06:13Z","updated_at":"2026-10-15T18:06:15Z","files":[],"chapters":[],"series":[{"series_id":"s1","name":"Alice books","position":1}]}"#),
            ],
            "progress.book": ["b1": data(#"{"kind":"book","id":"b1","position_ms":1200,"finished":false,"updated_at":"2026-10-15T10:00:00Z"}"#)],
            "bookmark": ["bm1": data(#"{"id":"bm1","kind":"book","item_id":"b1","position_ms":500,"label":"here","created_at":"2026-10-15T10:00:00Z"}"#)],
            "favourite.book": ["b2": data(#"{"kind":"book","id":"b2","created_at":"2026-10-15T10:00:00Z"}"#)],
        ])
    }

    @Test("a feed state becomes the library: books with files in order, chapters with ends, people by role, the listener's state")
    func library() {
        let library = OwnAudioSource.library(state())
        let alice = library.books.first { $0.id == "b1" }!
        #expect(alice.authors == [Person(id: "a1", name: "Lewis Carroll", imageURL: URL(string: "https://s.example.com/api/v2/images/i1?e=1&s=sig&w=256"))])
        #expect(alice.narrators.map(\.name) == ["LibriVox volunteers"])
        #expect(alice.files?.map(\.id) == ["f1", "f2"])
        #expect(alice.files?.map(\.startMs) == [0, 1000])
        #expect(alice.chapters == [Chapter(title: "Down the Rabbit-Hole", startMs: 0, endMs: 1500), Chapter(title: "Chapter 2", startMs: 1500, endMs: 3000)])
        #expect(alice.series.first?.sequence == "1.5" && alice.visibility == .family)
        #expect(alice.coverURL?.query()?.contains("w=1024") == true)
        #expect(library.authors.map(\.name) == ["Lewis Carroll"] && library.authors.first?.bookCount == 2)
        #expect(library.narrators.map(\.id) == ["n1"])
        #expect(library.progress["b1"]?.positionMs == 1200)
        #expect(library.bookmarks.map(\.label) == ["here"])
        #expect(library.favourites == ["b2"])
        let series = OwnAudioSource.series(of: library.books)
        #expect(series.map(\.name) == ["Alice books"])
        #expect(series.first?.books?.map(\.id) == ["b2", "b1"])
    }

    @Test("browsing the copy: sort, filter, series order, text, paging")
    func browsing() async throws {
        let catalogue = OwnAudioCatalogue()
        catalogue.restore(state())
        let source = OwnAudioSource(
            client: OwnAudioClient(host: URL(string: "https://s.example.com")!, tokens: OwnAudioKit.TokenSession(nil)),
            userId: "u1", device: DeviceIdentity(id: "d", name: "iPhone", model: "iPhone", appVersion: "0.1", systemVersion: "18"), catalogue: catalogue
        )
        #expect(try await source.books(BookQuery(sort: .title)).books.map(\.id) == ["b1", "b2"])
        #expect(try await source.books(BookQuery(sort: .added, descending: true)).books.map(\.id) == ["b2", "b1"])
        #expect(try await source.books(BookQuery(filter: .inProgress)).books.map(\.id) == ["b1"])
        #expect(try await source.books(BookQuery(filter: .notStarted)).books.map(\.id) == ["b2"])
        #expect(try await source.books(BookQuery(filter: .favourites)).books.map(\.id) == ["b2"])
        #expect(try await source.books(BookQuery(seriesId: "s1")).books.map(\.id) == ["b2", "b1"])
        #expect(try await source.books(BookQuery(text: "glass")).books.map(\.id) == ["b2"])
        let first = try await source.books(BookQuery(), cursor: nil, limit: 1)
        #expect(first.books.map(\.id) == ["b1"] && first.next == "1" && first.total == 2)
        let second = try await source.books(BookQuery(), cursor: first.next, limit: 1)
        #expect(second.books.map(\.id) == ["b2"] && second.next == nil)
        let shelves = try await source.shelves()
        #expect(shelves.map(\.id) == ["continue-listening", "recently-added"])
        let found = try await source.search("carroll")
        #expect(found.books.count == 2 && found.authors.count == 1)
        #expect(try await source.series().first?.bookCount == 2)
    }

    @Test("errors become the screens' errors")
    func errors() {
        #expect(OwnAudioSource.sourceError(.signedOut) == .signInRejected)
        #expect(OwnAudioSource.sourceError(.network) == .network)
    }
}
