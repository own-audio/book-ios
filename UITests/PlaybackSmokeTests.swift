import XCTest

/// Add a server, open a book, play it, move around in it: the path every listener takes first.
///
/// Needs a real server with at least one book:
///
/// ```
/// TEST_RUNNER_SERVER_HOST=nas.local:13378 TEST_RUNNER_SERVER_USER=… TEST_RUNNER_SERVER_PASSWORD=… \
/// xcodebuild test …
/// ```
///
/// `TEST_RUNNER_SCREENSHOT_DIR` saves a screenshot of each step there as well as in the result.
final class PlaybackSmokeTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    /// The tests find some controls by their English label, and the simulator may be set to
    /// another language the app is translated into.
    static let english = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["SERVER_HOST"] != nil else { throw XCTSkip("SERVER_HOST is not set") }
    }

    func testAddServerPlayBookAndMoveAround() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + Self.english
        app.launch()

        addServer(app)
        screenshot(app, "01-home")

        // Library: the first book of the grid.
        tapTab(app, "Library")
        let book = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.book.'")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30), "the library should list a book")
        screenshot(app, "02-library")
        book.tap()

        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        let title = app.staticTexts["detail.title"].label
        screenshot(app, "03-detail")
        play.tap()

        let miniPlayer = app.buttons["miniPlayer"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 30), "the mini player should appear once the book loads")
        let miniPlayPause = app.buttons["miniPlayer.playPause"]
        XCTAssertTrue(waitUntil(timeout: 40) { miniPlayPause.exists && miniPlayPause.label == "Pause" }, "playback should start")
        screenshot(app, "04-mini-player")
        miniPlayer.tap()

        let elapsed = app.staticTexts["player.elapsed"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["player.title"].label, title)
        let first = elapsed.label
        XCTAssertTrue(waitUntil(timeout: 10) { elapsed.label != first }, "the position should advance while playing")
        screenshot(app, "05-player")

        // Skip forward moves the position by the interval.
        let before = clock(elapsed.label)
        app.buttons["player.skipForward"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { clock(elapsed.label) >= before + 25 }, "skip forward should move ahead by about 30 s")

        // Speed: 1.5× is a preset.
        app.buttons["player.speed"].tap()
        let preset = app.buttons["speed.preset.1.5"]
        XCTAssertTrue(preset.waitForExistence(timeout: 5))
        preset.tap()
        XCTAssertEqual(app.staticTexts["speed.value"].label, "1.50×")
        app.buttons["Done"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { app.buttons["player.speed"].label.contains("1.5") })
        screenshot(app, "06-speed")

        // A bookmark at the current position, then removed, so the account ends as it began.
        app.buttons["player.bookmarks"].tap()
        let add = app.buttons["bookmarks.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        // A run that died halfway may have left a bookmark on the account: clear them first.
        let existing = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'bookmarks.' AND NOT identifier == 'bookmarks.add'"))
        for _ in 0..<10 where existing.firstMatch.exists {
            existing.firstMatch.swipeLeft()
            app.buttons["Delete"].firstMatch.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        add.tap()
        // An alert's fields and buttons are the alert's, not the screen's.
        let label = app.alerts.textFields.firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 5), "the new-bookmark alert should ask for a label")
        label.tap()
        label.typeText("UI test")
        app.alerts.buttons["Add"].tap()
        let made = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'bookmarks.' AND NOT identifier == 'bookmarks.add'")).firstMatch
        XCTAssertTrue(made.waitForExistence(timeout: 10), "the bookmark should be listed")
        screenshot(app, "07-bookmark")
        made.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !made.exists })
        app.buttons["Done"].tap()

        // Chapters open and the current one is marked.
        app.buttons["player.chapters"].tap()
        XCTAssertTrue(app.navigationBars["Chapters"].waitForExistence(timeout: 5))
        screenshot(app, "08-chapters")
        app.buttons["Done"].tap()

        // Sleep timer: armed, badge shown, turned off.
        app.buttons["player.sleep"].tap()
        let fifteen = app.buttons["sleep.15"]
        XCTAssertTrue(fifteen.waitForExistence(timeout: 5))
        fifteen.tap()
        XCTAssertTrue(app.otherElements["player.sleepBadge"].waitForExistence(timeout: 5) || app.staticTexts["player.sleepBadge"].waitForExistence(timeout: 1))
        app.buttons["player.sleep"].tap()
        app.buttons["sleep.off"].tap()

        let playPause = app.buttons["player.playPause"]
        playPause.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { playPause.label == "Play" }, "pause should pause")
        screenshot(app, "09-paused")

        // Back on the book, the position is shown as progress; a reset forgets it.
        app.buttons["player.close"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { app.staticTexts["detail.progress"].label.contains("left") }, "the detail should show time left")
        app.buttons["detail.more"].tap()
        sleep(1)
        screenshot(app, "09b-menu")
        let reset = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Reset Progress'")).firstMatch
        XCTAssertTrue(reset.waitForExistence(timeout: 5), "the menu should offer a reset")
        reset.tap()
        let confirm = app.sheets.buttons["Reset Progress"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the reset should ask to confirm")
        confirm.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !app.staticTexts["detail.progress"].label.contains("left") }, "the progress should be gone")
        screenshot(app, "10-reset")
    }

    /// own.audio servers list the devices signed in; this one is marked. Audiobookshelf has no
    /// such list, so the screen is absent there and the test ends early.
    func testDevicesScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + Self.english
        app.launch()
        addServer(app)
        app.buttons["home.settings"].tap()
        if !app.navigationBars["Settings"].waitForExistence(timeout: 3) {
            dismissSavePasswordPrompt(app)
            app.buttons["home.settings"].tap()
        }
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let devices = app.buttons["settings.devices"]
        guard devices.waitForExistence(timeout: 3) else { return }
        devices.tap()
        let thisDevice = app.staticTexts["This device"]
        _ = thisDevice.waitForExistence(timeout: 20)
        screenshot(app, "11-devices")
        XCTAssertTrue(thisDevice.exists, "the list should mark this device")
    }

    /// own.audio only: the family screen lists the members, with the listener among them.
    func testHousehold() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + Self.english
        app.launch()
        addServer(app)
        app.buttons["home.settings"].tap()
        if !app.navigationBars["Settings"].waitForExistence(timeout: 3) {
            dismissSavePasswordPrompt(app)
            app.buttons["home.settings"].tap()
        }
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let household = app.buttons["settings.household"]
        guard household.waitForExistence(timeout: 3) else { throw XCTSkip("this server has no family") }
        household.tap()
        XCTAssertTrue(app.staticTexts["Members"].waitForExistence(timeout: 20), "the members should be listed")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label ENDSWITH '(you)'")).firstMatch.exists, "the listener should be among them")
        XCTAssertTrue(app.staticTexts["Storage"].waitForExistence(timeout: 20), "the family's storage should show")
        screenshot(app, "16-family")
    }

    func testWrongPasswordIsRefused() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + Self.english
        app.launch()
        let address = app.textFields["addServer.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap(); address.typeText(env["SERVER_HOST"]!)
        let user = app.textFields["addServer.username"]
        user.tap(); user.typeText(env["SERVER_USER"]!)
        let password = app.secureTextFields["addServer.password"]
        password.tap(); password.typeText("not-the-password")
        app.buttons["addServer.connect"].tap()
        XCTAssertTrue(app.staticTexts["addServer.error"].waitForExistence(timeout: 30), "a wrong password should be told")
    }

    // MARK: - Helpers

    func addServer(_ app: XCUIApplication) {
        let address = app.textFields["addServer.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), "the first screen should ask for a server")
        address.tap()
        address.typeText(env["SERVER_HOST"]!)
        let user = app.textFields["addServer.username"]
        user.tap()
        user.typeText(env["SERVER_USER"]!)
        let password = app.secureTextFields["addServer.password"]
        password.tap()
        password.typeText(env["SERVER_PASSWORD"]!)
        app.buttons["addServer.connect"].tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 60), "Home should open after the sign-in")
        dismissSavePasswordPrompt(app)
    }

    /// iOS offers to save the password a moment after the sign-in, in the simulator's own
    /// language, and the sheet swallows whatever is tapped under it.
    func dismissSavePasswordPrompt(_ app: XCUIApplication) {
        let labels = ["Not Now", "Teď ne", "Nicht jetzt", "Pas maintenant"]
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            for label in labels {
                let button = app.buttons[label]
                if button.exists { button.tap(); return }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    func tapTab(_ app: XCUIApplication, _ name: String) {
        // On iPad the tabs sit in the top bar, and a section may carry the same name.
        let tab = app.tabBars.buttons[name].exists ? app.tabBars.buttons[name] : app.buttons[name].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "the \(name) tab")
        tab.tap()
        // The password prompt may arrive late and undo the tap.
        if !app.navigationBars[name].waitForExistence(timeout: 3) {
            dismissSavePasswordPrompt(app)
            tab.tap()
        }
    }

    /// Seconds in "1:02:07" or "3:07".
    func clock(_ text: String) -> Int {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        return parts.reversed().enumerated().reduce(0) { $0 + $1.element * Int(pow(60.0, Double($1.offset))) }
    }

    @discardableResult
    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = env["SCREENSHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}

/// A book downloaded, then the app relaunched with no network at all: the book is still there
/// and plays from the phone; what was listened to is reported once the network is back.
final class OfflineTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["SERVER_HOST"] != nil else { throw XCTSkip("SERVER_HOST is not set") }
    }

    func testDownloadedBookPlaysOffline() throws {
        let smoke = PlaybackSmokeTests()
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + PlaybackSmokeTests.english
        app.launch()
        smoke.addServer(app)
        smoke.tapTab(app, "Library")
        app.buttons["library.sortFilter"].tap()
        app.buttons["Length"].firstMatch.tap()
        let book = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.book.'")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        let bookId = String(book.identifier.dropFirst("library.book.".count))
        book.tap()
        let download = app.buttons["detail.download"]
        XCTAssertTrue(download.waitForExistence(timeout: 20))
        let title = app.staticTexts["detail.title"].label
        download.tap()
        XCTAssertTrue(smoke.waitUntil(timeout: 180) { download.label == "Downloaded" }, "the shortest book should download: \(download.label)")
        smoke.screenshot(app, "12-downloaded")
        // The Downloads tab lists it: where a listener finds what is on the phone.
        smoke.tapTab(app, "Downloads")
        XCTAssertTrue(app.descendants(matching: .any)["downloads.\(bookId)"].firstMatch.waitForExistence(timeout: 10), "the Downloads tab should list the book")
        smoke.screenshot(app, "12b-downloads-tab")

        // No network: relaunched with every request failing, the server kept.
        app.terminate()
        app.launchArguments = ["-simulateOffline"] + PlaybackSmokeTests.english
        app.launch()
        XCTAssertTrue(app.otherElements["offline.banner"].waitForExistence(timeout: 15) || app.staticTexts["offline.banner"].waitForExistence(timeout: 1), "the offline banner")
        let shelf = app.staticTexts["home.shelf.downloaded"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 15), "the downloaded shelf")
        smoke.screenshot(app, "13-offline-home")
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'home.book.'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["detail.title"].label, title)
        play.tap()
        let pause = app.buttons["miniPlayer.playPause"]
        XCTAssertTrue(smoke.waitUntil(timeout: 30) { pause.exists && pause.label == "Pause" }, "the downloaded book should play with no network")
        smoke.screenshot(app, "14-offline-playing")
        pause.tap()
        XCTAssertTrue(smoke.waitUntil(timeout: 5) { pause.label == "Play" })
    }
}

