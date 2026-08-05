import XCTest

/// The Reminders screen's own promises, driven for real.
///
/// The screen makes two claims no other screen in this app makes — that a tap anywhere opens a
/// composer, and that the composer takes a row's place rather than covering the app — and both
/// are claims about behaviour rather than about pixels, so both belong here rather than in the
/// screenshot walk.
final class RemindersUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchOnReminders(sampleData: Bool = true) -> XCUIApplication {
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

        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        app.buttons["mobile.sidebar.button"].tap()
        XCTAssertTrue(app.buttons["mobile.sidebar.reminders"].waitForExistence(timeout: 5))
        app.buttons["mobile.sidebar.reminders"].tap()
        XCTAssertTrue(app.navigationBars["Reminders"].waitForExistence(timeout: 5))
        return app
    }

    /// The composer's title field.
    ///
    /// Matched by identifier across every element type rather than as a text field: a
    /// `TextField` with a vertical axis grows into a multi-line editor, and UIKit reports that
    /// as a text view.
    private func composerTitle(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["reminders.composer.title"]
    }

    /// Starts a new reminder the way the screen intends: from the end of the list.
    private func startNewReminder(_ app: XCUIApplication) {
        let tail = app.buttons["reminders.new"]
        XCTAssertTrue(tail.waitForExistence(timeout: 5))
        // The tail is the last thing in a list that may be taller than the screen.
        if !tail.isHittable {
            app.swipeUp()
            app.swipeUp()
        }
        tail.tap()
    }

    /// The screen's headline claim: writing something down is one tap from reading the list.
    func testStartingANewReminderOpensTheComposer() throws {
        let app = launchOnReminders()

        XCTAssertFalse(composerTitle(app).exists)
        startNewReminder(app)
        XCTAssertTrue(
            composerTitle(app).waitForExistence(timeout: 5),
            "The end of the list should open the composer"
        )
    }

    /// The other half of the same claim: empty space is a target too.
    func testTappingEmptySpaceOpensTheComposer() throws {
        // No sample data, so the screen is empty and every point on it is background.
        let app = launchOnReminders(sampleData: false)

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).tap()
        XCTAssertTrue(
            composerTitle(app).waitForExistence(timeout: 5),
            "A tap on empty space should open the composer"
        )
    }

    /// Cancelling writes nothing — the composer that a stray tap opened has to be free to leave.
    func testCancellingKeepsTheListUnchanged() throws {
        let app = launchOnReminders()

        startNewReminder(app)
        let title = composerTitle(app)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.typeText("Never meant to write this")
        app.buttons["reminders.composer.cancel"].tap()

        XCTAssertFalse(composerTitle(app).exists)
        XCTAssertFalse(app.staticTexts["Never meant to write this"].exists)
    }

    /// The round trip: what is typed is saved, appears in the list, and opens in place.
    ///
    /// One test rather than two. A separate "writing adds it to the list" case asserted the
    /// same save, the same list refresh and the same text — and could not assert the strongest
    /// thing available, which is that reopening the row shows back exactly what was typed.
    /// That equality is the real promise, so the test that can make it owns the whole trip.
    func testWritingAReminderSavesItAndOpensItInPlace() throws {
        let app = launchOnReminders()

        startNewReminder(app)
        let title = composerTitle(app)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.typeText("Return the library books")
        app.buttons["reminders.composer.done"].tap()

        let row = app.staticTexts["Return the library books"]
        XCTAssertTrue(
            row.waitForExistence(timeout: 5),
            "A committed reminder should appear in the list"
        )
        XCTAssertFalse(composerTitle(app).exists, "Done should close the composer")

        row.tap()

        let editor = composerTitle(app)
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Tapping a row should open its editor")
        XCTAssertEqual(
            editor.value as? String,
            "Return the library books",
            "The editor should open on the reminder that was tapped"
        )
        // The navigation bar is still the list's, which is what "inline" means: nothing was
        // pushed and nothing was presented over the screen.
        XCTAssertTrue(app.navigationBars["Reminders"].exists)
    }
}
