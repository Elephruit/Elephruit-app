import UIKit
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
        // The drawer shell only exists at compact width. Skipping says that out loud; running
        // on an iPad and finding no `mobile.sidebar.button` would report the shell as broken when
        // what is actually true is that this device draws the other one. The iPad's own suite is
        // `PadNavigationUITests`, which skips on iPhone for the mirror-image reason.
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone,
            "The drawer shell only exists on iPhone."
        )
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

    /// Gets to the Time screen from wherever the app came back to.
    ///
    /// Which screen that is is deliberately not asserted. The shell restores the destination
    /// that was last open, and the store these tests launch against is temporary — so the entries
    /// do not survive a relaunch but the choice of screen does, and a test that runs after one
    /// that ended on Time arrives on Time. Waiting for "Today" made every test in this class
    /// depend on the order it ran in, which is a dependency none of them mean to have. What is
    /// worth waiting for is the shell itself; the rest is travel, and travel that has already
    /// happened is travel that can be skipped.
    private func openTime(_ app: XCUIApplication) {
        XCTAssertTrue(
            app.buttons["mobile.sidebar.button"].waitForExistence(timeout: 15),
            "the app never finished launching into its shell"
        )
        guard !app.navigationBars["Time"].exists else { return }

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

    /// The clock follows you off the Time screen, and it carries its controls with it.
    ///
    /// This is the promise the old bottom strip could not keep. It showed a running timer from
    /// anywhere and could only stop it, so pausing one — or checking what it was filed against —
    /// meant walking back to the Time screen and losing whatever you were doing. The pill answers
    /// both without leaving the page: it is small until asked, and asked, it grows.
    func testTheClockFollowsYouAndOpensInPlace() throws {
        let app = launch()
        openTime(app)

        app.buttons["time.start"].tap()
        XCTAssertTrue(app.buttons["time.stop"].waitForExistence(timeout: 5))

        // Away from Time, where the screen's own tracker card is not there to do this job.
        app.buttons["mobile.sidebar.button"].tap()
        app.buttons["mobile.sidebar.today"].tap()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 5))

        let pill = app.otherElements["time.pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "A running timer should float over Today")
        XCTAssertFalse(
            app.buttons["time.pill.stop"].exists,
            "At rest the pill is a readout, not a row of controls"
        )
        snap(app, "08-pill-resting")

        pill.tap()
        XCTAssertTrue(
            app.buttons["time.pill.stop"].waitForExistence(timeout: 5),
            "Tapping the pill should grow it into its controls"
        )
        XCTAssertTrue(app.buttons["time.pill.pause"].exists, "and offer a pause")
        XCTAssertTrue(
            app.navigationBars["Today"].exists,
            "and do it in place, without leaving the page"
        )
        snap(app, "09-pill-open")

        // Paused rather than stopped: the pill has to survive a pause, because a paused timer is
        // the one that is easiest to forget and the pill is the only thing still saying it exists.
        // And the card stays open around it — pause and resume are one decision seen twice, so
        // the way back must not cost a second tap to get the controls back.
        app.buttons["time.pill.pause"].tap()
        XCTAssertTrue(
            app.buttons["time.pill.resume"].waitForExistence(timeout: 5),
            "Pausing should leave the card open, with Resume where Pause was"
        )

        let stop = app.buttons["time.pill.stop"]
        XCTAssertTrue(stop.exists)
        stop.tap()
        XCTAssertTrue(
            app.otherElements["time.pill"].waitForNonExistence(timeout: 5),
            "Stopping should take the clock off the screen entirely"
        )
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
        // A chip is tapped with the description still under the cursor, so the keyboard has to
        // leave before the popup can be anchored to a control it was about to move. Asserted
        // rather than assumed: presenting over a live keyboard is how this chip used to open
        // nothing at all, and the symptom was a tap that visibly did nothing.
        XCTAssertTrue(
            app.keyboards.element.waitForNonExistence(timeout: 5),
            "opening a filing chip should have put the keyboard away"
        )
        // The popup carries its name as a label rather than a heading — the header was taken out
        // deliberately, because a popup anchored to the control that opened it spends its first
        // row saying what you just tapped. The name is still there for the reading that needs it,
        // which is this one.
        XCTAssertTrue(
            app.otherElements["Subject"].waitForExistence(timeout: 5),
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
