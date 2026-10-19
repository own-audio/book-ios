import XCTest

/// On an iPad the Library tab is a sidebar beside the open section; run with an iPad simulator
/// (`SIMULATOR_ID=<iPad>`), skipped on an iPhone.
final class IPadTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["SERVER_HOST"] != nil else { throw XCTSkip("SERVER_HOST is not set") }
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("an iPad simulator is needed") }
    }

    func testLibrarySidebar() throws {
        let smoke = PlaybackSmokeTests()
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + PlaybackSmokeTests.english
        app.launchChecked()
        smoke.addServer(app)
        smoke.tapTab(app, "Library")
        let books = app.descendants(matching: .any)["sidebar.books"].firstMatch
        XCTAssertTrue(books.waitForExistence(timeout: 20), "the Library tab should show a sidebar on iPad")
        let grid = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.book.'")).firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 40), "the books should open beside the sidebar")
        XCTAssertFalse(app.buttons["library.authors"].exists, "the chips give way to the sidebar")
        smoke.screenshot(app, "20-ipad-library")
        let authors = app.descendants(matching: .any)["sidebar.authors"].firstMatch
        authors.tap()
        XCTAssertTrue(app.navigationBars["Authors"].waitForExistence(timeout: 20), "the section opens in the detail column")
        let person = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'people.'")).firstMatch
        XCTAssertTrue(person.waitForExistence(timeout: 30))
        person.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.book.'")).firstMatch.waitForExistence(timeout: 30), "an author's books open in the same column")
        smoke.screenshot(app, "21-ipad-author")
    }
}
