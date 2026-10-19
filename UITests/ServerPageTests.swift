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
        let servers = app.buttons["settings.servers"]
        if !servers.waitForExistence(timeout: 5) { smoke.dismissSavePasswordPrompt(app); settings.tap() }
        XCTAssertTrue(servers.waitForExistence(timeout: 10))
        servers.tap()
        let info = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'servers.info.'")).firstMatch
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
}
