import ElephruitCore
import ElephruitFeaturesCore
import ElephruitIntegrations
import Foundation
import Testing

/// Which of two answers the page gets, and how often the app asks for the second one.
///
/// The feature is an ordering — a fresh measurement, then what the user said, then the default — and
/// every interesting case is a step *down* it. What matters is that each step is silent and lands on
/// a number that works, because the alternative is a page that goes blank when a phone loses signal.
///
/// The other half is restraint. A page redraws constantly, a meeting room never geocodes, and the
/// room is exactly what appears in a calendar five days a week: an app that asked every time would
/// spend a network call per scroll learning the same "no" forever.
@Suite("Travel estimates")
@MainActor
struct TravelEstimateTests {
    static let now = Date(timeIntervalSinceReferenceDate: 757_425_600)
    static let studio = "Northwind Studio, 40 Rivington Street"

    /// Departing in half an hour: comfortably inside the window worth measuring.
    static var soon: Date { now.addingTimeInterval(30 * 60) }

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

    @Test("With nothing measured, the answer is the one its owner gave")
    func theToldNumberIsTheFloor() async {
        let clock = MovingClock(now: Self.now)
        let travel = Self.preferences(clock: clock) { FixtureRouteProvider(dateProvider: clock) }

        #expect(travel.minutes(to: Self.studio) == TravelRules.defaultMinutes)
        #expect(travel.travel(to: Self.studio).isMeasured == false)

        travel.remember(minutes: 25, to: Self.studio)
        #expect(travel.minutes(to: Self.studio) == 25)
        #expect(travel.minutes(to: "Somewhere else") == TravelRules.defaultMinutes)
    }

    @Test("A measurement beats the number its owner gave")
    func aMeasurementWins() async {
        let clock = MovingClock(now: Self.now)
        let travel = Self.preferences(clock: clock) { FixtureRouteProvider(dateProvider: clock) }
        travel.remember(minutes: 25, to: Self.studio)

        await travel.enableEstimates()
        await travel.refreshEstimate(
            to: RoutePlace(name: Self.studio), departingAt: Self.soon
        )

        let answer = travel.travel(to: Self.studio)
        #expect(answer.minutes == 12, "The fixture's measured figure, not the remembered 25")
        #expect(answer.isMeasured)
        // And the page reads it through the question it always asked.
        #expect(travel.minutes(to: Self.studio) == 12)
    }

    /// The commonest case in a real calendar, and the reason the told number was never demoted.
    @Test("A place that will not geocode falls back silently")
    func aRoomFallsBackToWhatItsOwnerSaid() async {
        let clock = MovingClock(now: Self.now)
        let travel = Self.preferences(clock: clock) { FixtureRouteProvider(dateProvider: clock) }
        travel.remember(minutes: 5, to: "Room 2")

        await travel.enableEstimates()
        await travel.refreshEstimate(to: RoutePlace(name: "Room 2"), departingAt: Self.soon)

        #expect(travel.minutes(to: "Room 2") == 5)
        #expect(!travel.travel(to: "Room 2").isMeasured)
    }

    @Test("A measurement goes stale and the told number comes back")
    func staleMeasurementsAreNotUsed() async {
        let clock = MovingClock(now: Self.now)
        let travel = Self.preferences(clock: clock) { FixtureRouteProvider(dateProvider: clock) }
        travel.remember(minutes: 25, to: Self.studio)

        await travel.enableEstimates()
        await travel.refreshEstimate(to: RoutePlace(name: Self.studio), departingAt: Self.soon)
        #expect(travel.minutes(to: Self.studio) == 12)

        clock.now = Self.now.addingTimeInterval(RouteRules.freshness + 1)
        #expect(travel.minutes(to: Self.studio) == 25, "An hour-old ETA is a guess in a measurement's clothes")
    }

    // MARK: - The switch

    @Test("Nothing is measured until somebody turns it on")
    func measuringIsOffUntilAsked() async {
        let clock = MovingClock(now: Self.now)
        let spy = CountingRouteProvider(clock: clock)
        let travel = Self.preferences(clock: clock) { spy }

        #expect(!travel.isEstimating)
        await travel.refreshEstimate(to: RoutePlace(name: Self.studio), departingAt: Self.soon)

        #expect(spy.asked == 0, "An app that is off must not have asked anybody anything")
        #expect(travel.minutes(to: Self.studio) == TravelRules.defaultMinutes)
    }

