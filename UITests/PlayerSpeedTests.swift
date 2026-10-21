import XCTest

/// The player's speed button and sheet show the speed it plays at — "1×", "0.75×", "1.75×" — on
/// the demo library.
final class PlayerSpeedTests: XCTestCase {
    func testSpeedButtonShowsTheSpeed() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + PlaybackSmokeTests.english
        app.launchChecked()
        let demo = app.buttons["addServer.demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        demo.tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 60))
        let tab = app.tabBars.buttons["Library"].exists ? app.tabBars.buttons["Library"] : app.buttons["Library"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        let book = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.book.'")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        book.tap()
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.tap()
        let mini = app.buttons["miniPlayer"]
        XCTAssertTrue(mini.waitForExistence(timeout: 40))
        mini.tap()
        let speed = app.buttons["player.speed"]
        XCTAssertTrue(speed.waitForExistence(timeout: 10))
        sleep(2)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "player-speed"
        shot.lifetime = .keepAlways
        add(shot)
        let shown = speed.staticTexts.allElementsBoundByIndex.map { $0.label }
        print("SPEED-LABEL", speed.label, "TEXTS", shown)
        XCTAssertTrue(shown.contains { $0.hasPrefix("1") && $0.hasSuffix("×") }, "the button shows 1×: \(shown)")

        for preset in ["0.75", "1.75"] {
            speed.tap()
            let button = app.buttons["speed.preset.\(preset)"]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.tap()
            let value = app.staticTexts["speed.value"].label
            print("SPEED-SHEET", preset, value)
            app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Hotovo"])).firstMatch.tap()
            sleep(1)
            let texts = speed.staticTexts.allElementsBoundByIndex.map { $0.label }
            print("SPEED-BUTTON", preset, texts)
            // Two decimals where the speed has them: "%.2g" turned 1.75 into "1.8×".
            XCTAssertTrue(texts.contains("\(preset)×"), "the button shows \(preset)×: \(texts)")
            XCTAssertEqual(value, "\(preset)×", "the sheet too")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "player-speed-\(preset)"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }
}
