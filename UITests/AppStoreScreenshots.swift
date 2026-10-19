import XCTest

/// Screenshots for the App Store and the website, taken on the public demo library ("Try the
/// Demo Library": public-domain LibriVox books, nothing private). Not a test of behaviour: run
/// it on purpose, on the store's device sizes, with a clean status bar
/// (`scripts/app-store-screenshots.sh`). `SCREENSHOT_LANGUAGE` is `en` or `cs`,
/// `SCREENSHOT_DIR` is where the PNGs go. Modelled on the music app's.
final class AppStoreScreenshots: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var czech: Bool { env["SCREENSHOT_LANGUAGE"] == "cs" }

    override func setUpWithError() throws {
        // Every picture that can be taken is worth more than stopping at the first miss.
        continueAfterFailure = true
        guard env["SCREENSHOT_DIR"] != nil, env["SCREENSHOT_LANGUAGE"] != nil else {
            throw XCTSkip("Set SCREENSHOT_DIR and SCREENSHOT_LANGUAGE to take store screenshots")
        }
    }

    private func t(_ english: String, _ czech: String) -> String { self.czech ? czech : english }

    func testTakeScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset", "-AppleLanguages", "(\(env["SCREENSHOT_LANGUAGE"]!))", "-AppleLocale", czech ? "cs_CZ" : "en_US"]
        app.launchChecked()

        let demo = app.buttons["addServer.demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 15))
        demo.tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 90), "Home should open on the demo")
        // Covers and shelves in.
        sleep(8)
        save(app, "1-home")

        tab(app, t("Library", "Knihovna")).tap()
        let book = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.book.'")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30), "the demo should have books")
        sleep(5)
        save(app, "2-library")

        book.tap()
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        sleep(4)
        save(app, "3-book")

        play.tap()
        let miniPlayer = app.buttons["miniPlayer"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 40))
        let pause = app.buttons["miniPlayer.playPause"]
        _ = waitUntil(timeout: 40) { pause.exists && pause.label == t("Pause", "Pozastavit") }
        sleep(8)
        miniPlayer.tap()
        XCTAssertTrue(app.descendants(matching: .any)["player.scrubber"].firstMatch.waitForExistence(timeout: 15))
        sleep(4)
        save(app, "4-player")

        // The chapters, where the player offers them.
        let chapter = app.buttons["player.chapter"]
        if chapter.waitForExistence(timeout: 5) {
            chapter.tap()
            sleep(3)
            save(app, "5-chapters")
            dismissSheet(app)
        }

        // The sleep timer and speed, as the player shows them.
        let speed = app.buttons["speed.value"]
        if speed.waitForExistence(timeout: 5) {
            speed.tap()
            sleep(2)
            save(app, "6-speed")
            dismissSheet(app)
        }
        if app.buttons["player.close"].exists { app.buttons["player.close"].tap() }

        tab(app, t("Search", "Hledat")).tap()
        sleep(2)
    }

    private func dismissSheet(_ app: XCUIApplication) {
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Hotovo"])).firstMatch
        if done.waitForExistence(timeout: 2) { done.tap(); return }
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
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }
}
