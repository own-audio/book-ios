import XCTest

/// The app at the largest accessibility text size: the screens a listener meets still work and
/// their controls are still there. The screenshots are for a look by eye.
final class LargeTextTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["SERVER_HOST"] != nil else { throw XCTSkip("SERVER_HOST is not set") }
    }

    func testScreensAtAccessibilityXXXL() throws {
        let smoke = PlaybackSmokeTests()
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] + PlaybackSmokeTests.english
        app.launchChecked()
        XCTAssertTrue(app.buttons["addServer.connect"].waitForExistence(timeout: 10))
        smoke.screenshot(app, "large-00-onboarding")
        smoke.addServer(app)
        smoke.screenshot(app, "large-01-home")
        smoke.tapTab(app, "Library")
        let book = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.book.'")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        smoke.screenshot(app, "large-02-library")
        book.tap()
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        smoke.screenshot(app, "large-03-detail")
        play.tap()
        let miniPlayer = app.buttons["miniPlayer"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 40))
        smoke.screenshot(app, "large-04-mini-player")
        miniPlayer.tap()
        XCTAssertTrue(app.buttons["player.playPause"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["player.skipForward"].exists && app.buttons["player.skipBackward"].exists, "the controls should fit")
        smoke.screenshot(app, "large-05-player")
        app.buttons["player.playPause"].tap()
        app.buttons["player.close"].tap()
        smoke.tapTab(app, "Home")
        app.buttons["home.settings"].tap()
        if !app.navigationBars["Settings"].waitForExistence(timeout: 3) { smoke.dismissSavePasswordPrompt(app); app.buttons["home.settings"].tap() }
        XCTAssertTrue(app.buttons["servers.add"].waitForExistence(timeout: 10))
        smoke.screenshot(app, "large-06-settings")
    }
}
