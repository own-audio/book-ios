import XCTest

/// The app launches and shows its first screen. Needs no server, so it runs on every build.
final class LaunchTests: XCTestCase {
    func testLaunchesToTheFirstScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchChecked()
        // A clean start lands on the first screen, which asks for a server.
        XCTAssertTrue(app.textFields["addServer.address"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["addServer.demo"].exists)
    }

    /// Cold start, five times; the number lands in the result bundle and the summary.
    func testLaunchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
        }
    }
}
