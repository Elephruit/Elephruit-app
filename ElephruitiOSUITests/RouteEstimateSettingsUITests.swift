import XCTest

/// The switch that decides whether this app ever uses the network for anything but sync.
///
/// ### Why it is worth its own test rather than a line in the screenshot walk
/// Because the thing being asserted is a *transition*, and the state before it is the one almost
/// every user is in. A screenshot proves the row draws; it cannot prove that the app starts with
/// this off, that nothing else on the screen mentions routing until it is on, or that turning it on
/// is what reveals the rest.
///
/// Launched with a fixture route provider but deliberately **without**
/// `-ElephruitFixturesAuthorized`. That combination is the whole reason this test can exist: the
/// fixture answers the permission request itself, so flipping the switch never puts a CoreLocation
/// dialogue on screen — and a system alert is a thing a UI test cannot dismiss and does not fail
/// against, it simply waits out its timeout and reports the wrong cause.
final class RouteEstimateSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openSettings() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ElephruitDevelopmentMode",
            "-ElephruitUseTemporaryStore",
            "-ElephruitLoadSampleData",
            "-ElephruitUseFixtureCalendar",
            "-ElephruitUseFixtureRoutes",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 20))

        app.buttons["mobile.sidebar.button"].tap()
        XCTAssertTrue(app.buttons["mobile.sidebar.settings"].waitForExistence(timeout: 10))
        app.buttons["mobile.sidebar.settings"].tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        return app
    }

    /// Scrolls until the element can be *pressed*, not merely until it exists.
    ///
    /// Integrations is four sections down a phone-width form, and a `List` only realises rows about
    /// a screen beyond the fold — so the switch is absent from the accessibility tree entirely until
    /// the page has been dragged to it, and the first `exists` is still false while it is one swipe
    /// away. This cost a full timeout and a failure message about the feature rather than the query.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable {
            app.swipeUp()
        }
    }

    /// Taps a `Toggle` where its control actually is.
    ///
    /// Giving a `Toggle` an accessibility identifier collapses the whole row into one `Switch`
    /// element — 370 points wide here — so `tap()` aims at the row's centre, which is the label.
    /// The tap lands, nothing toggles, and the failure reads as "the feature did not turn on" rather
    /// than "you pressed the words". Two runs went into that; the element's own debug description is
    /// what settled it, since it prints the frame.
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    /// Waits for a switch to settle, rather than reading it the instant after a tap.
    ///
    /// Turning this one on asks the system for location access, so the binding hands off to a task
    /// and the switch is still reporting its old value when `tap()` returns. Asserting immediately
    /// tests how fast a permission request answers, which is not a fact about this app.
    private func expect(_ element: XCUIElement, toRead value: String, _ message: String) {
        let settled = expectation(
            for: NSPredicate(format: "value == %@", value), evaluatedWith: element
        )
        XCTAssertEqual(XCTWaiter().wait(for: [settled], timeout: 10), .completed, message)
    }

    /// By identifier throughout: every control here is chrome this screen renders from a literal,
    /// which is the kind that gets reworded and restructured. Matching the words passes until
    /// somebody does, and then waits out a full timeout before failing with a message about the
    /// feature rather than about the query.
    func testRouteEstimatesStartOffAndRevealTheRestWhenTurnedOn() throws {
        let app = openSettings()

        // Read before scrolling: the told-number setting is the floor and is offered whatever else
        // is switched on, so it is near the top. How you travel is meaningless until something is
        // actually routing, and must not be beside it.
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.travel.default"].waitForExistence(timeout: 10),
            "the told-number setting is the floor and is always offered"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["settings.travel.transport"].exists,
            "how you travel is a question about a measurement nobody has switched on"
        )

        let routes = app.descendants(matching: .any)["settings.integration.routes"]
        reveal(routes, in: app)
        XCTAssertTrue(routes.exists, "the route estimates switch did not draw")

        // The state nearly every user is in, and the one the privacy copy is written against.
        XCTAssertEqual(
            routes.value as? String, "0",
            "route estimates must be off until somebody asks for them"
        )

        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "settings-routes-off"
        before.lifetime = .keepAlways
        add(before)

        flip(routes)

        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "settings-routes-on"
        after.lifetime = .keepAlways
        add(after)

        expect(routes, toRead: "1", "the route estimates switch did not turn on")

        // Back up the page: what the switch reveals is in "Getting there", which is now above the
        // fold rather than below it. Same realisation rule, opposite direction.
        let transport = app.descendants(matching: .any)["settings.travel.transport"]
        for _ in 0..<8 where !transport.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(transport.exists, "turning route estimates on did not offer how you travel")

        // And back off, because a switch that cannot be undone is one nobody dares try. Scrolled to
        // again rather than reused: the page moved under it while the picker was being found.
        reveal(routes, in: app)
        flip(routes)
        expect(routes, toRead: "0", "the route estimates switch did not turn off again")

        for _ in 0..<8 where !app.descendants(matching: .any)["settings.travel.default"].isHittable {
            app.swipeDown()
        }
        XCTAssertFalse(
            app.descendants(matching: .any)["settings.travel.transport"].exists,
            "turning route estimates off left a setting that only means anything while it is on"
        )
    }
}
