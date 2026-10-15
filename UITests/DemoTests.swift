import XCTest

/// "Try the Demo Library" on the first screen signs in to the public own.audio demo and plays
/// from it. Needs the network, so only `scripts/test-servers.sh demo` runs it.
final class DemoTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["DEMO"] == "1" else { throw XCTSkip("DEMO is not set") }
    }

    func testTryTheDemoLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + PlaybackSmokeTests.english
        app.launch()

        let demo = app.buttons["addServer.demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        demo.tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 60), "Home should open on the demo")

        let tab = app.tabBars.buttons["Library"].exists ? app.tabBars.buttons["Library"] : app.buttons["Library"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        let book = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.book.'")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30), "the demo should have books")
        book.tap()
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.tap()
        let pause = app.buttons["miniPlayer.playPause"]
        let deadline = Date().addingTimeInterval(40)
        while !(pause.exists && pause.label == "Pause"), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        XCTAssertTrue(pause.exists && pause.label == "Pause", "the demo should play")
    }
}
