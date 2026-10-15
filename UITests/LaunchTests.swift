import XCTest

/// The app launches and shows its first screen. Needs no server, so it runs on every build.
final class LaunchTests: XCTestCase {
    func testLaunchesToTheFirstScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.otherElements["root.placeholder"].waitForExistence(timeout: 10)
            || app.staticTexts["root.placeholder"].waitForExistence(timeout: 1))
    }
}