    @Test("Turning it off drops what was measured rather than letting it age out")
    func disablingForgetsEverything() async {
        let clock = MovingClock(now: Self.now)
        let travel = Self.preferences(clock: clock) { FixtureRouteProvider(dateProvider: clock) }
        travel.remember(minutes: 25, to: Self.studio)

        await travel.enableEstimates()
        await travel.refreshEstimate(to: RoutePlace(name: Self.studio), departingAt: Self.soon)
        #expect(travel.minutes(to: Self.studio) == 12)

        travel.disableEstimates()

        #expect(!travel.isEstimating)
        #expect(travel.minutes(to: Self.studio) == 25, """
            A page still showing a measured figure after the switch went off would be telling \
            somebody the feature is off while it is visibly still on
            """)
        #expect(travel.rememberedPlaceCount == 1, "Turning measuring off is not forgetting what you were told")
    }

    /// The bug that made the whole feature look broken to the first person who used it.
    ///
    /// `enableEstimates()` was the only thing that ever set `authorization`, so the session where
    /// somebody turned the switch on worked and every session afterwards did not: the app came back
    /// up with the switch on, the permission standing, and `authorization` at its initial
    /// `.notRequested` — measuring nothing, forever, because nothing would ever ask again. It reads
    /// as "I granted location and it still says 15 minutes", which is exactly how it was reported.
    @Test("A relaunch with the switch already on still measures")
    func aRelaunchStillMeasures() async {
        let clock = MovingClock(now: Self.now)
        let defaults = Self.scratchDefaults()

        // The session where somebody turns it on.
        let first = TravelPreferences(defaults: defaults, dateProvider: clock) {
            FixtureRouteProvider(dateProvider: clock)
        }
        await first.enableEstimates()
        #expect(first.isEstimating)

        // The next launch: same preferences on disk, a brand-new object, nobody asked again.
        let second = TravelPreferences(defaults: defaults, dateProvider: clock) {
            FixtureRouteProvider(dateProvider: clock)
        }
        #expect(second.isEstimating, "the switch is remembered")
        #expect(second.authorization == .notRequested, "and nothing has read the standing decision yet")

        await second.refreshEstimate(to: RoutePlace(name: Self.studio), departingAt: Self.soon)

        #expect(second.minutes(to: Self.studio) == 12, """
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

        let granted = await travel.enableEstimates()
        #expect(granted == .denied)

        await travel.refreshEstimate(to: RoutePlace(name: Self.studio), departingAt: Self.soon)
        #expect(travel.minutes(to: Self.studio) == TravelRules.defaultMinutes)
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

        #expect(spy.asked == 1, "A room that does not exist does not start existing on the next scroll")
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

        // Still inside the short delay.
        clock.now = Self.now.addingTimeInterval(60)
        await travel.refreshEstimate(to: place, departingAt: Self.soon)
        #expect(spy.asked == 1)

        clock.now = Self.now.addingTimeInterval(RouteRules.retryDelay(after: .unavailable) + 1)
        await travel.refreshEstimate(to: place, departingAt: Self.soon)
        #expect(spy.asked == 2, "A network that was down comes back; a place that does not exist does not")
    }

    @Test("A fresh answer is not measured again")
    func freshAnswersAreNotRemeasured() async {
        let clock = MovingClock(now: Self.now)
        let spy = CountingRouteProvider(clock: clock, answer: nil)
        let travel = Self.preferences(clock: clock) { spy }
        await travel.enableEstimates()

        let place = RoutePlace(name: Self.studio)
        for _ in 0..<4 {
            await travel.refreshEstimate(to: place, departingAt: Self.soon)
        }
        #expect(spy.asked == 1)

        clock.now = Self.now.addingTimeInterval(RouteRules.freshness + 1)
        await travel.refreshEstimate(to: place, departingAt: Self.soon)
        #expect(spy.asked == 2)
    }

    /// Both ends of the window, because both are the app declining to spend a location read.
    @Test("A journey too far off, or already begun, is not measured")
    func onlyJourneysInTheWindowAreMeasured() async {
        let clock = MovingClock(now: Self.now)
        let spy = CountingRouteProvider(clock: clock)
        let travel = Self.preferences(clock: clock) { spy }
        await travel.enableEstimates()

        let place = RoutePlace(name: Self.studio)
        await travel.refreshEstimate(
            to: place, departingAt: Self.now.addingTimeInterval(RouteRules.horizon + 60)
        )
        await travel.refreshEstimate(
            to: place, departingAt: Self.now.addingTimeInterval(-RouteRules.freshness - 60)
        )

        #expect(spy.asked == 0)
    }

    @Test("Changing how you travel discards answers about the other way")
    func changingTransportClearsWhatWasMeasured() async {
        let clock = MovingClock(now: Self.now)
        let travel = Self.preferences(clock: clock) { FixtureRouteProvider(dateProvider: clock) }

        await travel.enableEstimates()
        await travel.refreshEstimate(to: RoutePlace(name: Self.studio), departingAt: Self.soon)
        #expect(travel.minutes(to: Self.studio) == 12)

        travel.transport = .walking
        #expect(travel.minutes(to: Self.studio) == TravelRules.defaultMinutes,
                "A drive reported as a walk is worse than no answer")

        await travel.refreshEstimate(to: RoutePlace(name: Self.studio), departingAt: Self.soon)
        let answer = travel.travel(to: Self.studio)
        #expect(answer.minutes == 48)
        #expect(answer.isMeasured)
    }

    @Test("Forgetting a place forgets what was measured about it too")
    func forgettingAPlaceForgetsItsMeasurement() async {
        let clock = MovingClock(now: Self.now)
        let travel = Self.preferences(clock: clock) { FixtureRouteProvider(dateProvider: clock) }
        travel.remember(minutes: 25, to: Self.studio)

        await travel.enableEstimates()
        await travel.refreshEstimate(to: RoutePlace(name: Self.studio), departingAt: Self.soon)
        #expect(travel.minutes(to: Self.studio) == 12)

        travel.forget(Self.studio)
        #expect(travel.minutes(to: Self.studio) == TravelRules.defaultMinutes)
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
