import XCTest

/// The app in Czech: the screens a listener meets first, with the Czech words on them.
final class CzechScreensTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["SERVER_HOST"] != nil else { throw XCTSkip("SERVER_HOST is not set") }
    }

    func testCzechScreens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset", "-AppleLanguages", "(cs)", "-AppleLocale", "cs_CZ"]
        app.launch()
        XCTAssertTrue(app.buttons["addServer.demo"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["addServer.demo"].label, "Vyzkoušet ukázkovou knihovnu")
        XCTAssertEqual(app.buttons["addServer.connect"].label, "Připojit")

        let smoke = PlaybackSmokeTests()
        let address = app.textFields["addServer.address"]
        address.tap(); address.typeText(env["SERVER_HOST"]!)
        app.textFields["addServer.username"].tap(); app.textFields["addServer.username"].typeText(env["SERVER_USER"]!)
        app.secureTextFields["addServer.password"].tap(); app.secureTextFields["addServer.password"].typeText(env["SERVER_PASSWORD"]!)
        app.buttons["addServer.connect"].tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 60))
        smoke.dismissSavePasswordPrompt(app)
        let greeting = app.staticTexts["home.greeting"]
        XCTAssertTrue(greeting.waitForExistence(timeout: 10))
        XCTAssertTrue(["Dobré ráno", "Dobré odpoledne", "Dobrý večer"].contains(greeting.label), greeting.label)

        smoke.tapTab(app, "Knihovna")
        XCTAssertTrue(app.buttons["library.authors"].waitForExistence(timeout: 40))
        XCTAssertEqual(app.buttons["library.authors"].label, "Autoři")
        let book = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.book.'")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        book.tap()
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        XCTAssertEqual(play.label, "Přehrát")
        XCTAssertTrue(app.buttons["Kapitoly"].exists, "the detail's sections should be Czech")
        let settings = app.buttons["home.settings"]
        app.buttons["Domů"].firstMatch.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Nastavení"].waitForExistence(timeout: 10))
    }
}
