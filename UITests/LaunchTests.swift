import XCTest

/// The app launches and shows its first screen. Needs no server, so it runs on every build.
final class LaunchTests: XCTestCase {
    func testLaunchesToTheFirstScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        // A clean start lands on the first screen, which asks for a server.
        XCTAssertTrue(app.textFields["addServer.address"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["addServer.demo"].exists)
    }
}
