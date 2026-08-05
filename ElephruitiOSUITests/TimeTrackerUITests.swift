import XCTest

/// The tracker on the phone, driven the way a thumb drives it.
///
/// The Time screen is the one surface where the app makes a claim about the world — this ran
/// for this long — so its controls are worth pressing in a real build rather than reasoning
/// about. Every assertion here is about a control existing at the moment it should: a Stop that
/// is not there while something runs is the whole feature failing, and it is invisible to a
/// unit test that only ever talks to `TimerService`.
final class TimeTrackerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ElephruitDevelopmentMode",
            "-ElephruitUseTemporaryStore",
            "-ElephruitLoadSampleData",
        ]
        app.launch()
        return app
    }

    private func openTime(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 15))
        if !app.buttons["mobile.sidebar.time"].exists {
            app.buttons["mobile.sidebar.button"].tap()
        }
        XCTAssertTrue(app.buttons["mobile.sidebar.time"].waitForExistence(timeout: 5))
        app.buttons["mobile.sidebar.time"].tap()
        XCTAssertTrue(app.navigationBars["Time"].waitForExistence(timeout: 5))
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Start, name, file, pause, resume, stop — the whole sitting, in the order somebody does it.
    func testTheSittingCanBeRunFromThePhone() throws {
        let app = launch()
        openTime(app)
        snap(app, "01-idle")

        app.buttons["time.start"].tap()

        let stop = app.buttons["time.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "starting a timer did not produce a Stop")
        XCTAssertTrue(app.buttons["time.pause"].exists, "a running timer has no Pause")

        let description = app.textFields["time.description"]
        XCTAssertTrue(description.waitForExistence(timeout: 5))
        description.tap()
        description.typeText("Drafting the brief")
        snap(app, "02-running")

        // The filing chips are the reason this card exists rather than a Start button: an entry
        // that cannot say what it was against is one somebody reconstructs later.
        XCTAssertTrue(app.buttons["time.subject"].exists, "no subject chip")
        XCTAssertTrue(app.buttons["time.project"].exists, "no project chip")
        XCTAssertTrue(app.buttons["time.people"].exists, "no people chip")
        XCTAssertTrue(app.buttons["time.tags"].exists, "no tag chip")

        app.buttons["time.billable"].tap()
        app.buttons["time.subject"].tap()
        XCTAssertTrue(
            app.staticTexts["Subject"].waitForExistence(timeout: 5),
            "the subject chip opened nothing"
        )
        snap(app, "03-subject")
        // Dismissing a popover is a tap outside it.
        app.navigationBars["Time"].tap()

        app.buttons["time.pause"].tap()
        let resume = app.buttons["time.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "pausing offered nothing to resume")
        snap(app, "04-paused")

        resume.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "resuming did not start the clock again")

        stop.tap()
        XCTAssertTrue(
            app.buttons["time.start"].waitForExistence(timeout: 5),
            "stopping left no way to start again"
        )
        // The log is a fetch, and a fetch does not know it has gone stale. A sitting that
        // finished and did not appear underneath it is the version of this screen that made
        // people check on the Mac to see whether the phone had recorded anything at all.
        XCTAssertTrue(
            app.staticTexts["Drafting the brief"].waitForExistence(timeout: 5),
            "the stopped entry never appeared in the log"
        )
        snap(app, "05-stopped")
    }

    /// A running timer reaches the Dynamic Island, and stops appearing there when it stops.
    ///
    /// Photographed rather than asserted: the island is drawn by another process from a
    /// presentation this test cannot reach through the app's accessibility tree. What can be
    /// checked automatically is that requesting one does not fail — a refusal logs and leaves
    /// the app running — so the screenshot is the evidence and the walk is the regression.
    func testTheRunningTimerReachesTheIsland() throws {
        let app = launch()
        openTime(app)

        app.buttons["time.start"].tap()
        XCTAssertTrue(app.buttons["time.stop"].waitForExistence(timeout: 5))

        let description = app.textFields["time.description"]
        description.tap()
        description.typeText("Reviewing the contract")
        // Tapping the bar rather than a keyboard key: the return key's label is the system's to
        // choose, and a test that types into a field should not also be a test of that choice.
        app.navigationBars["Time"].tap()

        // The island shows a Live Activity while its app is *not* frontmost.
        XCUIDevice.shared.press(.home)
        sleep(3)
        snapScreen("07-island")
    }

    /// The whole display, including the parts no application owns.
    private func snapScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A focus cycle is started from the same card, and says which block is running.
    func testAFocusCycleRunsOverTheTimer() throws {
        let app = launch()
        openTime(app)

        app.buttons["time.start"].tap()
        XCTAssertTrue(app.buttons["time.stop"].waitForExistence(timeout: 5))

        app.buttons["More timer commands"].tap()
        let focus = app.buttons["time.focus"]
        XCTAssertTrue(focus.waitForExistence(timeout: 5), "the menu offers no focus cycle")
        focus.tap()

        XCTAssertTrue(
            app.otherElements["time.focus.strip"].waitForExistence(timeout: 5),
            "starting a cycle drew no strip"
        )
        snap(app, "06-focus")

        app.buttons["time.stop"].tap()
        XCTAssertTrue(app.buttons["time.start"].waitForExistence(timeout: 5))
    }
}
