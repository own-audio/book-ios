import XCTest

/// Downloads as sets, the server's page, and the whole library offline — on own.audio servers,
/// where the account owns the tiny book the import test made ("Test Author").
final class DownloadSetTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["SERVER_HOST"] != nil else { throw XCTSkip("SERVER_HOST is not set") }
    }

    func testServerPageAuthorSetAndWholeLibraryOffline() throws {
        let smoke = PlaybackSmokeTests()
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + PlaybackSmokeTests.english
        app.launchChecked()
        smoke.addServer(app)

        // Settings → the server: the copy of the library on the phone.
        app.buttons["home.settings"].tap()
        if !app.navigationBars["Settings"].waitForExistence(timeout: 3) {
            smoke.dismissSavePasswordPrompt(app)
            app.buttons["home.settings"].tap()
        }
        let info = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'servers.row.'")).firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 10), "every server row should have a details button")
        info.tap()
        XCTAssertTrue(app.buttons["serverDetail.check"].waitForExistence(timeout: 10))
        let catalogue = app.descendants(matching: .any)["serverDetail.catalogue"].firstMatch
        guard catalogue.waitForExistence(timeout: 20) else { throw XCTSkip("not an own.audio server") }
        XCTAssertTrue(catalogue.label.hasPrefix("Books:"), catalogue.label)
        smoke.screenshot(app, "17-server-detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Servers"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let whole = app.switches["settings.wholeLibrary"]
        XCTAssertTrue(whole.waitForExistence(timeout: 5), "an own.audio server brings the Whole Library setting")
        // The row's element covers the label too; the switch inside it is what toggles.
        for _ in 0..<3 where (whole.value as? String) != "1" {
            whole.switches.firstMatch.tap()
            if smoke.waitUntil(timeout: 3, { (whole.value as? String) == "1" }) { break }
            smoke.dismissSavePasswordPrompt(app)
        }
        XCTAssertEqual(whole.value as? String, "1", "the setting should turn on")
        app.buttons["Done"].firstMatch.tap()

        // An author's books, downloaded as one set.
        smoke.tapTab(app, "Library")
        let authors = app.buttons["library.authors"]
        XCTAssertTrue(authors.waitForExistence(timeout: 40))
        authors.tap()
        // The filter field hides under the bar until the list is pulled; the row is found by name.
        let author = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'people.' AND label CONTAINS 'Test Author'")).firstMatch
        guard author.waitForExistence(timeout: 15) else { throw XCTSkip("no Test Author on this server; run the live import test first") }
        if !author.isHittable { app.swipeUp() }
        author.tap()
        let start = app.buttons["setDownload.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20), "an author's list should offer Download All")
        start.tap()
        let done = app.descendants(matching: .any)["setDownload.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 120), "the author's books should download")
        smoke.screenshot(app, "18-set-downloaded")

        // Offline with Whole Library on: more than the one download is listed.
        app.terminate()
        app.launchArguments = ["-simulateOffline"] + PlaybackSmokeTests.english
        app.launchChecked()
        smoke.tapTab(app, "Library")
        let books = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.book.'"))
        XCTAssertTrue(smoke.waitUntil(timeout: 30) { books.count > 1 }, "offline, the whole library should be listed, not the one download: \(books.count)")
        smoke.screenshot(app, "19-whole-library-offline")
    }
}
