import XCTest

/// Recording somebody's family on a phone, end to end.
///
/// The conversation this whole path was built for, driven the way a person drives it: open a
/// record, press the word *Son*, type a grade, save — and find the child on the page afterwards
/// under a name nobody gave him.
///
/// ### Why this is a UI test and not another unit test
/// The value types and the repository already have suites, and they pass. What they cannot say is
/// whether the phone reaches any of it: the screen was read-only for the whole life of the module,
/// and a write path with no button in front of it is exactly the failure that shipped. This asserts
/// the button exists, is reachable with a thumb, and that pressing it changes the page behind.
final class PersonCaptureUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    /// Opens straight onto Maya's record, through the phone review routing.
    private func launchOnMaya() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ElephruitDevelopmentMode",
            "-ElephruitUseTemporaryStore",
            "-ElephruitLoadSampleData",
            "-ElephruitUseFixtureContacts",
            "-ElephruitFixturesAuthorized",
            "-ElephruitSelectPerson", "Maya",
        ]
        app.launch()
        return app
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Scrolls the record until something is on screen, and fails if it never is.
    ///
    /// ### Why not simply swipe to the bottom
    /// Because a cell is in the accessibility tree only while it is realised, and that cuts *both*
    /// ways: below the fold it is not there yet, and once scrolled past the top it is gone again.
    /// Swiping a fixed number of times to the end of a long record recycled the Connected section
    /// out of existence and reported its button as missing — which reads exactly like the button
    /// having never been added.
    @discardableResult
    private func scroll(_ app: XCUIApplication, to element: XCUIElement, _ message: String) -> Bool {
        // The page itself, not `collectionViews.firstMatch` — a presented sheet is a collection view
        // too, and swiping the wrong one scrolls nothing while looking like it worked.
        let list = app.collectionViews["person.screen"]
        for _ in 0..<10 {
            if element.exists, element.isHittable { return true }
            list.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, message)
        return element.exists
    }

    func testAddingAChildFromThePhone() throws {
        let app = launchOnMaya()
        XCTAssertTrue(
            app.collectionViews["person.screen"].waitForExistence(timeout: 20),
            "review routing should open the record without anybody tapping"
        )

        let addFamily = app.buttons["person.addRelatives"]
        scroll(app, to: addFamily, "the page must offer a way to add family")
        addFamily.tap()

        // Waited for by its first control rather than by the sheet's own container: which element
        // type SwiftUI gives a presented `NavigationStack` is not a promise, and the button is.
        let addSon = app.buttons["person.relatives.add.son"]
        XCTAssertTrue(addSon.waitForExistence(timeout: 10), "the family sheet should be up")
        snap(app, "person-capture-01-sheet")
        addSon.tap()

        let grade = app.textFields["person.relatives.grade"]
        XCTAssertTrue(grade.waitForExistence(timeout: 10))
        grade.tap()
        grade.typeText("senior")

        snap(app, "person-capture-02-filled")

        let save = app.buttons["person.relatives.save"]
        XCTAssertTrue(save.isEnabled, "a son with a grade is worth saving even with no name")
        save.tap()

        // Back on the page: the child is in Connected under the phrase that stands in for a name,
        // and the app is now asking what he is called.
        XCTAssertTrue(app.collectionViews["person.screen"].waitForExistence(timeout: 10))

        scroll(
            app, to: app.staticTexts["Maya Chen's son"],
            "an unnamed child reads as a description of a person, not as a blank"
        )
        scroll(
            app, to: app.buttons["person.fillIn.name"],
            "the app should ask for the name it does not have"
        )

        snap(app, "person-capture-03-recorded")
    }

    /// Filling in the blank keeps everything already known, which is the difference between
    /// supplying a name and starting the record again.
    func testSupplyingTheNameLater() throws {
        let app = launchOnMaya()
        XCTAssertTrue(app.collectionViews["person.screen"].waitForExistence(timeout: 20))

        let addFamily = app.buttons["person.addRelatives"]
        scroll(app, to: addFamily, "the page must offer a way to add family")
        addFamily.tap()
        let addDaughter = app.buttons["person.relatives.add.daughter"]
        XCTAssertTrue(addDaughter.waitForExistence(timeout: 10))
        addDaughter.tap()

        let grade = app.textFields["person.relatives.grade"]
        XCTAssertTrue(grade.waitForExistence(timeout: 10))
        grade.tap()
        grade.typeText("8th")
        app.buttons["person.relatives.save"].tap()

        XCTAssertTrue(app.collectionViews["person.screen"].waitForExistence(timeout: 10))

        let ask = app.buttons["person.fillIn.name"]
        scroll(app, to: ask, "the app should ask for the name it does not have")
        ask.tap()

        let field = app.textFields["person.nameSheet.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Nina")
        app.buttons["person.nameSheet.save"].tap()

        scroll(app, to: app.staticTexts["Nina"], "the phrase should have become the name")
        snap(app, "person-capture-04-named")
    }
}
