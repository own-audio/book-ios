import XCTest

/// TEMPORARY: taps the Apple and Google buttons for the canary server and screenshots what
/// opens, to check the client ids by eye. Not part of the suite.
final class ProviderProbeTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["PROBE"] == "1" else { throw XCTSkip("PROBE is not set") }
    }

    func testButtonsOpenTheProviders() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + PlaybackSmokeTests.english
        app.launch()
        let smoke = PlaybackSmokeTests()
        let canary = app.buttons["addServer.canary"]
        XCTAssertTrue(canary.waitForExistence(timeout: 10))
        canary.tap()
        let google = app.buttons["addServer.google"]
        XCTAssertTrue(google.waitForExistence(timeout: 20), "the Google button should appear for canary")
        XCTAssertTrue(app.buttons["addServer.apple"].exists, "the Apple button should appear for canary")
        smoke.screenshot(app, "p1-buttons")

        google.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let proceed = springboard.buttons["Continue"]
        if proceed.waitForExistence(timeout: 10) { proceed.tap() }
        sleep(8)
        smoke.screenshot(app, "p2-google")
        let cancel = app.buttons["Cancel"]
        if cancel.waitForExistence(timeout: 3) { cancel.tap() }

        app.buttons["addServer.apple"].tap()
        sleep(5)
        smoke.screenshot(app, "p3-apple")
    }
}
