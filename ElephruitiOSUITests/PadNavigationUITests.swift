import UIKit
import XCTest

/// The iPad shell, driven for real: the resident sidebar, the stage it puts things on, and the
/// promises the arrangement makes.
///
/// The claims worth a test are the ones a screenshot cannot make: that the sidebar survives
/// entering a project, that a module's front door is not drawn twice, that a list root opens the
/// record beside the list once the window is wide enough for one, and that rotating a window
/// through both arrangements keeps the journey rather than resetting it.
///
/// Every test launches against a throwaway store and fixture providers, so nothing here can touch
/// a person's calendar, contacts, or reminders. On an iPhone the whole suite is skipped: there is
/// no regular width to test, and a skipped test says that more honestly than one that passes by
/// finding nothing.
final class PadNavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "The iPad shell only exists at regular width."
        )
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func launch(root: String? = nil, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ElephruitDevelopmentMode",
            "-ElephruitUseTemporaryStore",
            "-ElephruitUseFixtureCalendar",
            "-ElephruitUseFixtureContacts",
            "-ElephruitUseFixtureReminders",
            "-ElephruitFixturesAuthorized",
            "-ElephruitLoadSampleData",
        ]
        if let root {
            app.launchArguments += ["-ElephruitPadRoot", root]
        }
        app.launchArguments += extra
        app.launch()
        return app
    }

    /// The sidebar's own scroll container, whichever element the platform put the identifier on.
    private func sidebar(_ app: XCUIApplication) -> XCUIElement {
        let byIdentifier = app.collectionViews["pad.sidebar"]
        if byIdentifier.exists { return byIdentifier }
        let scroller = app.scrollViews["pad.sidebar"]
        if scroller.exists { return scroller }
        // The leading column is the first collection view in the window.
        return app.collectionViews.element(boundBy: 0)
    }

    /// A sidebar row, scrolled to where it can actually be tapped.
    ///
    /// The column holds every place the app has, and a `List` builds its rows lazily — so on a
    /// short window the Archive is not merely off screen, it does not exist yet. Asserting on
    /// `exists` alone would make these tests a measurement of the simulator's height rather than
    /// of the sidebar.
    ///
    /// The walk always restarts from the top, in one direction. Searching from wherever the last
    /// assertion left the column means a row above the current scroll position is unreachable —
    /// which is how the first version of this helper concluded that tapping the Archive had
    /// deleted Today.
    private func sidebarRow(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let row = app.buttons[identifier]
        if row.exists, row.isHittable { return row }

        let top = app.buttons["pad.sidebar.today"]
        var rewinds = 0
        while !(top.exists && top.isHittable) && rewinds < 10 {
            sidebar(app).swipeDown()
            rewinds += 1
        }

        var descents = 0
        while !(row.exists && row.isHittable) && descents < 10 {
            sidebar(app).swipeUp()
            descents += 1
        }
        return row
    }

    // MARK: - The sidebar

    /// Every band's front door is reachable, and reaching one does not cost you the others.
    func testSidebarReachesEveryPlaceAndStays() {
        let app = launch()

        XCTAssertTrue(
            app.buttons["pad.sidebar.today"].waitForExistence(timeout: 15),
            "The sidebar should be resident at regular width without anybody asking for it."
        )

        let places = [
            "pad.sidebar.inbox",
            "pad.sidebar.kind.note",
            "pad.sidebar.reminders",
            "pad.sidebar.calendar",
            "pad.sidebar.records.all",
            "pad.sidebar.time",
            "pad.sidebar.kind.bookmark",
            "pad.sidebar.archive",
            "pad.sidebar.trash",
            "pad.sidebar.settings",
        ]

        for place in places {
            let row = sidebarRow(place, in: app)
            XCTAssertTrue(row.exists, "\(place) should be reachable in the sidebar.")
            row.tap()
            XCTAssertTrue(
                sidebarRow("pad.sidebar.today", in: app).exists,
                "Selecting \(place) must not replace the sidebar — Today should still be one tap away."
            )
        }
    }

    /// A module's front door is a row, not two rows. The Library names Notes; the context band
    /// below it names the kinds that are *not* Notes.
    func testContextBandDoesNotRepeatTheFrontDoor() {
        let app = launch(root: "notes")

        XCTAssertTrue(app.buttons["pad.sidebar.today"].waitForExistence(timeout: 15))
        XCTAssertTrue(sidebarRow("pad.sidebar.kind.idea", in: app).exists)
        XCTAssertTrue(sidebarRow("pad.sidebar.kind.reference", in: app).exists)
        XCTAssertEqual(
            app.buttons.matching(identifier: "pad.sidebar.kind.note").count, 1,
            "Notes should appear once — in the Library — not again as its own sub-destination."
        )
    }

    /// Reminders brings its smart lists; Records brings its scopes. Neither is a column swap.
    func testSelectedModuleBringsItsOwnSources() {
        let app = launch(root: "reminders")

        XCTAssertTrue(app.buttons["pad.sidebar.today"].waitForExistence(timeout: 15))
        XCTAssertTrue(sidebarRow("pad.sidebar.smartList.overdue", in: app).exists)
        XCTAssertTrue(
            sidebarRow("pad.sidebar.today", in: app).exists,
            "A module's sources appear below the Library, never instead of it."
        )

        sidebarRow("pad.sidebar.records.all", in: app).tap()
        XCTAssertTrue(sidebarRow("pad.sidebar.records.people", in: app).exists)
        XCTAssertFalse(
            app.buttons["pad.sidebar.smartList.overdue"].exists,
            "Leaving Reminders should take its smart lists with it."
        )
    }

    // MARK: - The stage

    /// A project is a workspace with its own views — and the sidebar's project tree is still there
    /// to switch projects with, which is the whole reason the sidebar does not swap.
    func testProjectOpensTheWorkspaceWithoutLosingTheTree() {
        let app = launch(root: "firstProject")

        XCTAssertTrue(app.buttons["pad.project.view.board"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["pad.project.view.table"].exists)
        XCTAssertTrue(
            sidebarRow("pad.sidebar.today", in: app).exists,
            "Entering a project must not swap the sidebar for the project's own navigation."
        )
    }

    /// A list root wide enough for three columns opens the record beside the list rather than over
    /// it — the list stays on screen and stays usable.
    func testWideListRootOpensTheRecordBesideTheList() {
        let app = launch(root: "notes", extra: ["-ElephruitPadSelectFirst"])

        XCTAssertTrue(app.navigationBars["Notes"].waitForExistence(timeout: 15))
        XCTAssertTrue(
            app.staticTexts["Studio pricing conversation"].waitForExistence(timeout: 5),
            "The selected record should be showing in the reading pane."
        )
        XCTAssertTrue(
            app.navigationBars["Notes"].exists,
            "Opening a record beside the list must not take the list away."
        )
    }

    /// The pane is not asserted, it is afforded: held upright there is no room for one, and the
    /// list takes the stage instead of being pushed off it.
    func testPortraitKeepsTheListRatherThanTheReadingPane() {
        let app = launch(root: "notes", extra: ["-ElephruitPadSelectFirst"])
        XCTAssertTrue(app.navigationBars["Notes"].waitForExistence(timeout: 15))

        XCUIDevice.shared.orientation = .portrait

        XCTAssertTrue(
            app.navigationBars["Notes"].waitForExistence(timeout: 10),
            "Rotating upright should leave the list on screen, not a pane where a list was."
        )
        XCTAssertTrue(sidebarRow("pad.sidebar.today", in: app).exists)
    }

    // MARK: - Capture

    /// The capture button is on every arrangement, and is never a dead tap.
    func testCaptureOpensFromTheStage() {
        let app = launch()
        XCTAssertTrue(app.buttons["mobile.capture.button"].waitForExistence(timeout: 15))
        app.buttons["mobile.capture.button"].tap()
        XCTAssertTrue(
            app.textViews.firstMatch.waitForExistence(timeout: 5)
                || app.textFields.firstMatch.waitForExistence(timeout: 5),
            "Quick capture should arrive with somewhere to type."
        )
    }
}
