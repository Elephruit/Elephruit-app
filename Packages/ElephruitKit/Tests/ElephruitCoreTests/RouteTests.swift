import ElephruitCore
import Foundation
import Testing

/// What a route lookup is allowed to ask, believe, and be trusted about.
///
/// The arithmetic here is small; the refusals are the feature. Each test below is a way an eager
/// version of this spends a location read on nothing, or renders an answer it should have thrown
/// away — and the one that matters most is ``aPlaceCarriesOnlyThePlace``, which is the whole reason
/// ``RoutePlace`` is a type instead of two arguments.
@Suite("Routes")
struct RouteTests {
    static let now = Date(timeIntervalSinceReferenceDate: 757_425_600)

    static func event(
        _ title: String,
        location: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        notes: String? = nil,
        allDay: Bool = false,
        status: EventStatus = .confirmed
    ) -> CalendarEventSummary {
        CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: title),
            title: title,
            startAt: now.addingTimeInterval(3_600),
            endAt: now.addingTimeInterval(7_200),
            isAllDay: allDay,
            locationName: location,
            locationLatitude: latitude,
            locationLongitude: longitude,
            notes: notes,
            status: status,
            attendees: [EventAttendee(name: "Ada Lovelace", emailAddress: "ada@example.com")]
        )
    }

    // MARK: - What crosses the boundary

    /// The one test that is really about privacy rather than behaviour.
    ///
    /// A place is built from an event that has a title, a note, an attendee and an organizer. None
    /// of them can survive the conversion, because the type they would have to survive into has no
    /// room for them. If this ever fails it is because somebody widened `RoutePlace`, which is
    /// exactly the moment the question is worth asking out loud.
    @Test("A place carries the place and nothing else about the meeting")
    func aPlaceCarriesOnlyThePlace() throws {
        let meeting = Self.event(
            "Divorce settlement with Ada",
            location: "12 Rue Oberkampf, Paris",
            notes: "Do not mention the house",
        )
        let place = try #require(RoutePlace(travellingTo: meeting))

        #expect(place.name == "12 Rue Oberkampf, Paris")
        // Not an assertion about the fields being absent — they cannot be present. This asserts the
        // only thing left to get wrong: that the location itself was not quietly replaced by
        // something more useful to a geocoder and more revealing to whoever reads the query.
        #expect(!place.name.contains("Ada"))
        #expect(!place.name.contains("Divorce"))
        #expect(!place.name.contains("house"))
    }

    @Test("A resolved place is not geocoded again")
    func aResolvedPlaceCarriesItsCoordinate() throws {
        let place = try #require(RoutePlace(travellingTo: Self.event(
            "Lunch", location: "Ristorante Da Enzo", latitude: 41.888, longitude: 12.478
        )))
        #expect(place.hasCoordinate)
        #expect(place.latitude == 41.888)

        let typed = try #require(RoutePlace(travellingTo: Self.event("Lunch", location: "Room 2")))
        #expect(!typed.hasCoordinate, "Most events have a line of text and nothing else")
    }

    /// The refusals are inherited rather than re-decided, so a video call cannot become a route
    /// lookup by way of a second opinion about what a journey is.
    @Test("Nothing you do not travel to becomes a place")
    func onlyJourneysBecomePlaces() {
        #expect(RoutePlace(travellingTo: Self.event("Sync", location: "https://zoom.us/j/123")) == nil)
        #expect(RoutePlace(travellingTo: Self.event("Focus")) == nil)
        #expect(RoutePlace(travellingTo: Self.event("Focus", location: "   ")) == nil)
        #expect(RoutePlace(travellingTo: Self.event("Berlin", location: "Berlin", allDay: true)) == nil)
        #expect(RoutePlace(travellingTo: Self.event("Off", location: "Room 2", status: .cancelled)) == nil)
    }

    @Test("A place is keyed the same way a told number is")
    func aPlaceSharesTheTravelKey() {
        // Same key, or a measurement and the number somebody gave are about different rooms.
        #expect(RoutePlace(name: " ROOM  2 ").key == TravelRules.placeKey(for: "Room 2"))
    }

    // MARK: - The arithmetic

    /// Rounding up is not a rounding preference, it is the difference between arriving and not.
    @Test("Seconds become minutes the generous way")
    func secondsRoundUp() {
        #expect(RouteRules.minutes(fromSeconds: 90) == 2)
        #expect(RouteRules.minutes(fromSeconds: 60) == 1)
        #expect(RouteRules.minutes(fromSeconds: 61) == 2)
        #expect(RouteRules.minutes(fromSeconds: 1_800) == 30)

        // A journey of no time is still a journey somebody has to make.
        #expect(RouteRules.minutes(fromSeconds: 0) == 1)
        #expect(RouteRules.minutes(fromSeconds: -10) == 1)
        #expect(RouteRules.minutes(fromSeconds: .infinity) == 1)
        #expect(RouteRules.minutes(fromSeconds: .nan) == 1)
    }

    @Test("An answer goes stale")
    func estimatesExpire() {
        let estimate = RouteEstimate(
            placeKey: "room 2", minutes: 12, transport: .driving, measuredAt: Self.now
        )

        #expect(RouteRules.isFresh(estimate, now: Self.now))
        #expect(RouteRules.isFresh(estimate, now: Self.now.addingTimeInterval(RouteRules.freshness - 1)))
        #expect(!RouteRules.isFresh(estimate, now: Self.now.addingTimeInterval(RouteRules.freshness)))

        // A measurement from the future is a clock that moved, not a fresh answer.
        #expect(!RouteRules.isFresh(estimate, now: Self.now.addingTimeInterval(-60)))
    }

    /// Both ends of the window, because both are the app declining to spend a location read.
    @Test("Only a journey soon is worth measuring")
    func measuringHasAWindow() {
        let soon = Self.now.addingTimeInterval(30 * 60)
        #expect(RouteRules.isWorthMeasuring(departingAt: soon, now: Self.now))

        let thursday = Self.now.addingTimeInterval(RouteRules.horizon + 60)
        #expect(!RouteRules.isWorthMeasuring(departingAt: thursday, now: Self.now),
                "Traffic four hours out is not knowable, so the lookup buys a number that will be wrong")

        let longGone = Self.now.addingTimeInterval(-RouteRules.freshness - 60)
        #expect(!RouteRules.isWorthMeasuring(departingAt: longGone, now: Self.now),
                "A journey already begun cannot be planned")
    }

    /// The failure mode this exists for: a geocoder handed a string with no city in it finds a
    /// Room 2 somewhere, and confidently reports a nine-hour drive to it.
    @Test("An implausible answer is discarded rather than rendered")
    func absurdAnswersAreRefused() {
        #expect(RouteRules.isPlausible(minutes: 12))
        #expect(RouteRules.isPlausible(minutes: RouteRules.implausibleMinutes))
        #expect(!RouteRules.isPlausible(minutes: RouteRules.implausibleMinutes + 1))
        #expect(!RouteRules.isPlausible(minutes: 0))
        #expect(!RouteRules.isPlausible(minutes: -5))
    }

    // MARK: - What the page says

    @Test("A measured number says it was measured")
    func measuredNumbersLookDifferent() {
        let moment = Self.now
        let told = TravelRules.summary(leavingAt: moment, travel: .told(15))
        let measured = TravelRules.summary(
            leavingAt: moment, travel: .measured(12, transport: .driving, at: moment)
        )

        #expect(told == TravelRules.summary(leavingAt: moment, minutes: 15),
                "A told number reads exactly as it always did")
        #expect(measured.hasSuffix("drive"))
        #expect(measured != told)

        let walked = TravelRules.summary(
            leavingAt: moment, travel: .measured(12, transport: .walking, at: moment)
        )
        #expect(walked.hasSuffix("walk"), "A walk and a drive of the same length are different meetings")
    }

    @Test("A number knows where it came from")
    func travelNumbersReportTheirSource() {
        #expect(TravelNumber.told(15).minutes == 15)
        #expect(!TravelNumber.told(15).isMeasured)
        #expect(TravelNumber.measured(12, transport: .transit, at: Self.now).minutes == 12)
        #expect(TravelNumber.measured(12, transport: .transit, at: Self.now).isMeasured)
    }

    /// Silence is the design, not an oversight. A meeting room that does not geocode must not put an
    /// error under somebody's calendar every morning — the told number already covered it.
    @Test("Only a refusal the user can act on says anything")
    func ordinaryFailuresStayQuiet() {
        #expect(RouteFailure.placeNotFound.explanation == nil)
        #expect(RouteFailure.noRoute.explanation == nil)
        #expect(RouteFailure.implausible.explanation == nil)
        #expect(RouteFailure.unavailable.explanation == nil)

        #expect(RouteFailure.notAuthorized.explanation?.isEmpty == false,
                "A permission the user can grant is the one thing worth telling them about")
        #expect(RouteFailure.failed("Maps is unreachable").explanation == "Maps is unreachable")
    }
}
