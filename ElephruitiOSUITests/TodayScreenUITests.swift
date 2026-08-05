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

        let awareness = app.staticTexts["Awareness"]
        let schedule = app.staticTexts["Schedule"]
        XCTAssertTrue(awareness.waitForExistence(timeout: 10), "the awareness band did not draw")
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
}
