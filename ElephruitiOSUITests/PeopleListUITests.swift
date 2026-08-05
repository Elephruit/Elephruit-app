import XCTest

/// The Records list at a size that makes its two new controls matter.
///
/// The sample library has a dozen people, which is not a list that needs an alphabet. These launch
/// against a seeded library, because a jump rail and a set of sticky headings are answers to a
/// question forty rows never ask — and a screenshot of twelve contacts would show a feature working
/// without showing what it is for.
///
/// ### Why not the Mac's four hundred
/// `-ElephruitPeopleCount 400` is what the macOS design reviews use, and on the phone it is fatal:
/// `MobileAppEnvironment.start()` seeds synchronously before the first frame, four hundred
/// `createPerson` calls take longer than iOS gives an app to launch, and the whole test runner is
/// killed before it ever connects — which reads as an infrastructure failure rather than as a slow
/// launch, and cost an afternoon to tell apart. A hundred and fifty is enough for a dozen headings
/// and a list several screens long, and it starts.
///
/// Both photographs in the run come from `ContactFixtures`: `CNContactStore` is never constructed,
/// so what these produce is the same on every machine.
final class PeopleListUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func launch(peopleCount: Int) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ElephruitDevelopmentMode",
            "-ElephruitUseTemporaryStore",
            "-ElephruitLoadSampleData",
            "-ElephruitUseFixtureContacts",
            "-ElephruitFixturesAuthorized",
            "-ElephruitPeopleCount", String(peopleCount),
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

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The list itself: faces where Contacts has one, monograms where it does not, and the alphabet
    /// down the trailing edge.
    func testRecordsListShowsFacesAndAnAlphabet() throws {
        let app = launch(peopleCount: 150)
        openRecords(app)

        let rail = app.otherElements["sectionIndexBar"]
        XCTAssertTrue(rail.waitForExistence(timeout: 10), "the jump rail should exist over a long list")

        snap(app, "people-01-list")
    }

    /// Dragging the rail. The assertion is that the list *moved somewhere else* — the screenshots are
    /// what say whether it moved somewhere sensible.
    func testDraggingTheRailJumpsThroughTheAlphabet() throws {
        let app = launch(peopleCount: 150)
        openRecords(app)

        let rail = app.otherElements["sectionIndexBar"]
        XCTAssertTrue(rail.waitForExistence(timeout: 10))

        let namesBefore = visibleNames(app)
        XCTAssertFalse(namesBefore.isEmpty, "the list should have rows to scroll")

        // Near the bottom of the rail rather than at it, so the target is a letter with names under
        // it rather than whatever the last section happens to be.
        rail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
            .press(
                forDuration: 0.2,
                thenDragTo: rail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            )

        snap(app, "people-02-after-scrub")

        XCTAssertNotEqual(
            Set(namesBefore),
            Set(visibleNames(app)),
            "scrubbing the rail should move the list somewhere else in the alphabet"
        )
    }

    /// What is legible on screen right now.
    ///
    /// The rows' own labels are no good for this: each row combines its children into one element
    /// whose label the enclosing cell does not inherit, so `cells.firstMatch.label` is the empty
    /// string and an assertion on it compares "" to "" and passes for the wrong reason — which is
    /// how the first version of this test reported a working scrub as a failure.
    private func visibleNames(_ app: XCUIApplication) -> [String] {
        // Closures rather than key paths: `exists` and `label` are main-actor isolated, and a key
        // path cannot be formed to either.
        app.staticTexts.allElementsBoundByIndex
            .filter { $0.exists }
            .map { $0.label }
            .filter { !$0.isEmpty }
    }

    /// Searching takes the sections away, so the rail has nothing to jump through. It stays on
    /// screen, dimmed: a control that vanishes takes its width with it and shoves every row sideways,
    /// which is a worse answer to "not right now" than saying so.
    func testTheRailStaysPutWhileSearching() throws {
        let app = launch(peopleCount: 150)
        openRecords(app)

        let rail = app.otherElements["sectionIndexBar"]
        XCTAssertTrue(rail.waitForExistence(timeout: 10))

        app.searchFields.firstMatch.tap()
        app.typeText("Maya")

        XCTAssertTrue(rail.exists, "the rail should stay on screen while the search is running")
        snap(app, "people-03-searching")
    }
}
