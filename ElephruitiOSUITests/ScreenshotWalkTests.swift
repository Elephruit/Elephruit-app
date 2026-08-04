import XCTest

/// Walks the whole app and photographs every major screen into the result bundle.
///
/// Not an assertion suite — the shell tests assert; this one *looks*. Run it against
/// different devices, appearances, and text sizes to produce the visual QA sets:
///
///     xcodebuild test … -only-testing:ElephruitiOSUITests/ScreenshotWalkTests
///
/// Extract with `xcrun xcresulttool export attachments`. The walk grows with the
/// screens; today it photographs the shell — five tabs, the Library's leaves, and the
/// capture sheet.
final class ScreenshotWalkTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testWalkEveryScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ElephruitDevelopmentMode",
            "-ElephruitUseTemporaryStore",
            "-ElephruitLoadSampleData",
            "-ElephruitUseFixtureCalendar",
            "-ElephruitUseFixtureContacts",
            "-ElephruitUseFixtureReminders",
            "-ElephruitFixturesAuthorized",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        snap(app, "01-today")

        app.tabBars.buttons["Reminders"].tap()
        _ = app.navigationBars["Reminders"].waitForExistence(timeout: 5)
        snap(app, "02-reminders")

        app.tabBars.buttons["Records"].tap()
        _ = app.navigationBars["Records"].waitForExistence(timeout: 5)
        snap(app, "03-records")

        app.tabBars.buttons["Library"].tap()
        _ = app.navigationBars["Library"].waitForExistence(timeout: 5)
        snap(app, "04-library")

        for (index, row) in ["Inbox", "Notes", "Calendar", "Time", "Settings"].enumerated() {
            app.staticTexts[row].tap()
            sleep(1)
            snap(app, String(format: "%02d-%@", index + 5, row.lowercased()))
            app.navigationBars.buttons.firstMatch.tap()
            _ = app.navigationBars["Library"].waitForExistence(timeout: 5)
        }

        app.tabBars.buttons["Search"].tap()
        sleep(1)
        snap(app, "10-search")

        app.tabBars.buttons["Today"].tap()
        _ = app.navigationBars["Today"].waitForExistence(timeout: 5)
        app.buttons["mobile.capture.button"].tap()
        _ = app.navigationBars["Capture"].waitForExistence(timeout: 5)
        snap(app, "11-capture")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
