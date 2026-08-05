import XCTest

/// Today, photographed and read, against the fixture calendar.
///
/// Separate from ``ScreenshotWalkTests`` for the reason ``WorkdaySettingsUITests`` is: the walk
/// visits eleven screens and takes eleven minutes, which is the wrong tool for looking at one.
///
/// The fixture calendar is what makes the assertions mean anything — it carries a four-day trip, a
/// day marked away, an all-day birthday, a morning where three things clash, a defended block, and
/// a cancelled meeting still showing. A screenshot of an empty day proves nothing.
final class TodayScreenUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAwarenessSitsAboveTheSchedule() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ElephruitDevelopmentMode",
            "-ElephruitUseTemporaryStore",
            "-ElephruitLoadSampleData",
            "-ElephruitUseFixtureCalendar",
            "-ElephruitFixturesAuthorized",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 20))

        let awareness = app.staticTexts["today.awareness.header"]
        let schedule = app.staticTexts["today.schedule.header"]
        XCTAssertTrue(awareness.waitForExistence(timeout: 30), "the awareness band did not draw")
        XCTAssertTrue(schedule.exists, "the schedule did not draw")
        XCTAssertLessThan(
            awareness.frame.minY, schedule.frame.minY,
            "what the day is has to be readable before what is in it"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "today-awareness"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The far end of the thread: people, and the day's note closing it off.
    ///
    /// Scrolled to rather than waited for. A SwiftUI `List` only realises cells near the viewport,
    /// so anything below the fold is absent from the accessibility tree entirely and no timeout
    /// will conjure it.
    func testThreadRunsThroughToTheDaysNote() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ElephruitDevelopmentMode",
            "-ElephruitUseTemporaryStore",
            "-ElephruitLoadSampleData",
            "-ElephruitUseFixtureCalendar",
            "-ElephruitFixturesAuthorized",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 30))

        let note = app.staticTexts["Write about this day"]
        for _ in 0..<12 where !note.exists {
            app.swipeUp()
        }

        XCTAssertTrue(note.exists, "the thread never reached the day's note")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "today-thread-end"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// People in one meeting are one row, and opening it names them.
    ///
    /// The fixture puts three people in Roadmap sync, which used to be three rows each repeating
    /// the same time and title.
    func testAMeetingsPeopleAreOneRowUntilOpened() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ElephruitDevelopmentMode",
            "-ElephruitUseTemporaryStore",
            "-ElephruitLoadSampleData",
            "-ElephruitUseFixtureCalendar",
            "-ElephruitFixturesAuthorized",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 30))

        let gatherings = app.descendants(matching: .any).matching(identifier: "today.gathering")
        for _ in 0..<12 where gatherings.count == 0 {
            app.swipeUp()
        }
        XCTAssertGreaterThan(gatherings.count, 0, "no meeting gathered its people")

        let closed = XCTAttachment(screenshot: app.screenshot())
        closed.name = "today-people-gathered"
        closed.lifetime = .keepAlways
        add(closed)

        // Counted by identifier rather than by looking for a particular name: which meeting is
        // first depends on the fixture's clock, and the first version of this tapped the ten
        // o'clock and then asserted on somebody who is in the four o'clock.
        let named = app.descendants(matching: .any).matching(identifier: "today.gathering.person")
        XCTAssertEqual(named.count, 0, "the people are named before the meeting was opened")

        gatherings.firstMatch.tap()
        XCTAssertTrue(
            named.firstMatch.waitForExistence(timeout: 5),
            "opening the meeting did not name its people"
        )

        let opened = XCTAttachment(screenshot: app.screenshot())
        opened.name = "today-people-expanded"
        opened.lifetime = .keepAlways
        add(opened)
    }

    /// The gaps are rows, and the switch that hides them actually hides them.
    ///
    /// Asserted rather than only photographed, because "free" appearing on screen is not proof the
    /// gaps drew — the briefing says "free" too, at the top, and always has.
    ///
    /// Counted by identifier rather than by matching text. The first version of this scanned every
    /// static text for "free" and was killed on a six-hundred-second timeout: a `CONTAINS` predicate
    /// re-snapshots the whole hierarchy of a long list on each evaluation, and it would have matched
    /// the briefing line anyway.
    func testFreeTimeCanBeShownAndHidden() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ElephruitDevelopmentMode",
            "-ElephruitUseTemporaryStore",
            "-ElephruitLoadSampleData",
            "-ElephruitUseFixtureCalendar",
            "-ElephruitFixturesAuthorized",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["today.schedule.header"].waitForExistence(timeout: 30))

        let toggle = app.buttons["today.freeTime.toggle"]
        XCTAssertTrue(toggle.exists, "the schedule has no control over its own free time")
        XCTAssertEqual(
            toggle.label, "Hide free time",
            "free time is meant to start shown — the room left in a day is the answer this page exists to give"
        )

        // Scrolled to. Which gaps a day has depends on the hour the suite runs at — late in the
        // afternoon the first one is well below the schedule's first screenful — and a `List` does
        // not realise cells it has not reached. This passed for weeks by being run before lunch.
        let gaps = app.descendants(matching: .any).matching(identifier: "today.freeSlot")
        for _ in 0..<6 where gaps.count == 0 {
            app.swipeUp()
        }
        XCTAssertGreaterThan(
            gaps.count, 0, "no gap was drawn on a day the fixture leaves room in"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "today-free-time"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Back up to the header, which holds the switch.
        for _ in 0..<6 where !toggle.isHittable {
            app.swipeDown()
        }
        toggle.tap()
        XCTAssertTrue(
            gaps.firstMatch.waitForNonExistence(timeout: 5),
            "the switch did not hide the gaps"
        )
    }

    /// The third offer: a reminder for a moment inside the gap, and nothing on the calendar.
    ///
    /// Worth its own method because it is the one offer that must *not* write an event. "Nudge me
    /// at two" is not an appointment, and an app that quietly turns one into the other is an app
    /// whose calendar fills up with things nobody agreed to put there.
    func testAGapCanBecomeAReminderInstead() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ElephruitDevelopmentMode",
            "-ElephruitUseTemporaryStore",
            "-ElephruitLoadSampleData",
            "-ElephruitUseFixtureCalendar",
            "-ElephruitFixturesAuthorized",
            "-ElephruitTodayBlockSheet", "gap",
        ]
        app.launch()

        let reminder = app.buttons["today.block.reminder"]
        XCTAssertTrue(reminder.waitForExistence(timeout: 30), "the gap never offered a reminder")
        reminder.tap()

        let field = app.textFields["today.block.reminder.title"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "there was nowhere to say what to be reminded of")
        field.tap()
        field.typeText("Ring the vet")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "today-block-reminder"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.buttons["today.block.add"].tap()

        // On the page, in the work — not in the schedule, where an appointment would be. Scrolled
        // to rather than waited for: the work sits below a screenful of schedule, and a `List` does
        // not realise cells it has not reached, so no timeout conjures one.
        let written = app.staticTexts["Ring the vet"]
        for _ in 0..<10 where !written.exists {
            app.swipeUp()
        }
        XCTAssertTrue(written.exists, "the reminder was never written")
    }

    /// The same sheet, reached from the work rather than from the room.
    ///
    /// Swipe actions are exactly the class of affordance that silently fails to appear — the row
    /// draws, the gesture does nothing, and nobody notices until it ships. The task is found by its
    /// title, which is content and is the test doing its job; everything after the swipe is chrome
    /// and is found by identifier.
    func testWorkCanClaimTimeFromItsOwnRow() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ElephruitDevelopmentMode",
            "-ElephruitUseTemporaryStore",
            "-ElephruitLoadSampleData",
            "-ElephruitUseFixtureCalendar",
            "-ElephruitFixturesAuthorized",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 20))

        let task = app.staticTexts["Draft the announcement post"]
        for _ in 0..<10 where !task.exists {
            app.swipeUp()
        }
        XCTAssertTrue(task.exists, "the sample day never showed the work this test swipes")

        task.swipeLeft()

        // Photographed as well as asserted: a third trailing action is where a row runs out of
        // width, and a truncated label is not something an assertion notices.
        let revealed = XCTAttachment(screenshot: app.screenshot())
        revealed.name = "today-task-swipe-actions"
        revealed.lifetime = .keepAlways
        add(revealed)

        let block = app.buttons["Block Time"]
        XCTAssertTrue(block.waitForExistence(timeout: 5), "a to-do cannot ask for time of its own")
        block.tap()

        XCTAssertTrue(
            app.buttons["today.block.add"].waitForExistence(timeout: 10),
            "the swipe action opened nothing"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "today-block-for-work"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A gap can be claimed, and the claim can be taken straight back.
    ///
    /// The whole loop in one method because each one relaunches the app: tapping the gap, what it
    /// offers, the write, the receipt, and the undo. Undo is asserted rather than assumed — a button
    /// that writes to somebody's calendar and cannot be reversed in the same breath is the fastest
    /// way to make them stop trusting it.
    ///
    /// Everything is reached by identifier, because all of it is chrome. The one thing matched by
    /// its words is the work in the offer list, which is content and is the test doing its job.
    func testAGapCanBeClaimedAndGivenBack() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ElephruitDevelopmentMode",
            "-ElephruitUseTemporaryStore",
            "-ElephruitLoadSampleData",
            "-ElephruitUseFixtureCalendar",
            "-ElephruitFixturesAuthorized",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["today.schedule.header"].waitForExistence(timeout: 30))

        let gaps = app.descendants(matching: .any).matching(identifier: "today.freeSlot")
        for _ in 0..<8 where gaps.count == 0 {
            app.swipeUp()
        }
        XCTAssertGreaterThan(gaps.count, 0, "no gap was drawn on a day the fixture leaves room in")

        gaps.firstMatch.tap()

        let addButton = app.buttons["today.block.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10), "tapping a gap offered nothing to do with it")
        XCTAssertTrue(
            app.buttons["today.block.focus"].exists,
            "a gap must at least offer to be defended, whatever else is on the day"
        )

        let offered = XCTAttachment(screenshot: app.screenshot())
        offered.name = "today-block-offers"
        offered.lifetime = .keepAlways
        add(offered)

        addButton.tap()

        let remove = app.buttons["today.block.remove"]
        XCTAssertTrue(
            remove.waitForExistence(timeout: 15),
            "the write said nothing about itself, so there is nothing to undo"
        )

        let written = XCTAttachment(screenshot: app.screenshot())
        written.name = "today-block-written"
        written.lifetime = .keepAlways
        add(written)

        remove.tap()
        XCTAssertTrue(
            remove.waitForNonExistence(timeout: 15),
            "removing the block left the sheet up, so nobody can tell whether it worked"
        )
    }
}
