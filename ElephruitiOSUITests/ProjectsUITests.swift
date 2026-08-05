import XCTest

/// Projects on the phone, driven for real.
///
/// The suite exists because projects were reachable on the Mac and absent here, and the way that
/// happens again is quietly: a screen that lists nothing, a create that goes nowhere, a brief that
/// renders as hash marks, work that is filed under a heading and therefore invisible. Each of
/// those is a test below.
///
/// Every launch is against a throwaway store with the fixture providers, so nothing here can touch
/// a person's calendar, contacts, or reminders.
final class ProjectsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
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
        return app
    }

    /// Opens Projects from wherever the app is.
    private func openProjects(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        if !app.buttons["mobile.sidebar.today"].exists {
            app.buttons["mobile.sidebar.button"].tap()
            _ = app.buttons["mobile.sidebar.today"].waitForExistence(timeout: 5)
        }
        app.buttons["mobile.sidebar.projects"].tap()
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 5))
    }

    /// A row's label, not its identifier: the rows carry their item's identifier, which a test
    /// running against freshly-seeded sample data has no way to know in advance.
    private func element(_ app: XCUIApplication, labelled text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
    }

    /// Scrolls until something is on screen, and answers whether it ever was.
    ///
    /// A `List` builds its rows lazily, so a row below the fold does not merely fail to be hit —
    /// it does not exist to query at all. Asserting on `exists` without scrolling first would make
    /// this suite a test of screen height.
    @discardableResult
    private func reveal(_ app: XCUIApplication, labelled text: String) -> Bool {
        let target = element(app, labelled: text)
        if target.waitForExistence(timeout: 5) { return true }
        for _ in 0..<8 {
            app.swipeUp()
            if target.exists { return true }
        }
        return false
    }

    // MARK: - The list

    /// The tree lists what the library holds, areas and the projects inside them alike.
    func testTheProjectsScreenListsTheTree() throws {
        let app = launch()
        openProjects(app)

        for name in ["Work", "Q3 Product Launch", "Database migration", "House move"] {
            XCTAssertTrue(reveal(app, labelled: name), "Projects should list \(name)")
        }
    }

    /// Opening a project shows its brief as prose, and its work — including the work filed under
    /// a heading, which is the case that used to disappear.
    ///
    /// The brief assertion is about *rendering*: the stored text begins `# Brief`, and what should
    /// arrive on screen is the sentence under that heading rather than the hash mark in front of
    /// it. The heading itself is deliberately suppressed — the section is already called Brief.
    func testAProjectShowsItsBriefAndTheWorkUnderItsHeadings() throws {
        let app = launch()
        openProjects(app)

        element(app, labelled: "Q3 Product Launch").tap()
        XCTAssertTrue(app.navigationBars["Q3 Product Launch"].waitForExistence(timeout: 5))

        XCTAssertTrue(
            element(app, labelled: "Ship the new pricing page").waitForExistence(timeout: 5),
            "The brief should be rendered on the project's screen"
        )
        XCTAssertFalse(
            element(app, labelled: "# Brief").exists,
            "The brief should be set as prose, never shown as its Markdown source"
        )

        // Filed under the "Planning" heading in the sample library. The old screen asked the
        // store for direct children only, so this was invisible while its heading was not.
        XCTAssertTrue(
            reveal(app, labelled: "Send the revised pricing table"),
            "Work filed under a heading should appear in the project"
        )
    }

    /// A project with something late says so, in a sentence.
    func testAProjectNamesWhatNeedsAttention() throws {
        let app = launch()
        openProjects(app)

        element(app, labelled: "Q3 Product Launch").tap()
        XCTAssertTrue(app.navigationBars["Q3 Product Launch"].waitForExistence(timeout: 5))

        XCTAssertTrue(
            reveal(app, labelled: "past its deadline"),
            "An overdue item should be named as a concern rather than left to a counter"
        )
    }

    // MARK: - Creating

    /// Creating from a template lands inside the new project rather than back on the list.
    func testCreatingAProjectLandsInsideIt() throws {
        let app = launch()
        openProjects(app)

        app.buttons["projects.new"].tap()
        app.buttons["Blank"].tap()

        let field = app.textFields["nameSheet.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Kitchen rewire")
        app.buttons["nameSheet.confirm"].tap()

        XCTAssertTrue(
            app.navigationBars["Kitchen rewire"].waitForExistence(timeout: 5),
            "Creating a project should open it"
        )
    }

    /// Work can be added to a project from the project, which is the whole point of being in one.
    func testWorkCanBeAddedToAProject() throws {
        let app = launch()
        openProjects(app)

        element(app, labelled: "House move").tap()
        XCTAssertTrue(app.navigationBars["House move"].waitForExistence(timeout: 5))

        app.buttons["project.addWork"].tap()
        let field = app.textFields["nameSheet.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Book the van")
        app.buttons["nameSheet.confirm"].tap()

        XCTAssertTrue(
            reveal(app, labelled: "Book the van"),
            "Added work should appear in the project it was added to"
        )
    }
}
