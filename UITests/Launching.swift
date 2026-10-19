import XCTest

extension XCUIApplication {
    /// Launches with the arguments set, and makes sure they arrived. iOS prewarms apps it
    /// expects to be opened: it starts the process early, without arguments, and a test's launch
    /// can then be handed that process — in the device's language, without `-uiTestReset`. The
    /// first screen tells: it must be in the language asked for, and after a reset it must be
    /// the welcome screen. If not, the launch is tried again. Copied from the podcasts app.
    func launchChecked(file: StaticString = #filePath, line: UInt = #line) {
        let czech = launchArguments.contains("(cs)")
        let reset = launchArguments.contains("-uiTestReset")
        let settings = czech ? "Nastavení" : "Settings"
        let demo = czech ? "Vyzkoušet ukázkovou knihovnu" : "Try the Demo Library"
        for attempt in 1...3 {
            if state != .notRunning { terminate() }
            launch()
            let home = buttons["home.settings"], welcome = buttons["addServer.demo"]
            let end = Date().addingTimeInterval(30)
            while Date() < end, !home.exists, !welcome.exists { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
            let welcomeOK = welcome.exists && welcome.label == demo
            let homeOK = !reset && home.exists && home.label == settings
            // A test that adds its server through the launch arguments lands on Home after a reset.
            let debugServer = launchArguments.contains("-debugServerHost") && home.exists && home.label == settings
            if welcomeOK || homeOK || debugServer { return }
            if attempt == 3 { XCTFail("the app didn't start with its arguments", file: file, line: line) }
        }
    }
}
