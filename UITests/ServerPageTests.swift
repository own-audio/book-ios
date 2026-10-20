import XCTest

/// The server page as in the podcasts app: Automatic or a fixed address, the addresses with where
/// each came from, one added by hand and removed again. Needs `SERVER_*`.
final class ServerPageTests: XCTestCase {
    private let smoke = PlaybackSmokeTests()

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SERVER_HOST"] != nil else { throw XCTSkip("SERVER_HOST is not set") }
    }

    func testAddressesOnTheServerPage() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + PlaybackSmokeTests.english
        app.launchChecked()
        smoke.addServer(app)
        let settings = app.buttons["home.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        // Settings lists the servers itself, as in the podcasts app.
        let servers = app.buttons["servers.add"]
        if !servers.waitForExistence(timeout: 5) { smoke.dismissSavePasswordPrompt(app); settings.tap() }
        XCTAssertTrue(servers.waitForExistence(timeout: 10))
        let info = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'servers.row.'")).firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 10))
        info.tap()

        let add = app.buttons["serverDetail.addAddress"]
        for _ in 0..<5 where !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.exists, "Add Address on the server page")
        XCTAssertTrue(app.descendants(matching: .any)["serverDetail.mode"].exists || app.buttons["Automatic"].exists, "Automatic or a fixed address")
        add.tap()
        // A field in an alert doesn't keep its identifier: the alert's one field.
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.exists)
        field.typeText("http://192.168.1.20:13378")
        alert.buttons["Add"].tap()
        let row = app.descendants(matching: .any)["serverDetail.address.http://192.168.1.20:13378"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the address is listed")
        XCTAssertTrue(row.label.contains("Added by you"), row.label)
        row.swipeLeft()
        app.buttons["Remove"].firstMatch.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "and removed again")
    }

    /// Renamed and removed on its page, as in the podcasts and music apps; removing asks first.
    func testRenameAndRemoveOnTheServerPage() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + PlaybackSmokeTests.english
        app.launchChecked()
        smoke.addServer(app)
        let settings = app.buttons["home.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        // Settings lists the servers itself, as in the podcasts app.
        let servers = app.buttons["servers.add"]
        if !servers.waitForExistence(timeout: 5) { smoke.dismissSavePasswordPrompt(app); settings.tap() }
        XCTAssertTrue(servers.waitForExistence(timeout: 10))
        let info = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'servers.row.'")).firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 10))
        info.tap()

        let name = app.buttons["serverDetail.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        let field = app.alerts.firstMatch.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + "Books Renamed")
        let save = app.alerts.firstMatch.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        if app.alerts.firstMatch.exists { app.alerts.firstMatch.buttons.element(boundBy: 1).tap() }
        XCTAssertTrue(app.navigationBars["Books Renamed"].waitForExistence(timeout: 5), "the page shows the new name")

        let remove = app.buttons["serverDetail.remove"]
        for _ in 0..<8 where !remove.isHittable { app.swipeUp() }
        remove.tap()
        let confirm = app.buttons["Remove"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "it asks first")
        confirm.tap()
        XCTAssertTrue(app.textFields["addServer.address"].waitForExistence(timeout: 15), "with no server left, the welcome screen")
    }

    /// Settings → Add a Server opens the sign-in sheet, and it stays open. It used to close at
    /// once: the sheet hung on the servers' section, not on the Settings screen.
    func testAddServerSheetStaysOpen() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + PlaybackSmokeTests.english
        app.launchChecked()
        smoke.addServer(app)
        let settings = app.buttons["home.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let add = app.buttons["servers.add"]
        if !add.waitForExistence(timeout: 5) { smoke.dismissSavePasswordPrompt(app); settings.tap() }
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let address = app.textFields["addServer.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), "the sign-in sheet opens")
        sleep(3)
        XCTAssertTrue(address.exists, "and stays open")
    }
}
