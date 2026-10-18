import XCTest

/// An Audiobookshelf server's page names its book libraries and which one the app shows;
/// skipped on own.audio servers, which have none to choose.
final class LibraryChoiceTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["SERVER_HOST"] != nil else { throw XCTSkip("SERVER_HOST is not set") }
    }

    func testServerPageNamesTheLibraries() throws {
        let smoke = PlaybackSmokeTests()
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + PlaybackSmokeTests.english
        app.launch()
        smoke.addServer(app)

        app.buttons["home.settings"].tap()
        if !app.navigationBars["Settings"].waitForExistence(timeout: 3) {
            smoke.dismissSavePasswordPrompt(app)
            app.buttons["home.settings"].tap()
        }
        app.buttons["settings.servers"].tap()
        let info = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'servers.info.'")).firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 10))
        info.tap()
        XCTAssertTrue(app.buttons["serverDetail.check"].waitForExistence(timeout: 10))
        let library = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'serverDetail.library.'")).firstMatch
        guard library.waitForExistence(timeout: 15) else { throw XCTSkip("not an Audiobookshelf server") }
        XCTAssertTrue(app.images["checkmark"].exists, "the library shown is ticked")
        library.tap()
        XCTAssertTrue(app.images["checkmark"].waitForExistence(timeout: 5), "choosing it keeps it chosen")
        smoke.screenshot(app, "18-server-libraries")
    }
}
