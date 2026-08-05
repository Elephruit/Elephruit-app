import XCTest

/// Walks the whole app and photographs every major screen into the result bundle.
///
/// Not an assertion suite — the shell tests assert; this one *looks*. Run it against
/// different devices, appearances, and text sizes to produce the visual QA sets:
///
///     xcodebuild test … -only-testing:ElephruitiOSUITests/ScreenshotWalkTests
///
/// Extract with `xcrun xcresulttool export attachments`.
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

        // The drawer itself is a screen worth photographing: it is now the app's table of
        // contents, and a regression in it is a regression in every route.
        openSidebar(app)
        snap(app, "02-sidebar")

        let walk = [
            "projects", "calendar", "reminders", "records", "notes", "time",
            "areas", "bookmarks", "inbox", "archive", "trash", "search", "settings",
        ]

        for (index, destination) in walk.enumerated() {
            openSidebar(app)
            app.buttons["mobile.sidebar.\(destination)"].tap()
            sleep(1)
            snap(app, String(format: "%02d-%@", index + 3, destination))
        }

        openSidebar(app)
        app.buttons["mobile.sidebar.today"].tap()
        _ = app.navigationBars["Today"].waitForExistence(timeout: 5)
        app.buttons["mobile.capture.button"].tap()
        _ = app.navigationBars["Capture"].waitForExistence(timeout: 5)
        snap(app, "15-capture")
    }

    /// Opens the drawer if it is not already showing.
    ///
    /// The check matters: while the drawer is open the scrim covers where the chevron sits on
    /// screen, so a second tap would close it instead of leaving it open.
    private func openSidebar(_ app: XCUIApplication) {
        guard !app.buttons["mobile.sidebar.today"].exists else { return }
        app.buttons["mobile.sidebar.button"].tap()
        _ = app.buttons["mobile.sidebar.today"].waitForExistence(timeout: 5)
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
