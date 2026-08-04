import XCTest

/// The iPhone shell, driven for real: tabs, routes, capture, and the promises the
/// navigation makes. Every test launches against a throwaway store and fixture
/// providers, so nothing here can touch a person's calendar, contacts, or reminders.
///
/// The suite grows with the screens: today it asserts the shell's own contract — every
/// tab reachable, every Library row landing somewhere, per-tab stacks surviving a tab
/// switch, the capture sheet never a dead tap. Each module pass adds its own assertions.
final class MobileShellUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(sampleData: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ElephruitDevelopmentMode",
            "-ElephruitUseTemporaryStore",
            "-ElephruitUseFixtureCalendar",
            "-ElephruitUseFixtureContacts",
            "-ElephruitUseFixtureReminders",
            "-ElephruitFixturesAuthorized",
        ]
        if sampleData {
            app.launchArguments.append("-ElephruitLoadSampleData")
        }
        app.launch()
        return app
    }

    // MARK: - Shell

    /// Every tab is reachable, and each shows its own root.
    func testTabsNavigate() throws {
        let app = launch()

        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))

        app.tabBars.buttons["Reminders"].tap()
        XCTAssertTrue(app.navigationBars["Reminders"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Records"].tap()
        XCTAssertTrue(app.navigationBars["Records"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Calendar"].exists)

        app.tabBars.buttons["Today"].tap()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 5))
    }

    /// Every Library row lands on its own screen and back returns to the Library.
    func testLibraryRowsNavigate() throws {
        let app = launch()

        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))

        for row in ["Inbox", "Notes", "Calendar", "Time", "Settings"] {
            app.staticTexts[row].tap()
            XCTAssertTrue(
                app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 5),
                "Tapping \(row) should push a screen with a back button"
            )
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
        }
    }

    /// A drill-down survives switching tabs: per-tab stacks are the shell's core promise.
    func testDrillDownSurvivesTabSwitch() throws {
        let app = launch()

        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
        app.staticTexts["Inbox"].tap()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Today"].tap()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(
            app.navigationBars["Inbox"].waitForExistence(timeout: 5),
            "Returning to Library should find the Inbox still open"
        )
    }

    // MARK: - Capture

    /// The capture button is never a dead tap, and a cancelled sheet goes away.
    func testCaptureSheetOpensAndDismisses() throws {
        let app = launch()

        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        app.buttons["mobile.capture.button"].tap()
        XCTAssertTrue(app.navigationBars["Capture"].waitForExistence(timeout: 5))

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 5))
    }
}
