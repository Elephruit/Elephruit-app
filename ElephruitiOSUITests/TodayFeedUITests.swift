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

    /// A meeting somewhere says when to leave, and the line writes the journey.
    ///
    /// Asserted against a day that has not happened yet, on purpose. A "leave by" line disappears
    /// once the moment has passed, so a test aimed at today's meetings proves the feature before
    /// lunch and fails after it — which is a test reporting the clock. Tomorrow evening is always
    /// still ahead.
    func testAMeetingSomewhereSaysWhenToLeave() throws {
        let app = launch()

        let tomorrowKey = key(daysFromToday: 1)
        scroll(app, to: tomorrowKey)
        let tomorrow = app.descendants(matching: .any)[tomorrowKey]
        XCTAssertTrue(tomorrow.waitForExistence(timeout: 10))
        tomorrow.tap()

        // Scrolled until it can be *pressed*, not merely until it exists: a list realises rows about
        // a screen beyond the fold, so the first `exists` is true while the line is still below the
        // bottom of the screen — and a screenshot taken then proves nothing.
        let travel = app.buttons["today.travel"]
        for _ in 0..<8 where !travel.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(travel.exists, "a meeting with an address said nothing about getting to it")
        snap(app, "07-leave-by")

        travel.tap()
        XCTAssertTrue(
            app.buttons["today.block.add"].waitForExistence(timeout: 10),
            "the leave-by line offered no way to claim the time"
        )
        snap(app, "08-the-journey-as-a-block")
    }

    /// The feed runs backwards too, and today can be got back to.
    ///
    /// ### What is actually being proved
    /// That the past is *not* there until it is asked for — the first thing checked, because the
    /// cost of getting this wrong is a calendar read every morning for a question nobody put — that
    /// asking produces the days behind today, and that once today is off the screen there is a way
    /// back to it that says which way it went.
    func testTheFeedRunsBackwardsAndFindsItsWayHome() throws {
        let app = launch()

        let yesterdayKey = key(daysFromToday: -1)
        XCTAssertFalse(
            app.descendants(matching: .any)[yesterdayKey].exists,
            "yesterday is a record, not a plan, and must not be loaded before it is asked for"
        )

        let earlier = app.buttons["today.showPreviousDays"]
        XCTAssertTrue(earlier.waitForExistence(timeout: 20), "there was no way into the days behind")
        earlier.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)[yesterdayKey].waitForExistence(timeout: 15),
            "asking for the earlier days produced none"
        )
        snap(app, "05-the-days-behind-today")
    }

    /// From weeks back, there is a way home, and it says which way home is.
    ///
    /// Launched into the past rather than swiped into it. Getting there by gesture takes a reveal
    /// and half a dozen flicks whose distance depends on how tall the days happen to be, which is a
    /// test that reports the fixture's weather; the launch switch puts the page in the state under
    /// test and leaves the assertions to say something.
    func testThereIsAWayBackFromWeeksAgo() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ElephruitDevelopmentMode",
            "-ElephruitUseTemporaryStore",
            "-ElephruitLoadSampleData",
            "-ElephruitUseFixtureCalendar",
            "-ElephruitFixturesAuthorized",
            "-ElephruitTodayEarlierDays", "21",
        ]
        app.launch()

        let home = app.buttons["today.backToNow"]
        XCTAssertTrue(
            home.waitForExistence(timeout: 30),
            "today scrolled away and left nothing to get back with"
        )
        snap(app, "06-the-way-back-to-now")

        // Both ways back, and the toolbar's is the one somebody looks for.
        XCTAssertTrue(app.buttons["today.return"].exists, "the toolbar forgot the way back")

        home.tap()
        XCTAssertTrue(
            app.staticTexts["today.schedule.header"].waitForExistence(timeout: 10),
            "the way back did not land on today"
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
