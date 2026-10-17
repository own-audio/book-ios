import XCTest

/// Things a listener isn't meant to do, done anyway: wrong sign-ins, buttons hammered, screens
/// left before they load, odd searches, the server removed or the network gone mid-book, the app
/// killed mid-download. Nothing here checks a feature; each checks the app is still usable after.
///
/// Runs against the same server as `PlaybackSmokeTests` (`SERVER_HOST`, `SERVER_USER`,
/// `SERVER_PASSWORD`, optionally `SERVER_DOWNLOAD_BOOK`), so once per kind of server.
final class MisuseTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private let smoke = PlaybackSmokeTests()

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["SERVER_HOST"] != nil else { throw XCTSkip("SERVER_HOST is not set") }
    }

    /// Sign-ins that can't work say why and leave the form usable; the right one still works
    /// afterwards, even typed with spaces around the address and a slash after it.
    func testWrongSignIns() throws {
        var app = launch(reset: true)
        let host = env["SERVER_HOST"]!
        let attempts: [(address: String, user: String, password: String)] = [
            ("not a server %% 😀", "someone", "x"),
            ("127.0.0.1:1", "someone", "x"),
            (host, env["SERVER_USER"] ?? "", "certainly-not-the-password"),
            (host, String(repeating: "ž", count: 200), String(repeating: "'\"; --", count: 30)),
        ]
        for (index, attempt) in attempts.enumerated() {
            // Each attempt on a fresh form: editing what the last one left behind is a test of
            // the text field, not of signing in.
            if index > 0 {
                app.terminate()
                app = launch(reset: true)
            }
            fill(app, address: attempt.address, user: attempt.user, password: attempt.password)
            let connect = app.buttons["addServer.connect"]
            connect.tap()
            if connect.exists, connect.isHittable { connect.tap() }
            smoke.dismissSavePasswordPrompt(app)
            let error = app.descendants(matching: .any)["addServer.error"].firstMatch
            XCTAssertTrue(error.waitForExistence(timeout: 45), "attempt \(index) should say what went wrong")
            XCTAssertFalse(app.buttons["home.settings"].exists, "attempt \(index) should not get in")
            smoke.screenshot(app, "misuse-signin-\(index)")
        }

        app.terminate()
        app = launch(reset: true)
        fill(app, address: "  \(host)/  ", user: env["SERVER_USER"] ?? "", password: env["SERVER_PASSWORD"] ?? "")
        app.buttons["addServer.connect"].tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 60), "the right sign-in should still work")
        smoke.dismissSavePasswordPrompt(app)
    }

    /// Skips, chapter steps, play/pause and the scrubber hammered faster than anything can load:
    /// afterwards the player still plays, and the position moves.
    func testHammeredPlayer() throws {
        let app = launch(reset: true)
        smoke.addServer(app)
        startBook(app)
        app.buttons["miniPlayer"].tap()
        let scrubber = app.descendants(matching: .any)["player.scrubber"].firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 10))

        let forward = app.buttons["player.skipForward"], back = app.buttons["player.skipBackward"]
        let next = app.buttons["player.nextChapter"], previous = app.buttons["player.previousChapter"]
        let playPause = app.buttons["player.playPause"]
        for _ in 0..<8 { forward.tap() }
        for _ in 0..<8 { back.tap() }
        for _ in 0..<6 where next.exists { next.tap() }
        for _ in 0..<6 where previous.exists { previous.tap() }
        for _ in 0..<9 { playPause.tap() }
        for offset in [0.9, 0.1, 0.5, 0.95, 0.0] {
            scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: offset, dy: 0.5)))
        }
        smoke.screenshot(app, "misuse-hammered")

        XCTAssertTrue(ensurePlaying(app), "after all that, the player should play again")
        let elapsed = app.staticTexts["player.elapsed"]
        let before = elapsed.label
        XCTAssertTrue(smoke.waitUntil(timeout: 10) { elapsed.label != before }, "and the position should move")
    }

    /// Stop pressed while the book is still loading: nothing starts playing afterwards when the
    /// load lands, and playing again works as usual.
    func testStopWhileLoading() throws {
        let app = launch(reset: true)
        smoke.addServer(app)
        openFirstBook(app)
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.tap()
        let miniPlayer = app.buttons["miniPlayer"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 30))
        miniPlayer.tap()
        let stop = app.buttons["player.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.tap()
        XCTAssertTrue(smoke.waitUntil(timeout: 10) { !miniPlayer.exists && !stop.exists }, "stopping should close the player")
        sleep(6)
        XCTAssertFalse(miniPlayer.exists, "a load that lands after the stop should not start playing")

        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        let pause = app.buttons["miniPlayer.playPause"]
        XCTAssertTrue(smoke.waitUntil(timeout: 40) { pause.exists && pause.label == "Pause" }, "playing again should work")
    }

    /// Screens left before they load, tabs switched as fast as they can be tapped, and searches
    /// no book is called: the app keeps answering and a book still plays.
    func testRestlessNavigationAndOddSearches() throws {
        let app = launch(reset: true)
        smoke.addServer(app)
        smoke.tapTab(app, "Library")
        let book = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.book.'")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        for _ in 0..<5 {
            book.tap()
            let back = app.navigationBars.buttons.firstMatch
            if back.waitForExistence(timeout: 2) { back.tap() }
        }
        // iOS offers to save the password a while after the sign-in; the sheet swallows taps.
        smoke.dismissSavePasswordPrompt(app)
        for round in 0..<12 {
            let tab = tabButton(app, ["Home", "Library"][round % 2])
            if tab.exists { tab.tap() }
        }

        let search = openSearch(app)
        let odd = ["%", "' OR 1=1 --", "😀📚", "<script>alert(1)</script>", "\\", "   ", "a", String(repeating: "Alice ", count: 40), "../../etc/passwd", "*?[]{}"]
        for (index, text) in odd.enumerated() {
            let clear = search.buttons.firstMatch
            if clear.exists, clear.isHittable { clear.tap() }
            search.tap()
            search.typeText(text)
            sleep(2)
            XCTAssertEqual(app.state, .runningForeground, "searching for “\(text)” should not end the app")
            if index == 3 { smoke.screenshot(app, "misuse-search") }
        }
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Cancel", "Zavřít", "Zrušit"])).firstMatch
        if close.exists { close.tap() }

        smoke.tapTab(app, "Library")
        startBook(app)
    }

    /// Mid-book: the app sent to the background and back, started with no network, started
    /// again, and finally the server removed — which stops what it was playing.
    func testInterruptionsWhilePlaying() throws {
        var app = launch(reset: true)
        smoke.addServer(app)
        startBook(app)

        XCUIDevice.shared.press(.home)
        sleep(4)
        app.activate()
        let pause = app.buttons["miniPlayer.playPause"]
        XCTAssertTrue(smoke.waitUntil(timeout: 10) { pause.exists && pause.label == "Pause" }, "back from the background, still playing")

        app.terminate()
        app = launch(reset: false, offline: true)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 20), "a start with no network should reach Home")
        smoke.tapTab(app, "Library")
        XCTAssertEqual(app.state, .runningForeground)
        smoke.screenshot(app, "misuse-offline-start")

        app.terminate()
        app = launch(reset: false)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 20))
        startBook(app)

        smoke.tapTab(app, "Home")
        app.buttons["home.settings"].tap()
        let servers = app.buttons["settings.servers"]
        if !servers.waitForExistence(timeout: 3) { smoke.dismissSavePasswordPrompt(app); app.buttons["home.settings"].tap() }
        XCTAssertTrue(servers.waitForExistence(timeout: 10))
        servers.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'servers.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeLeft()
        let remove = app.buttons["Remove"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(smoke.waitUntil(timeout: 15) { !app.buttons["miniPlayer"].exists }, "removing the server should stop its book")
        XCTAssertTrue(smoke.waitUntil(timeout: 15) { app.textFields["addServer.address"].exists || !row.exists }, "and leave no server behind")
        XCTAssertEqual(app.state, .runningForeground)
        smoke.screenshot(app, "misuse-server-removed")
    }

    /// The app killed in the middle of downloading a book: started again, the book can be
    /// downloaded to the end, and plays from the phone.
    func testKilledMidDownload() throws {
        guard let name = env["SERVER_DOWNLOAD_BOOK"].flatMap({ $0.isEmpty ? nil : $0 }) else {
            throw XCTSkip("SERVER_DOWNLOAD_BOOK is not set")
        }
        var app = launch(reset: true)
        smoke.addServer(app)
        openBook(app, named: name)
        let download = app.buttons["detail.download"]
        XCTAssertTrue(download.waitForExistence(timeout: 20))
        download.tap()
        XCTAssertTrue(smoke.waitUntil(timeout: 20) { download.label.hasPrefix("Downloading") }, "the download should start")
        app.terminate()

        app = launch(reset: false)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 20))
        openBook(app, named: name)
        XCTAssertTrue(download.waitForExistence(timeout: 20))
        if download.label.hasPrefix("Download failed") || download.label == "Download" { download.tap() }
        XCTAssertTrue(smoke.waitUntil(timeout: 300) { download.label == "Downloaded" }, "the download should finish after the restart: \(download.label)")
        app.buttons["detail.play"].tap()
        let pause = app.buttons["miniPlayer.playPause"]
        XCTAssertTrue(smoke.waitUntil(timeout: 30) { pause.exists && pause.label == "Pause" }, "the downloaded book should play")
    }

    // MARK: - Helpers

    /// The tab bar's button for `label`. Other buttons can carry the same label and sit first
    /// in the list off screen, where a tap goes nowhere: the one that can be hit.
    private func tabButton(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", label))
        _ = matches.firstMatch.waitForExistence(timeout: 10)
        return matches.allElementsBoundByIndex.first { $0.isHittable } ?? matches.firstMatch
    }

    /// The search field: on iOS 26 the Search tab is a capsule that opens into the field on a
    /// tap, sometimes on a second one.
    private func openSearch(_ app: XCUIApplication) -> XCUIElement {
        let field = app.searchFields.firstMatch
        for _ in 0..<3 where !field.exists {
            smoke.dismissSavePasswordPrompt(app)
            let tab = tabButton(app, "Search")
            if tab.exists { tab.tap() }
            if field.waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(field.exists, "the Search tab should show a search field")
        return field
    }

    private func launch(reset: Bool, offline: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (reset ? ["-uiTestReset"] : []) + (offline ? ["-simulateOffline"] : []) + PlaybackSmokeTests.english
        app.launch()
        return app
    }

    private func fill(_ app: XCUIApplication, address: String, user: String, password: String) {
        for (id, text) in [("addServer.address", address), ("addServer.username", user)] {
            let field = app.textFields[id]
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.tap()
            field.typeText(text)
        }
        let secret = app.secureTextFields["addServer.password"]
        secret.tap()
        secret.typeText(password)
    }

    /// Back to the Library's first screen, then into the first book, or the named one via Search.
    private func openBook(_ app: XCUIApplication, named name: String? = nil) {
        if let name {
            let search = openSearch(app)
            search.tap()
            search.typeText(name)
            let hit = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'search.book.'")).firstMatch
            XCTAssertTrue(hit.waitForExistence(timeout: 30), "the search should find \(name)")
            hit.tap()
            return
        }
        openFirstBook(app)
    }

    private func openFirstBook(_ app: XCUIApplication) {
        smoke.tapTab(app, "Library")
        let book = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.book.'")).firstMatch
        for _ in 0..<4 where !book.waitForExistence(timeout: 3) {
            let back = app.navigationBars.buttons.firstMatch
            guard back.exists else { break }
            back.tap()
        }
        XCTAssertTrue(book.waitForExistence(timeout: 30), "the Library should list a book")
        book.tap()
    }

    /// Opens the first book (unless already on one) and plays it until there is sound.
    private func startBook(_ app: XCUIApplication) {
        if !app.buttons["detail.play"].exists { openFirstBook(app) }
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.tap()
        let pause = app.buttons["miniPlayer.playPause"]
        XCTAssertTrue(smoke.waitUntil(timeout: 40) { pause.exists && pause.label == "Pause" }, "playback should start")
    }

    /// Waits for loading to settle and presses play if it ended up paused.
    private func ensurePlaying(_ app: XCUIApplication) -> Bool {
        let playPause = app.buttons["player.playPause"]
        return smoke.waitUntil(timeout: 40) {
            guard playPause.exists, playPause.isEnabled else { return false }
            if playPause.label == "Pause" { return true }
            if playPause.label == "Play" { playPause.tap(); sleep(2) }
            return playPause.label == "Pause"
        }
    }
}
