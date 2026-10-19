import XCTest

/// Another device went on with the book: this phone, which had its own position, asks where
/// to start. The other device is played by the test itself, through the own.audio API — so
/// this runs against own.audio servers only.
final class OtherDeviceTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["SERVER_HOST"] != nil else { throw XCTSkip("SERVER_HOST is not set") }
    }

    func testAsksWhereToContinue() throws {
        guard let token = try? signInAsCar() else { throw XCTSkip("not an own.audio server") }
        let smoke = PlaybackSmokeTests()
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + PlaybackSmokeTests.english
        app.launchChecked()
        smoke.addServer(app)
        smoke.tapTab(app, "Library")
        // The first book by title, not the shortest: the import test leaves a two-second book
        // on the account, which ends before the car's 6:40.
        let book = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.book.'")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        let bookId = String(book.identifier.dropFirst("library.book.".count))
        // A run that died halfway may have left the car's position behind.
        try clear(token: token, bookId: bookId)
        book.tap()
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.tap()
        let pause = app.buttons["miniPlayer.playPause"]
        XCTAssertTrue(smoke.waitUntil(timeout: 40) { pause.exists && pause.label == "Pause" })
        sleep(3)
        pause.tap()
        XCTAssertTrue(smoke.waitUntil(timeout: 5) { pause.label == "Play" })
        app.terminate()

        // The car listens on to 6:40.
        try save(token: token, bookId: bookId, positionMs: 400_000)

        app.launchArguments = PlaybackSmokeTests.english
        app.launchChecked()
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'home.book.'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        smoke.tapTab(app, "Library")
        let same = app.descendants(matching: .any)["library.book.\(bookId)"].firstMatch
        XCTAssertTrue(same.waitForExistence(timeout: 30))
        same.tap()
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.tap()
        let other = app.buttons["resume.other"].firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 20), "the app should ask where to continue")
        smoke.screenshot(app, "15-other-device")
        other.tap()
        XCTAssertTrue(smoke.waitUntil(timeout: 40) { pause.exists && pause.label == "Pause" })
        app.buttons["miniPlayer"].tap()
        let elapsed = app.staticTexts["player.elapsed"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
        XCTAssertTrue(smoke.waitUntil(timeout: 10) { smoke.clock(elapsed.label) >= 395 }, "should play on from the car's position: \(elapsed.label)")
        app.buttons["player.playPause"].tap()
        try clear(token: token, bookId: bookId)
    }

    // MARK: - The other device, through the API

    private var host: URL { URL(string: env["SERVER_HOST"]!.hasPrefix("http") ? env["SERVER_HOST"]! : "https://" + env["SERVER_HOST"]!)! }

    private func signInAsCar() throws -> String {
        var request = URLRequest(url: host.appending(path: "api/v2/auth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("own.audio Books UI tests", forHTTPHeaderField: "User-Agent")
        let fields = ["grant_type": "password", "username": env["SERVER_USER"]!, "password": env["SERVER_PASSWORD"]!, "device_name": "UI test car", "device_kind": "other"]
        request.httpBody = Data(fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }.joined(separator: "&").utf8)
        let (data, response) = try send(request)
        guard response.statusCode == 200, let token = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["access_token"] as? String else {
            throw NSError(domain: "test", code: 1)
        }
        return token
    }

    private func save(token: String, bookId: String, positionMs: Int64) throws {
        var request = URLRequest(url: host.appending(path: "api/v2/me/progress/book/\(bookId)"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("own.audio Books UI tests", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(#"{"position_ms":\#(positionMs),"finished":false}"#.utf8)
        let (_, response) = try send(request)
        XCTAssertEqual(response.statusCode, 200, "the car's position should save")
    }

    private func clear(token: String, bookId: String) throws {
        var request = URLRequest(url: host.appending(path: "api/v2/me/progress/book/\(bookId)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("own.audio Books UI tests", forHTTPHeaderField: "User-Agent")
        _ = try send(request)
    }

    private func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Data, HTTPURLResponse)?
        nonisolated(unsafe) var failure: Error?
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data, let http = response as? HTTPURLResponse { result = (data, http) } else { failure = error }
            done.signal()
        }.resume()
        done.wait()
        if let result { return result }
        throw failure ?? NSError(domain: "test", code: 2)
    }
}
