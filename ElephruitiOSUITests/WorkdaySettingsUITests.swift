import XCTest

/// The working-day section of Settings, photographed and read.
///
/// Separate from ``ScreenshotWalkTests`` because that walk visits eleven screens and takes eleven
/// minutes, which is the wrong tool for looking at one section. This launches, goes straight to
/// Settings, and asserts the section is actually there before photographing it — a screenshot of a
/// screen that failed to draw is a screenshot of nothing.
final class WorkdaySettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testWorkingDaySectionIsPresent() throws {
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

        app.buttons["mobile.sidebar.button"].tap()
        XCTAssertTrue(app.buttons["mobile.sidebar.settings"].waitForExistence(timeout: 10))
        app.buttons["mobile.sidebar.settings"].tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["Working day"].waitForExistence(timeout: 5),
            "the working-day section did not draw"
        )
        XCTAssertTrue(app.staticTexts["Starts"].exists, "no start time to set")
        XCTAssertTrue(app.staticTexts["Ends"].exists, "no end time to set")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "settings-workday"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
