import XCTest

/// The iPhone shell, driven for real: the drawer, the routes, capture, and the promises the
/// navigation makes. Every test launches against a throwaway store and fixture providers, so
/// nothing here can touch a person's calendar, contacts, or reminders.
///
/// The suite grows with the screens: today it asserts the shell's own contract — every
/// destination reachable from the drawer, per-destination stacks surviving a step away, back
/// meaning one thing at every depth, and the capture button never a dead tap.
final class MobileShellUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(sampleData: Bool = true) -> XCUIApplication {
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
        return app
    }

    /// Opens the drawer from wherever the app currently is, and answers whether it is showing.
    ///
    /// Idempotent on purpose. While the drawer is open the scrim covers the chevron's screen
    /// position, so a blind second tap would close the drawer rather than confirm it — the
    /// check comes first.
    @discardableResult
    private func openSidebar(_ app: XCUIApplication) -> Bool {
        if app.buttons["mobile.sidebar.today"].exists { return true }
        app.buttons["mobile.sidebar.button"].tap()
        return app.buttons["mobile.sidebar.today"].waitForExistence(timeout: 5)
    }

    private func step(_ app: XCUIApplication, to destination: String) {
        openSidebar(app)
        app.buttons["mobile.sidebar.\(destination)"].tap()
    }

    // MARK: - The drawer

    /// Every destination the drawer lists is reachable, and each shows its own root.
    ///
    /// The whole list, not a sample: the drawer's argument for replacing the tab bar is that it
    /// can hold every place at its real name, and a test that walked four of them would be
    /// asserting the tab bar's contract on the drawer's shell.
    func testEveryDestinationIsReachable() throws {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))

        let destinations = [
            ("calendar", "Calendar"),
            ("reminders", "Reminders"),
            ("records", "Records"),
            ("notes", "Notes"),
            ("time", "Time"),
            ("areas", "Areas"),
            ("bookmarks", "Bookmarks"),
            ("inbox", "Inbox"),
            ("archive", "Archive"),
            ("trash", "Trash"),
            ("settings", "Settings"),
            ("today", "Today"),
        ]

        for (identifier, title) in destinations {
            step(app, to: identifier)
            XCTAssertTrue(
                app.navigationBars[title].waitForExistence(timeout: 5),
                "Choosing \(identifier) should land on the \(title) screen"
            )
        }
    }

    /// Back means one thing at every depth: out of the stack, then into the drawer.
    func testBackWalksAllTheWayToTheSidebar() throws {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))

        step(app, to: "inbox")
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 5))

        // At a root there is no stack left to pop, so the same chevron reveals the drawer
        // rather than doing nothing.
        app.buttons["mobile.sidebar.button"].tap()
        XCTAssertTrue(
            app.buttons["mobile.sidebar.today"].waitForExistence(timeout: 5),
            "Back from a root should reveal the sidebar"
        )
    }

    /// A drill-down survives stepping away: per-destination stacks are the shell's core promise.
    func testDrillDownSurvivesSteppingAway() throws {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))

        step(app, to: "notes")
        XCTAssertTrue(app.navigationBars["Notes"].waitForExistence(timeout: 5))

        let firstNote = app.collectionViews.cells.firstMatch
        XCTAssertTrue(firstNote.waitForExistence(timeout: 5))
        firstNote.tap()
        let pushedTitle = app.navigationBars.element(boundBy: 0).identifier

        step(app, to: "today")
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 5))

        step(app, to: "notes")
        XCTAssertTrue(
            app.navigationBars[pushedTitle].waitForExistence(timeout: 5),
            "Returning to Notes should find the pushed note still open"
        )
    }

    /// Choosing the destination you are already on pops it to its root — the way out of a deep
    /// stack that does not require walking back up it.
    func testReselectingADestinationPopsToRoot() throws {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))

        step(app, to: "notes")
        let firstNote = app.collectionViews.cells.firstMatch
        XCTAssertTrue(firstNote.waitForExistence(timeout: 5))
        firstNote.tap()

        step(app, to: "notes")
        XCTAssertTrue(
            app.navigationBars["Notes"].waitForExistence(timeout: 5),
            "Re-choosing Notes should return to the list"
        )
    }

    // MARK: - Capture

    /// The capture button is never a dead tap, and a cancelled sheet goes away.
    func testCaptureSheetOpensAndDismisses() throws {
        let app = launch()

        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        app.buttons["mobile.capture.button"].tap()
        XCTAssertTrue(app.navigationBars["Capture"].waitForExistence(timeout: 5))

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 5))
    }
}
