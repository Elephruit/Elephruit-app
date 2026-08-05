import XCTest

/// Today as a feed: that it keeps going, and that it keeps going *further* the longer you scroll.
///
/// The paging rule is asserted against the model in `DailyPlanServiceTests`. What can only be
/// asserted here is the half that lives in the scroll view — that reaching the bottom is what asks
/// for the next week, and that the week arrives without a control to press.
final class TodayFeedUITests: XCTestCase {
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
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 15))
        return app
    }

    /// Scrolls until the day is in the tree.
    ///
    /// A `List` only realises the cells near the viewport, so a day is not findable until the scroll
    /// has been near it — which is the same reason the feed cannot be tested from a standstill.
    ///
    /// Probing for the one identifier rather than enumerating every day marker matters: a predicate
    /// over all descendants takes a full accessibility snapshot, and doing that after every swipe of
    /// a list that is deliberately growing is slow enough that the runner kills the app.
    @discardableResult
    private func scroll(_ app: XCUIApplication, to target: String, swipes: Int = 30) -> Bool {
        let day = app.descendants(matching: .any)[target]
        for _ in 0..<swipes {
            if day.exists { return true }
            app.swipeUp(velocity: .fast)
        }
        return day.exists
    }

    func testScrollingReachesDaysThatWereNeverAskedFor() throws {
        let app = launch()
        snap(app, "01-today")

        // Today is drawn in full, so the days after it begin below it.
        XCTAssertTrue(
            scroll(app, to: key(daysFromToday: 1)),
            "the day is followed by the days after it"
        )
        snap(app, "02-the-days-after-today")

        // Past the initial window and past the first extension both. Reaching it means the feed
        // asked for more days twice over, without a control being pressed.
        let target = key(daysFromToday: 14)
        let reached = scroll(app, to: target)
        snap(app, "03-a-fortnight-out")

        XCTAssertTrue(reached, "scrolling never reached \(target)")
    }

    func testADayInTheFeedOpensOutInPlace() throws {
        let app = launch()

        let tomorrowKey = key(daysFromToday: 1)
        scroll(app, to: tomorrowKey)
        let tomorrow = app.descendants(matching: .any)[tomorrowKey]
        XCTAssertTrue(tomorrow.waitForExistence(timeout: 10))

        // A summary is a line per thing; the whole day is that plus the sections only a full day
        // draws. Asserted on one of those sections by identifier rather than by counting text:
        // how many static texts are on screen depends on where the scroll comes to rest, so the
        // count passed this test when run alone and failed it in a suite, which is a test reporting
        // the weather rather than the behaviour.
        let scheduleHeaders = app.descendants(matching: .any)
            .matching(identifier: "today.schedule.header")
        let before = scheduleHeaders.count

        tomorrow.tap()

        snap(app, "04-a-day-opened-in-place")
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "today.schedule.header")
                .element(boundBy: before).waitForExistence(timeout: 5),
            "tapping a day in the feed did not draw its schedule"
        )
    }

    /// The accessibility identifier a day marker carries, which is `DayKey`'s `yyyy-MM-dd`.
    private func key(daysFromToday days: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: days, to: Date()) ?? Date()
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "today.day.%04d-%02d-%02d",
            parts.year ?? 0, parts.month ?? 1, parts.day ?? 1
        )
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
