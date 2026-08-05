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

        let gaps = app.descendants(matching: .any).matching(identifier: "today.freeSlot")
        XCTAssertGreaterThan(
            gaps.count, 0, "no gap was drawn on a day the fixture leaves room in"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "today-free-time"
        attachment.lifetime = .keepAlways
        add(attachment)

        toggle.tap()
        XCTAssertTrue(
            gaps.firstMatch.waitForNonExistence(timeout: 5),
            "the switch did not hide the gaps"
        )
    }
}
