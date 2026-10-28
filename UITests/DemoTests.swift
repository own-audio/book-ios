import XCTest

/// "Try the Demo Library" on the first screen signs in to the public own.audio demo and plays
/// from it. Needs the network, so only `scripts/test-servers.sh demo` runs it.
final class DemoTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["DEMO"] == "1" else { throw XCTSkip("DEMO is not set") }
    }

    func testTryTheDemoLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + PlaybackSmokeTests.english
        app.launchChecked()

        let demo = app.buttons["addServer.demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        demo.tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 60), "Home should open on the demo")

        let tab = app.tabBars.buttons["Library"].exists ? app.tabBars.buttons["Library"] : app.buttons["Library"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        let book = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.book.'")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30), "the demo should have books")
        book.tap()
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.tap()
        let pause = app.buttons["miniPlayer.playPause"]
        let deadline = Date().addingTimeInterval(40)
        while !(pause.exists && pause.label == "Pause"), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        XCTAssertTrue(pause.exists && pause.label == "Pause", "the demo should play")
    }

    /// After the demo sign-in: the accent colour, the account's listening and the way to delete
    /// it. The dialog is cancelled; the demo refuses deletion anyway. Ported from own.audio Music.
    func testSettingsOnTheDemo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + PlaybackSmokeTests.english
        app.launchChecked()
        app.buttons["addServer.demo"].tap()
        let settings = app.buttons["home.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 60), "Home should open on the demo")
        settings.tap()

        let green = app.buttons["settings.accent.green"]
        for _ in 0..<8 where !green.isHittable { app.swipeUp() }
        XCTAssertTrue(green.waitForExistence(timeout: 5), "Settings should offer accent colours")
        green.tap()
        XCTAssertTrue(green.isSelected, "the chosen colour should be marked")
        app.buttons["settings.accent.app"].tap()
        XCTAssertTrue(app.buttons["settings.accent.app"].isSelected)

        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'servers.row.'")).firstMatch
        for _ in 0..<8 where !row.isHittable { app.swipeDown() }
        row.tap()

        let listening = app.buttons["serverDetail.listening"]
        for _ in 0..<4 where !listening.isHittable { app.swipeUp() }
        XCTAssertTrue(listening.waitForExistence(timeout: 10))
        listening.tap()
        XCTAssertTrue(app.staticTexts["Listened"].waitForExistence(timeout: 20), "the listening statistics should load")
        app.segmentedControls.buttons["Year"].tap()
        XCTAssertTrue(app.staticTexts["Listened"].waitForExistence(timeout: 20))
        app.navigationBars.buttons.firstMatch.tap()

        let delete = app.buttons["serverDetail.deleteAccount"]
        for _ in 0..<6 where !delete.isHittable { app.swipeDown() }
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "an own.audio account can be deleted from the app")
        delete.tap()
        XCTAssertTrue(app.staticTexts["Delete Your Account?"].waitForExistence(timeout: 5))
        // Never confirmed: only Cancel, or a tap outside the dialog, closes it.
        let cancel = app.buttons["Cancel"]
        if cancel.exists { cancel.tap() } else { app.tap() }
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "cancelling keeps the server")
        XCTAssertFalse(app.staticTexts["Delete Your Account?"].exists)
    }
}
