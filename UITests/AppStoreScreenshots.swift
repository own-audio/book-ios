import XCTest

/// The App Store screenshots, taken from a real server. Not a test of behaviour: run it on
/// purpose, on the device sizes the store wants, with a clean status bar, in light mode (see
/// `scripts/app-store-screenshots.sh`). Use an own.audio server holding only the demo library
/// (public-domain LibriVox books), signed in as the account that runs its family, as own.audio
/// Music's screenshots do, so the three apps' pictures show the same family and server.
///
/// `TEST_RUNNER_SCREENSHOT_LANGUAGE` is `en` or `cs`; `TEST_RUNNER_SCREENSHOT_DIR` is where the
/// PNGs go; `TEST_RUNNER_SCREENSHOT_BOOK` is the book shown, played and downloaded (one whose
/// files carry chapter titles).
final class AppStoreScreenshots: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var czech: Bool { env["SCREENSHOT_LANGUAGE"] == "cs" }
    private var iPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["SERVER_HOST"] != nil, env["SCREENSHOT_DIR"] != nil, env["SCREENSHOT_LANGUAGE"] != nil else {
            throw XCTSkip("Set SERVER_HOST, SCREENSHOT_DIR and SCREENSHOT_LANGUAGE to take store screenshots")
        }
    }

    private func t(_ english: String, _ czech: String) -> String { self.czech ? czech : english }

    func testTakeScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestReset", "-AppleLanguages", "(\(env["SCREENSHOT_LANGUAGE"]!))", "-AppleLocale", czech ? "cs_CZ" : "en_US",
            "-debugServerHost", env["SERVER_HOST"]!, "-debugServerUser", env["SERVER_USER"] ?? "",
            "-debugServerPassword", env["SERVER_PASSWORD"] ?? "", "-debugServerName", t("Family Books", "Rodinné knihy"),
        ]
        app.launchChecked()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 90), "Home should open on the server")
        sleep(6)

        // The library, with its covers.
        openLibrary(app)
        let anyBook = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.book.'")).firstMatch
        XCTAssertTrue(anyBook.waitForExistence(timeout: 30), "the server should have books")
        sleep(5)
        save(app, "1-library")

        // The book, then the player a little way into it.
        let title = env["SCREENSHOT_BOOK"] ?? "Just So Stories"
        let book = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'library.book.' AND label CONTAINS %@", title
        )).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15), "\(title) should be in the library")
        book.tap()
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        sleep(4)
        save(app, "3-book")

        play.tap()
        chooseThisDevice(app)
        let miniPlayer = app.buttons["miniPlayer"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 40))
        let pause = app.buttons["miniPlayer.playPause"]
        _ = waitUntil(timeout: 40) { pause.exists && pause.label == t("Pause", "Pozastavit") }
        sleep(10)
        miniPlayer.tap()
        XCTAssertTrue(app.descendants(matching: .any)["player.scrubber"].firstMatch.waitForExistence(timeout: 15))
        sleep(3)
        save(app, "2-player")

        // The chapters: the file titles, as the server has no chapter marks for this book.
        app.buttons["player.chapter"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chapters.'")).firstMatch
            .waitForExistence(timeout: 10))
        sleep(2)
        save(app, "4-chapters")
        dismissSheet(app)

        // The sleep timer's choices.
        app.buttons["player.sleep"].tap()
        XCTAssertTrue(app.buttons["sleep.endOfChapter"].waitForExistence(timeout: 10))
        // The sheet's glass settles a moment after it appears.
        sleep(4)
        save(app, "5-sleep")
        dismissSheet(app)

        // Paused, so the listening position is saved and Home has it first.
        let playPause = app.buttons["player.playPause"]
        if playPause.exists && playPause.label == t("Pause", "Pozastavit") { playPause.tap() }
        app.buttons["player.close"].tap()
        sleep(1)

        // The book onto the phone, for the Downloads tab.
        let download = app.buttons["detail.download"]
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        download.tap()
        XCTAssertTrue(waitUntil(timeout: 300) { download.label == t("Downloaded", "Staženo") }, "the book should download: \(download.label)")

        // Home: Continue Listening, Recently Added.
        tab(app, t("Home", "Domů")).tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 10))
        sleep(5)
        save(app, "6-home")

        tab(app, t("Downloads", "Stažené")).tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'downloads.'")).firstMatch
            .waitForExistence(timeout: 15))
        sleep(2)
        save(app, "8-downloads")

        // The family, from the server's page in Settings.
        tab(app, t("Home", "Domů")).tap()
        app.buttons["home.settings"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'servers.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Settings should list the server")
        row.tap()
        let family = app.buttons["serverDetail.family"]
        XCTAssertTrue(family.waitForExistence(timeout: 15), "an own.audio server signed in to has a family")
        family.tap()
        XCTAssertTrue(app.staticTexts[t("Members", "Členové")].waitForExistence(timeout: 15))
        sleep(3)
        save(app, "7-family")
    }

    // MARK: - Steps

    private func openLibrary(_ app: XCUIApplication) {
        // A tab on the iPhone; on the iPad, the sidebar's Books.
        let sidebar = app.descendants(matching: .any)["sidebar.books"].firstMatch
        for _ in 0..<4 {
            if sidebar.exists { sidebar.tap(); return }
            let library = tab(app, t("Library", "Knihovna"))
            if library.exists { library.tap(); return }
            sleep(1)
        }
    }

    /// Another device's place in the book (from earlier runs) asks where to go on; this one.
    private func chooseThisDevice(_ app: XCUIApplication) {
        let here = app.buttons["resume.local"]
        if here.waitForExistence(timeout: 3) { here.tap() }
    }

    private func dismissSheet(_ app: XCUIApplication) {
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Hotovo"])).firstMatch
        if done.waitForExistence(timeout: 2) { done.tap(); sleep(1); return }
        app.swipeDown(velocity: .fast)
        sleep(1)
    }

    private func tab(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let bar = app.tabBars.buttons[label]
        return bar.exists ? bar : app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = URL(fileURLWithPath: env["SCREENSHOT_DIR"]!)
        try? shot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return condition()
    }
}
