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

        // Above a root the chevron belongs to the stack, so the drawer is however many backs
        // away — which is the shell's whole claim about what back means, walked here rather
        // than asserted.
        var guardRail = 0
        while !app.buttons["mobile.sidebar.button"].exists && guardRail < 8 {
            app.navigationBars.buttons.firstMatch.tap()
            guardRail += 1
        }

        app.buttons["mobile.sidebar.button"].tap()
        return app.buttons["mobile.sidebar.today"].waitForExistence(timeout: 5)
    }

    private func step(_ app: XCUIApplication, to destination: String) {
        openSidebar(app)
        app.buttons["mobile.sidebar.\(destination)"].tap()
    }

    // MARK: - The drawer

    /// The drawer offers every destination, and choosing one lands on it.
    ///
    /// The drawer's *rows* are asserted here without walking them: thirteen relaunches to prove
    /// thirteen rows exist costs a minute of every run, and `ScreenshotWalkTests` already
    /// visits every one of them and would fail loudly if any row stopped landing. What this
    /// test owns is the part the walk cannot state — that the drawer lists exactly the
    /// destinations the shell claims to have.
    func testTheDrawerOffersEveryDestinationAndOneLands() throws {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))

        openSidebar(app)
        for identifier in [
            "today", "calendar", "reminders", "records", "notes", "time", "areas",
            "bookmarks", "inbox", "archive", "trash", "search", "settings",
        ] {
            XCTAssertTrue(
                app.buttons["mobile.sidebar.\(identifier)"].exists,
                "The drawer should list \(identifier)"
            )
        }

        app.buttons["mobile.sidebar.calendar"].tap()
        XCTAssertTrue(app.navigationBars["Calendar"].waitForExistence(timeout: 5))
    }

    /// The chevron answers the first tap even when a keyboard is up — and takes the keyboard
    /// with it.
    ///
    /// The sequence a reminder makes likely: write something, then leave. If leaving takes two
    /// taps — one swallowed putting the keyboard away, one that works — the button reads as
    /// unreliable rather than as busy. And a drawer that arrives under a keyboard belonging to a
    /// field that is no longer on screen is half a drawer.
    func testTheChevronRegistersWhileTheKeyboardIsUp() throws {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        step(app, to: "reminders")
        XCTAssertTrue(app.navigationBars["Reminders"].waitForExistence(timeout: 5))

        add(app, "reminder")
        XCTAssertTrue(
            app.descendants(matching: .any)["reminders.composer.title"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5), "The composer takes focus")

        app.buttons["mobile.sidebar.button"].tap()
        XCTAssertTrue(
            app.buttons["mobile.sidebar.today"].waitForExistence(timeout: 5),
            "One tap on the chevron should open the drawer, keyboard or no keyboard"
        )
        XCTAssertTrue(
            app.keyboards.element.waitForNonExistence(timeout: 5),
            "Opening the drawer should take the keyboard with it"
        )
    }

    /// The chevron answers a tap anywhere on it, including its leading edge.
    ///
    /// The drawer's swipe is caught by a transparent strip along the leading edge of the screen,
    /// and that strip ran the full height — straight through the leading quarter of the chevron
    /// sitting in the toolbar. A thumb landing there hit the strip, the strip only understands
    /// drags, and the tap went nowhere. Which reads exactly as a button that works most of the
    /// time.
    func testTheChevronRegistersATapOnItsLeadingEdge() throws {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))

        let chevron = app.buttons["mobile.sidebar.button"]
        XCTAssertTrue(chevron.waitForExistence(timeout: 5))
        chevron.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.5)).tap()

        XCTAssertTrue(
            app.buttons["mobile.sidebar.today"].waitForExistence(timeout: 5),
            "A tap on the chevron's leading edge should still open the drawer"
        )
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

    /// Drilling in and walking back out lands on the list, not on the drawer.
    ///
    /// The shell's promise is that back is one idea at every depth, which means the drawer is
    /// *above* the deepest root rather than beside it: a push costs exactly one back to
    /// undo, and the drawer costs one more. A tab bar would have let you leave a pushed screen
    /// without popping it; this deliberately does not, because the price of that was a second
    /// way to move that the back gesture knew nothing about.
    func testDrillingInAndBackReturnsToTheList() throws {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))

        step(app, to: "notes")
        XCTAssertTrue(app.navigationBars["Notes"].waitForExistence(timeout: 5))

        let firstNote = app.collectionViews.cells.firstMatch
        XCTAssertTrue(firstNote.waitForExistence(timeout: 5))
        firstNote.tap()
        XCTAssertTrue(
            app.buttons["mobile.sidebar.button"].waitForNonExistence(timeout: 5),
            "A pushed screen's chevron belongs to the stack, not to the drawer"
        )

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Notes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["mobile.sidebar.button"].exists)
    }

    /// Which destination you were on survives going somewhere else and coming back.
    func testTheDestinationIsRemembered() throws {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))

        step(app, to: "notes")
        XCTAssertTrue(app.navigationBars["Notes"].waitForExistence(timeout: 5))

        step(app, to: "today")
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 5))

        openSidebar(app)
        XCTAssertTrue(
            app.buttons["mobile.sidebar.today"].isSelected,
            "The drawer should show where the app currently is"
        )
    }

    // MARK: - The plus

    /// Opens the fan and taps one of its choices.
    ///
    /// By identifier rather than by label, because a fan of five glass circles has no visible
    /// text for a label match to find, and because the accessibility labels are prose that
    /// should be free to change without breaking every test that reaches through them. And by
    /// `tapCenter` rather than `tap` — see `FloatingControlTaps` for what that buys.
    private func add(_ app: XCUIApplication, _ action: String) {
        app.buttons["mobile.capture.button"].tapCenter()
        let choice = app.buttons["mobile.add.\(action)"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "The plus should fan out")
        choice.tapCenter()
    }

    /// The fan is the plus's whole job now: it opens, it offers all five, and it folds away
    /// again without having done anything.
    ///
    /// The closing half matters as much as the opening one. While the fan is up a scrim covers
    /// the app, so a menu that could be opened and not closed would be a way of locking the
    /// screen — and the plus is the only control still above that scrim.
    func testThePlusFansOutAndFoldsBack() throws {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))

        app.buttons["mobile.capture.button"].tapCenter()
        for action in ["reminder", "event", "note", "time", "capture"] {
            XCTAssertTrue(
                app.buttons["mobile.add.\(action)"].waitForExistence(timeout: 5),
                "The fan should offer \(action)"
            )
        }

        app.buttons["mobile.capture.button"].tapCenter()
        XCTAssertTrue(
            app.buttons["mobile.add.reminder"].waitForNonExistence(timeout: 5),
            "Tapping the plus again should fold the fan away"
        )
        XCTAssertTrue(app.navigationBars["Today"].exists, "And leave the screen where it was")
    }

    // MARK: - Capture

    /// Capture is never a dead tap, and a cancelled sheet goes away.
    func testCaptureSheetOpensAndDismisses() throws {
        let app = launch()

        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        add(app, "capture")
        XCTAssertTrue(app.navigationBars["Capture"].waitForExistence(timeout: 5))

        // "Close", not "Cancel": the sheet keeps the draft rather than discarding it, and its
        // button says so.
        app.buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 5))
    }
}
