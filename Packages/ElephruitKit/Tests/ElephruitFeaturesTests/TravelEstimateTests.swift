import ElephruitCore
import ElephruitFeaturesCore
import ElephruitIntegrations
import Foundation
import Testing

/// Which of three answers the page gets, and how often the app asks for the second one.
///
/// The feature is an ordering — a fresh measurement, then what the user said, then **nothing** — and
/// the third of those is the one that took a bug report to get right. It used to be a default
/// fifteen minutes, rendered in the same words and the same confidence as a measurement, under
/// meetings the app had never looked up.
///
/// The other half is restraint. A page redraws constantly, a meeting room never geocodes, and the
/// room is exactly what appears in a calendar five days a week: an app that asked every time would
/// spend a network call per scroll learning the same "no" forever.
@Suite("Travel estimates")
@MainActor
struct TravelEstimateTests {
    static let now = Date(timeIntervalSinceReferenceDate: 757_425_600)
    static let studio = "Northwind Studio, 40 Rivington Street"

    /// Departing in half an hour: inside the window where traffic is worth re-checking.
    static var soon: Date { now.addingTimeInterval(30 * 60) }

    /// The case that used to be refused outright, and so produced a number nobody had earned.
    static var nextWeek: Date { now.addingTimeInterval(7 * 24 * 60 * 60) }

