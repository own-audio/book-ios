import XCTest

/// The narration sheet on a hosted own.audio server (`NARRATION_HOST`, `NARRATION_EMAIL`,
/// `NARRATION_PASSWORD`): the Library's + offers it, the voices load. No job is started — that
/// would spend the family's credit.
final class NarrationTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let host = env["NARRATION_HOST"], !host.isEmpty else { throw XCTSkip("NARRATION_HOST is not set") }
    }

    func testNarrationSheetOffersVoices() throws {
        let smoke = PlaybackSmokeTests()
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + PlaybackSmokeTests.english
        app.launch()
        let address = app.textFields["addServer.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap(); address.typeText(env["NARRATION_HOST"]!)
        app.textFields["addServer.username"].tap(); app.textFields["addServer.username"].typeText(env["NARRATION_EMAIL"]!)
        app.secureTextFields["addServer.password"].tap(); app.secureTextFields["addServer.password"].typeText(env["NARRATION_PASSWORD"]!)
        app.buttons["addServer.connect"].tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 60), "Home should open after the sign-in")
        smoke.dismissSavePasswordPrompt(app)

        smoke.tapTab(app, "Library")
        let add = app.buttons["library.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 30), "a server with narration should show the + menu")
        add.tap()
        let narrate = app.buttons["library.narrate"].firstMatch
        XCTAssertTrue(narrate.waitForExistence(timeout: 5))
        narrate.tap()
        let target = app.descendants(matching: .any)["narrate.targetLanguage"].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 30), "the languages and voices should load")
        XCTAssertTrue(app.descendants(matching: .any)["narrate.voice"].firstMatch.exists)
        XCTAssertFalse(app.buttons["narrate.start"].isEnabled, "nothing to start before a file and a price")
        smoke.screenshot(app, "23-narrate")
        app.buttons["Cancel"].firstMatch.tap()
    }
}
