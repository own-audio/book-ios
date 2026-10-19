import XCTest

/// Favourites on own.audio: marked on a book's page, a badge on its cover, and the Library's
/// Favourites filter; the mark is taken off again so the account ends as it began. Needs
/// `SERVER_*` pointing at own.audio (Audiobookshelf has no favourites).
final class FavouritesTests: XCTestCase {
    private let smoke = PlaybackSmokeTests()

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SERVER_HOST"] != nil else { throw XCTSkip("SERVER_HOST is not set") }
    }

    func testFavouriteBadgeAndFilter() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + PlaybackSmokeTests.english
        app.launchChecked()
        smoke.addServer(app)
        smoke.tapTab(app, "Library")
        let book = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.book.'")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        let bookId = book.identifier
        book.tap()
        let more = app.buttons["detail.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.tap()
        guard app.buttons["Add to Favourites"].waitForExistence(timeout: 5) || app.buttons["Remove Favourite"].exists else {
            throw XCTSkip("this server has no favourites (Audiobookshelf)")
        }
        // A run that died halfway may have left the mark: start from none.
        if app.buttons["Remove Favourite"].exists {
            app.buttons["Remove Favourite"].tap()
            more.tap()
        }
        app.buttons["Add to Favourites"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let sortFilter = app.buttons["library.sortFilter"]
        XCTAssertTrue(sortFilter.waitForExistence(timeout: 10))
        sortFilter.tap()
        let favourites = app.buttons["Favourites"].firstMatch
        XCTAssertTrue(favourites.waitForExistence(timeout: 5), "the Favourites filter")
        favourites.tap()
        let only = app.descendants(matching: .any)[bookId]
        XCTAssertTrue(only.waitForExistence(timeout: 10), "the favourite is listed")
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.book.'")).count, 1, "and only it")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Favourite'")).firstMatch.exists, "with the badge")

        only.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.tap()
        app.buttons["Remove Favourite"].tap()
    }
}