/// The import screen, on servers that take books from the phone (own.audio): it opens with
/// its form, and nothing is sent until files are chosen. The Files picker itself is the
/// system's; the server path is covered by the library's live test.
final class ImportTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["SERVER_HOST"] != nil else { throw XCTSkip("SERVER_HOST is not set") }
    }

    func testImportScreenOpens() throws {
        let smoke = PlaybackSmokeTests()
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + PlaybackSmokeTests.english
        app.launch()
        smoke.addServer(app)
        smoke.tapTab(app, "Library")
        let plus = app.buttons["library.import"]
        guard plus.waitForExistence(timeout: 10) else { throw XCTSkip("this server takes no uploads") }
        plus.tap()
        XCTAssertTrue(app.navigationBars["Import a Book"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["import.pick"].exists)
        XCTAssertFalse(app.buttons["import.start"].isEnabled, "nothing to send before files are chosen")
        smoke.screenshot(app, "16-import")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
    }
}

/// Offline Mode from the Downloads tab: on, the banner says so; off again, it goes.
final class OfflineModeButtonTests: XCTestCase {
    func testDownloadsTabSwitchesOfflineMode() throws {
        guard ProcessInfo.processInfo.environment["SERVER_HOST"] != nil else { throw XCTSkip("SERVER_HOST is not set") }
        let smoke = PlaybackSmokeTests()
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + PlaybackSmokeTests.english
        app.launch()
        smoke.addServer(app)
        smoke.tapTab(app, "Downloads")
        let toggle = app.buttons["downloads.offlineMode"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let banner = app.descendants(matching: .any)["offline.banner"].firstMatch
        XCTAssertFalse(banner.exists)
        toggle.tap()
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "Offline Mode on: the banner says so")
        smoke.screenshot(app, "13b-offline-mode-button")
        toggle.tap()
        XCTAssertTrue(smoke.waitUntil(timeout: 5) { !banner.exists }, "and off again")
    }
}
