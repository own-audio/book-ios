import XCTest

/// The player's parity with the other apps: the AirPlay button among its tools, every tool on
/// screen, and the last book back in the mini player after a relaunch. Needs `SERVER_*`.
final class PlayerParityTests: XCTestCase {
    private let smoke = PlaybackSmokeTests()
    private let env = ProcessInfo.processInfo.environment

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["SERVER_HOST"] != nil else { throw XCTSkip("SERVER_HOST is not set") }
    }

    /// The first book of the library, playing.
    private func startBook(_ app: XCUIApplication) {
        smoke.tapTab(app, "Library")
        let book = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.book.'")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        book.tap()
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.tap()
        let pause = app.buttons["miniPlayer.playPause"]
        XCTAssertTrue(smoke.waitUntil(timeout: 40) { pause.exists && pause.label == "Pause" }, "playback starts")
    }

    func testToolsOnScreenWithAirPlay() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + PlaybackSmokeTests.english
        app.launchChecked()
        smoke.addServer(app)
        startBook(app)
        app.buttons["miniPlayer"].tap()
        XCTAssertTrue(app.staticTexts["player.elapsed"].waitForExistence(timeout: 10))
        let screen = app.windows.firstMatch.frame
        for id in ["player.speed", "player.sleep", "player.bookmarks", "player.chapters", "player.airplay"] {
            let tool = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(tool.exists, id)
            XCTAssertTrue(screen.contains(tool.frame), "\(id) is on screen: \(tool.frame) in \(screen)")
        }
        app.buttons["player.stop"].tap()
    }

    /// Played, paused, the app killed and started again: the book waits in the mini player and
    /// plays on from where it was. Stop clears it.
    func testLastBookBackAfterARelaunch() {
        var app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + PlaybackSmokeTests.english
        app.launchChecked()
        smoke.addServer(app)
        startBook(app)
        app.buttons["miniPlayer"].tap()
        let elapsed = app.staticTexts["player.elapsed"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
        app.buttons["player.skipForward"].tap()
        app.buttons["player.skipForward"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        app.buttons["player.playPause"].tap()
        let before = smoke.clock(elapsed.label)
        XCTAssertGreaterThanOrEqual(before, 50)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        app.terminate()

        app = XCUIApplication()
        app.launchArguments = PlaybackSmokeTests.english
        app.launchChecked()
        let last = app.buttons["miniPlayer.last"]
        XCTAssertTrue(last.waitForExistence(timeout: 30), "the last book waits in the mini player")
        last.tap()
        let again = app.staticTexts["player.elapsed"]
        XCTAssertTrue(again.waitForExistence(timeout: 30), "a tap plays it and opens the player")
        XCTAssertTrue(smoke.waitUntil(timeout: 20) { smoke.clock(again.label) >= before - 3 }, "from where it was: \(again.label), was \(before)")

        app.buttons["player.stop"].tap()
        app.terminate()
        app.launchChecked()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["miniPlayer.last"].waitForExistence(timeout: 5), "Stop clears it")
    }
}
