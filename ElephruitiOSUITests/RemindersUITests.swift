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

    /// Closes the editor, once it has stopped moving.
    ///
    /// Opening an editor scrolls it into view, and a tap dispatched while the card is still
    /// travelling lands where the control used to be — which does nothing, and looks exactly
    /// like a dismiss control that does not work. Existence is not enough here; hittability is
    /// the thing being waited for.
    private func tapDismiss(_ app: XCUIApplication) {
        let dismiss = app.buttons["reminders.composer.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))

        let deadline = Date().addingTimeInterval(5)
        while !dismiss.isHittable && Date() < deadline {
            usleep(100_000)
        }
        dismiss.tap()
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

    /// The × closes and keeps. There is no discard on this screen.
    ///
    /// Every exit saves — this control, Return, tapping another reminder, tapping the
    /// background — so the editor never asks whether you meant the words you just typed.
    func testDismissingKeepsWhatWasTyped() throws {
        let app = launchOnReminders()

        startNewReminder(app)
        let title = composerTitle(app)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.typeText("Take the cat to the vet")
        tapDismiss(app)

        // The composer has to be gone before the list can be asked what is in it: while the
        // card animates out its own title field still holds the words, and a search would find
        // them there rather than in the list.
        XCTAssertTrue(
            composerTitle(app).waitForNonExistence(timeout: 10),
            "The dismiss control should close the composer"
        )
        XCTAssertTrue(
            app.staticTexts["Take the cat to the vet"].firstMatch.waitForExistence(timeout: 5),
            "Dismissing should have saved the reminder"
        )
    }

    /// The editor moves to whichever reminder you tap, with nothing to dismiss first.
    ///
    /// The behaviour a list of rows implies: rows are things you point at, and an open editor
    /// that refuses the next tap makes the list stop responding for a reason invisible while it
    /// is happening. What was typed in the first one is kept, not dropped.
    func testTappingAnotherReminderMovesTheEditor() throws {
        let app = launchOnReminders()

        for title in ["Alpha one reminder", "Beta two reminder"] {
            startNewReminder(app)
            let field = composerTitle(app)
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.typeText(title)
            tapDismiss(app)
            XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 5))
        }

        app.staticTexts["Alpha one reminder"].firstMatch.tap()
        XCTAssertTrue(composerTitle(app).waitForExistence(timeout: 5))
        XCTAssertEqual(composerTitle(app).value as? String, "Alpha one reminder")

        // The second tap goes straight through, with nothing dismissed first.
        app.staticTexts["Beta two reminder"].firstMatch.tap()
        XCTAssertEqual(
            composerTitle(app).value as? String,
            "Beta two reminder",
            "Tapping another reminder should move the editor to it"
        )
        XCTAssertTrue(
            app.staticTexts["Alpha one reminder"].firstMatch.waitForExistence(timeout: 5),
            "The reminder the editor left should still be in the list"
        )
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
        tapDismiss(app)

        // `.firstMatch`: a row is an accessibility container, so its title matches both the
        // element that holds it and the text inside it.
        let row = app.staticTexts["Return the library books"].firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 5),
            "A committed reminder should appear in the list"
        )
        // Waiting rather than asking once: the composer animates out, and `.exists` sampled on
        // the frame after the tap is asking whether the animation has finished, not whether the
        // editor closed.
        XCTAssertTrue(
            composerTitle(app).waitForNonExistence(timeout: 5),
            "Dismissing should close the composer"
        )

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

    /// A reminder asked for from the shell's fan is composed *here*, in the list, not filed into
    /// the Inbox — and the card opens at the top, where it can be read and typed into.
    ///
    /// The fan can ask for a reminder from any screen in the app, and on every other screen that
    /// means travelling to Reminders first. On Reminders it must not: a plus held over a list of
    /// reminders that answers somewhere else is a plus answering a question nobody asked. And the
    /// button is not a place in the list — it floats over the bottom-right corner, so answering
    /// at the *end* of the list would put a card you are about to type into behind the keyboard,
    /// under the button that opened it.
    func testTheShellButtonWritesAReminderAtTheTop() throws {
        let app = launchOnReminders()

        // By coordinate: this screen's background is itself a "new reminder" tap target, and it
        // is what a plain `tap()` on the plus lands on. `FloatingControlTaps` has the detail.
        app.buttons["mobile.capture.button"].tapCenter()
        let reminder = app.buttons["mobile.add.reminder"]
        XCTAssertTrue(reminder.waitForExistence(timeout: 5), "The plus should fan out")
        reminder.tapCenter()

        let title = composerTitle(app)
        XCTAssertTrue(
            title.waitForExistence(timeout: 5),
            "The shell's button should open this screen's composer"
        )
        XCTAssertTrue(
            app.navigationBars["Reminders"].exists,
            "It should compose in place rather than presenting the capture sheet"
        )
        XCTAssertLessThan(
            title.frame.midY,
            app.frame.height / 2,
            "The card should arrive in the top half of the screen, clear of the keyboard"
        )
    }

    /// A picker is chosen from by tapping, so the keyboard goes before the picker arrives.
    ///
    /// Five of the six controls used to present their popover directly, over a keyboard that was
    /// still up and anchored to a control the keyboard was about to move. What that looks like
    /// in the hand is a tap that freezes the screen for a second and a keyboard that will not go
    /// away, which is exactly how it was reported.
    func testOpeningAPickerPutsTheKeyboardAway() throws {
        let app = launchOnReminders()

        startNewReminder(app)
        let title = composerTitle(app)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.typeText("Book the dentist")
        XCTAssertTrue(
            app.keyboards.element.waitForExistence(timeout: 5),
            "Typing should have raised the keyboard"
        )

        let deadline = app.buttons["reminders.composer.deadline"]
        deadline.tap()

        XCTAssertTrue(
            app.keyboards.element.waitForNonExistence(timeout: 5),
            "Opening a picker should put the keyboard away"
        )
        let nextWeek = app.buttons["Next week"]
        XCTAssertTrue(
            nextWeek.waitForExistence(timeout: 5),
            "The picker should be showing once the keyboard has gone"
        )
        // The popup opens at full size rather than squeezed against an edge — the card scrolls
        // up to make the room, and the popup takes the direction that has it.
        XCTAssertGreaterThan(
            nextWeek.frame.height,
            0,
            "The picker's rows should have room to be themselves"
        )
        XCTAssertTrue(
            app.buttons["Today"].exists && app.buttons["Tomorrow"].exists,
            "All of the picker's quick answers should fit on screen"
        )
    }
}