    private static func scratchDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "travel.tests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func preferences(
        clock: MovingClock,
        provider: @escaping @Sendable () -> any RouteProviding
    ) -> TravelPreferences {
        TravelPreferences(defaults: scratchDefaults(), dateProvider: clock, makeProvider: provider)
    }

    // MARK: - The ordering

    /// The bug this whole change exists for.
    @Test("A journey nobody has measured and nobody has answered for has no number at all")
    func anUnaskedJourneyHasNoNumber() {
        let clock = MovingClock(now: Self.now)
        let travel = Self.preferences(clock: clock) { FixtureRouteProvider(dateProvider: clock) }

        let answer = travel.travel(to: Self.studio)
        #expect(answer.minutes == nil, """
            The default used to answer here, and the page drew "leave by" off it. A number nobody \
            earned must not reach the page at all.
            """)
        #expect(!answer.invitesAnAnswer, "nothing has been asked yet, so there is nothing to report")

        // It is still the starting position of a picker, which is the one place it belongs.
        #expect(travel.startingMinutes(for: Self.studio) == TravelRules.defaultMinutes)
    }

    @Test("A number its owner gave is used and said to be theirs")
    func theToldNumberIsUsed() {
        let clock = MovingClock(now: Self.now)
        let travel = Self.preferences(clock: clock) { FixtureRouteProvider(dateProvider: clock) }

        travel.remember(minutes: 25, to: Self.studio)
        #expect(travel.travel(to: Self.studio) == .told(25))
        #expect(travel.startingMinutes(for: Self.studio) == 25)

        #expect(travel.travel(to: "Somewhere else").minutes == nil,
                "answering for one place says nothing about another")
    }

    @Test("A measurement beats the number its owner gave")
    func aMeasurementWins() async {
        let clock = MovingClock(now: Self.now)
        let travel = Self.preferences(clock: clock) { FixtureRouteProvider(dateProvider: clock) }
        travel.remember(minutes: 25, to: Self.studio)

        await travel.enableEstimates()
        await travel.refreshEstimate(to: RoutePlace(name: Self.studio), departingAt: Self.soon)

        let answer = travel.travel(to: Self.studio)
        #expect(answer.minutes == 12, "the fixture's measured figure, not the remembered 25")
        #expect(answer.isMeasured)
    }

    /// By far the commonest outcome in a real calendar, and the one that must stay quiet.
    @Test("A place that will not geocode says nothing")
    func aRoomIsSilent() async {
        let clock = MovingClock(now: Self.now)
        let travel = Self.preferences(clock: clock) { FixtureRouteProvider(dateProvider: clock) }

        await travel.enableEstimates()
        await travel.refreshEstimate(to: RoutePlace(name: "Room 2"), departingAt: Self.soon)

        let answer = travel.travel(to: "Room 2")
        #expect(answer.minutes == nil)
        #expect(!answer.invitesAnAnswer, """
            You are already in the building. A prompt under every meeting-room booking is noise, \
            and it is most of somebody's calendar.
            """)
    }

    /// Detroit booked from Minnesota: a true ten-hour answer to the wrong question.
    @Test("A journey we could not work out offers to be told")
    func anUnworkableJourneyAsks() async {
        let clock = MovingClock(now: Self.now)
        let travel = Self.preferences(clock: clock) {
            CountingRouteProvider(clock: clock, answer: .failure(.implausible))
        }

        await travel.enableEstimates()
        await travel.refreshEstimate(to: RoutePlace(name: "Cobo Center, Detroit"), departingAt: Self.nextWeek)

        let answer = travel.travel(to: "Cobo Center, Detroit")
        #expect(answer.minutes == nil, "ten hours is not a travel time, it is a wrong origin")
        #expect(answer.invitesAnAnswer, "the reader can settle this in one tap and the app cannot")
    }

    // MARK: - When it asks again

    /// The horizon that caused the original complaint is gone.
    @Test("A journey next week is measured, not guessed at")
    func nextWeekIsMeasured() async {
        let clock = MovingClock(now: Self.now)
        let spy = CountingRouteProvider(clock: clock, answer: nil)
        let travel = Self.preferences(clock: clock) { spy }
        await travel.enableEstimates()

        await travel.refreshEstimate(to: RoutePlace(name: Self.studio), departingAt: Self.nextWeek)

        #expect(spy.asked == 1, "MapKit is told when the journey departs and models the traffic then")
        #expect(travel.travel(to: Self.studio).isMeasured)
    }

    /// The start-of-day re-measure, which is an expiry rather than a scheduler.
    @Test("An answer for a distant journey lasts the day and no longer")
    func distantAnswersExpireOvernight() async {
        let clock = MovingClock(now: Self.now)
        let travel = Self.preferences(clock: clock) { FixtureRouteProvider(dateProvider: clock) }
        await travel.enableEstimates()

        await travel.refreshEstimate(to: RoutePlace(name: Self.studio), departingAt: Self.nextWeek)
        #expect(travel.travel(to: Self.studio).isMeasured)

        // Later the same day, from the same city: still good.
        clock.now = Self.now.addingTimeInterval(3 * 60 * 60)
        #expect(travel.travel(to: Self.studio).isMeasured)

        // Tomorrow, possibly from somewhere else entirely: ask again.
        clock.now = Self.now.addingTimeInterval(26 * 60 * 60)
        #expect(!travel.travel(to: Self.studio).isMeasured, """
            The reader may have woken up in a different city. That is the whole reason the answer \
            does not survive the night.
            """)
    }

    @Test("An answer for a journey about to happen is re-checked every quarter hour")
    func imminentAnswersAreRecheckedOften() async {
        let clock = MovingClock(now: Self.now)
        let spy = CountingRouteProvider(clock: clock, answer: nil)
        let travel = Self.preferences(clock: clock) { spy }
        await travel.enableEstimates()

        let place = RoutePlace(name: Self.studio)
        await travel.refreshEstimate(to: place, departingAt: Self.soon)
        #expect(spy.asked == 1)

        clock.now = Self.now.addingTimeInterval(14 * 60)
        await travel.refreshEstimate(to: place, departingAt: Self.soon)
        #expect(spy.asked == 1, "still fresh")

        clock.now = Self.now.addingTimeInterval(16 * 60)
        await travel.refreshEstimate(to: place, departingAt: Self.soon)
        #expect(spy.asked == 2, "an accident on the route is now something you can act on")
    }

    // MARK: - Restraint

    /// Without this, every redraw of a page containing a meeting room is a network call.
    @Test("A place that refused is not asked again straight away")
    func refusalsAreRemembered() async {
        let clock = MovingClock(now: Self.now)
        let spy = CountingRouteProvider(clock: clock)
        let travel = Self.preferences(clock: clock) { spy }
        await travel.enableEstimates()

        let room = RoutePlace(name: "Room 2")
        for _ in 0..<5 {
            await travel.refreshEstimate(to: room, departingAt: Self.soon)
        }

        #expect(spy.asked == 1, "a room that does not exist does not start existing on the next scroll")
    }

    @Test("A service that was merely unreachable is tried again sooner")
    func transientFailuresRetrySooner() async {
        let clock = MovingClock(now: Self.now)
        let spy = CountingRouteProvider(clock: clock, answer: .failure(.unavailable))
        let travel = Self.preferences(clock: clock) { spy }
        await travel.enableEstimates()

        let place = RoutePlace(name: Self.studio)
        await travel.refreshEstimate(to: place, departingAt: Self.soon)
        #expect(spy.asked == 1)

        clock.now = Self.now.addingTimeInterval(60)
        await travel.refreshEstimate(to: place, departingAt: Self.soon)
        #expect(spy.asked == 1)

        clock.now = Self.now.addingTimeInterval(5 * 60 + 1)
        await travel.refreshEstimate(to: place, departingAt: Self.soon)
        #expect(spy.asked == 2, "a network that was down comes back; a place that does not exist does not")
    }

    /// Both ends of what is left of the window, now that the lookahead limit is gone.
    @Test("A journey already gone is not measured")
    func departuresInThePastAreNotMeasured() async {
        let clock = MovingClock(now: Self.now)
        let spy = CountingRouteProvider(clock: clock)
        let travel = Self.preferences(clock: clock) { spy }
        await travel.enableEstimates()

        await travel.refreshEstimate(
            to: RoutePlace(name: Self.studio),
            departingAt: Self.now.addingTimeInterval(-RouteRules.closeInFreshness - 60)
        )
        #expect(spy.asked == 0)
    }

    // MARK: - The switch

    @Test("Nothing is measured until somebody turns it on")
    func measuringIsOffUntilAsked() async {
        let clock = MovingClock(now: Self.now)
        let spy = CountingRouteProvider(clock: clock)
        let travel = Self.preferences(clock: clock) { spy }

        #expect(!travel.isEstimating)
        await travel.refreshEstimate(to: RoutePlace(name: Self.studio), departingAt: Self.soon)

        #expect(spy.asked == 0, "an app that is off must not have asked anybody anything")
        #expect(travel.travel(to: Self.studio).minutes == nil)
    }

    /// The bug that made the whole feature look broken to the first person who used it.
    ///
    /// `enableEstimates()` was the only thing that ever set `authorization`, so the session where
    /// somebody turned the switch on worked and every session afterwards did not: the app came back
    /// up with the switch on, the permission standing, and `authorization` at its initial
    /// `.notRequested` — measuring nothing, forever, because nothing would ever ask again.
    @Test("A relaunch with the switch already on still measures")
    func aRelaunchStillMeasures() async {
        let clock = MovingClock(now: Self.now)
        let defaults = Self.scratchDefaults()

        let first = TravelPreferences(defaults: defaults, dateProvider: clock) {
            FixtureRouteProvider(dateProvider: clock)
        }
        await first.enableEstimates()

        // The next launch: same preferences on disk, a brand-new object, nobody asked again.
        let second = TravelPreferences(defaults: defaults, dateProvider: clock) {
            FixtureRouteProvider(dateProvider: clock)
        }
        #expect(second.isEstimating, "the switch is remembered")
        #expect(second.authorization == .notRequested, "and nothing has read the standing decision yet")

        await second.refreshEstimate(to: RoutePlace(name: Self.studio), departingAt: Self.soon)

        #expect(second.travel(to: Self.studio).minutes == 12, """
            A relaunched app with the switch on and permission granted must measure. Reading the \
            standing decision costs nothing and never prompts.
            """)
    }

    @Test("A refused permission measures nothing")
    func aRefusedPermissionMeasuresNothing() async {
        let clock = MovingClock(now: Self.now)
        let travel = Self.preferences(clock: clock) {
            FixtureRouteProvider(authorization: .denied, dateProvider: clock)
        }

        #expect(await travel.enableEstimates() == .denied)
        await travel.refreshEstimate(to: RoutePlace(name: Self.studio), departingAt: Self.soon)
        #expect(travel.travel(to: Self.studio).minutes == nil)
    }

    @Test("Turning it off drops what was measured rather than letting it age out")
    func disablingForgetsEverything() async {
        let clock = MovingClock(now: Self.now)
        let travel = Self.preferences(clock: clock) { FixtureRouteProvider(dateProvider: clock) }
        travel.remember(minutes: 25, to: Self.studio)

        await travel.enableEstimates()
        await travel.refreshEstimate(to: RoutePlace(name: Self.studio), departingAt: Self.soon)
        #expect(travel.travel(to: Self.studio).minutes == 12)

        travel.disableEstimates()

        #expect(travel.travel(to: Self.studio) == .told(25), """
            A page still showing a measured figure after the switch went off would be telling \
            somebody the feature is off while it is visibly still on
            """)
        #expect(travel.rememberedPlaceCount == 1, "turning measuring off is not forgetting what you were told")
    }

    @Test("Changing how you travel discards answers about the other way")
    func changingTransportClearsWhatWasMeasured() async {
        let clock = MovingClock(now: Self.now)
        let travel = Self.preferences(clock: clock) { FixtureRouteProvider(dateProvider: clock) }

        await travel.enableEstimates()
        await travel.refreshEstimate(to: RoutePlace(name: Self.studio), departingAt: Self.soon)
        #expect(travel.travel(to: Self.studio).minutes == 12)

        travel.transport = .walking
        #expect(travel.travel(to: Self.studio).minutes == nil, "a drive reported as a walk is worse than no answer")

        await travel.refreshEstimate(to: RoutePlace(name: Self.studio), departingAt: Self.soon)
        #expect(travel.travel(to: Self.studio).minutes == 48)
    }

    @Test("Forgetting a place forgets what was measured about it too")
    func forgettingAPlaceForgetsItsMeasurement() async {
        let clock = MovingClock(now: Self.now)
        let travel = Self.preferences(clock: clock) { FixtureRouteProvider(dateProvider: clock) }
        travel.remember(minutes: 25, to: Self.studio)

        await travel.enableEstimates()
        await travel.refreshEstimate(to: RoutePlace(name: Self.studio), departingAt: Self.soon)
        #expect(travel.travel(to: Self.studio).minutes == 12)

        travel.forget(Self.studio)
        #expect(travel.travel(to: Self.studio).minutes == nil)
    }
}

// MARK: - Doubles

/// A clock somebody can push forward, so freshness and retry delays are assertions rather than
/// sleeps.
private final class MovingClock: DateProvider, @unchecked Sendable {
    nonisolated(unsafe) var now: Date
    let calendar = Calendar(identifier: .gregorian)

    init(now: Date) { self.now = now }
}

/// Counts how often it was actually asked, which is half of what these tests are about.
private final class CountingRouteProvider: RouteProviding, @unchecked Sendable {
    nonisolated(unsafe) private(set) var asked = 0

    private let clock: MovingClock

    /// What to answer. `nil` means "measure something plausible"; a value pins the outcome.
    private let answer: Result<RouteEstimate, RouteFailure>?

    init(clock: MovingClock, answer: Result<RouteEstimate, RouteFailure>? = .failure(.placeNotFound)) {
        self.clock = clock
        self.answer = answer
    }

    var authorization: IntegrationAuthorization { .authorized }
    func requestAccess() async -> IntegrationAuthorization { .authorized }

    func estimate(
        to place: RoutePlace,
        by transport: RouteTransport,
        departingAt moment: Date
    ) async -> Result<RouteEstimate, RouteFailure> {
        asked += 1
        return answer ?? .success(RouteEstimate(
            placeKey: place.key, minutes: 12, transport: transport, measuredAt: clock.now
        ))
    }
}
