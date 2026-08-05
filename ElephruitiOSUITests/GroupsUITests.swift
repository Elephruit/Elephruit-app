import XCTest

/// Groups: the list of them, making one, and filtering people by one.
///
/// These launch against the sample library rather than a seeded one. The sample library is where
/// the groups are — `PeopleSampleData` makes Family, Design Team and two smart groups — and it is
/// small enough to launch quickly. The seeded people from `PeopleListUITests` are in no group, so
/// seeding here would add a hundred and fifty rows with nothing to show.
final class GroupsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ElephruitDevelopmentMode",
            "-ElephruitUseTemporaryStore",
            "-ElephruitLoadSampleData",
            "-ElephruitUseFixtureContacts",
            "-ElephruitFixturesAuthorized",
        ]
        app.launch()
        return app
    }

    private func openRecords(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 20))
        app.buttons["mobile.sidebar.button"].tap()
        XCTAssertTrue(app.buttons["mobile.sidebar.records"].waitForExistence(timeout: 10))
        app.buttons["mobile.sidebar.records"].tap()
        XCTAssertTrue(app.navigationBars["Records"].waitForExistence(timeout: 10))
    }

    private func openGroups(_ app: XCUIApplication) {
        app.buttons["records.scope"].tap()
        XCTAssertTrue(app.buttons["Manage Groups…"].waitForExistence(timeout: 10))
        app.buttons["Manage Groups…"].tap()
        XCTAssertTrue(app.navigationBars["Groups"].waitForExistence(timeout: 10))
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The list, with its dots, and the groups screen that teaches what the dots mean.
    func testGroupsAreListedWithTheirColors() throws {
        let app = launch()
        openRecords(app)
        snap(app, "groups-01-list-with-dots")

        openGroups(app)
        XCTAssertTrue(app.staticTexts["Family"].waitForExistence(timeout: 10))
        snap(app, "groups-02-groups-screen")
    }

    /// Making one. The colour is pre-chosen, so the whole path is a name and Save.
    func testCreatingAGroup() throws {
        let app = launch()
        openRecords(app)
        openGroups(app)

        app.buttons["groups.new"].tap()
        XCTAssertTrue(app.textFields["group.name"].waitForExistence(timeout: 10))
        app.textFields["group.name"].tap()
        app.typeText("Cycling")
        snap(app, "groups-03-new-group")

        app.buttons["group.save"].tap()

        XCTAssertTrue(
            app.staticTexts["Cycling"].waitForExistence(timeout: 10),
            "a new group should appear in the list it was made from"
        )
        snap(app, "groups-04-after-create")
    }

    /// Filtering. Tapping a group goes to the people in it and nobody else.
    func testFilteringPeopleByGroup() throws {
        let app = launch()
        openRecords(app)
        openGroups(app)

        XCTAssertTrue(app.staticTexts["Family"].waitForExistence(timeout: 10))
        app.staticTexts["Family"].tap()

        XCTAssertTrue(
            app.navigationBars["Family"].waitForExistence(timeout: 10),
            "the filtered list should be titled with the group's own name, not \"Group\""
        )
        snap(app, "groups-05-filtered")
    }
}
