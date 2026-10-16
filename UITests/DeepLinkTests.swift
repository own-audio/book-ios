import XCTest

/// `ownbook://play/<book>` — what the widget and Siri open — starts that book.
final class DeepLinkTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["SERVER_HOST"] != nil else { throw XCTSkip("SERVER_HOST is not set") }
    }

    func testPlayLinkStartsTheBook() throws {
        let smoke = PlaybackSmokeTests()
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + PlaybackSmokeTests.english
        app.launch()
        smoke.addServer(app)
        smoke.tapTab(app, "Library")
        let book = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.book.'")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        let bookId = String(book.identifier.dropFirst("library.book.".count))
        let title = book.staticTexts.firstMatch.label
        smoke.tapTab(app, "Home")
        let escaped = bookId.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        // open(_:) relaunches the app with its launch arguments: without the reset, the server stays.
        app.launchArguments = PlaybackSmokeTests.english
        app.open(URL(string: "ownbook://play/\(escaped)")!)
        let pause = app.buttons["miniPlayer.playPause"]
        XCTAssertTrue(smoke.waitUntil(timeout: 40) { pause.exists && pause.label == "Pause" }, "the link should start the book")
        XCTAssertTrue(app.buttons["miniPlayer"].label.contains(title) || app.staticTexts[title].exists, "the mini player should show \(title)")
        smoke.screenshot(app, "22-deep-link")
        pause.tap()
    }
}
