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

    static let calendar = Calendar(identifier: .gregorian)

    private static func expiry(departingIn seconds: TimeInterval) -> Date {
        RouteRules.expiry(
            measuredAt: now, departingAt: now.addingTimeInterval(seconds), calendar: calendar
        )
    }

    @Test("An answer goes stale")
    func estimatesExpire() {
        let estimate = RouteEstimate(
            placeKey: "room 2", minutes: 12, transport: .driving,
            measuredAt: Self.now, expiresAt: Self.now.addingTimeInterval(900)
        )

        #expect(RouteRules.isFresh(estimate, now: Self.now))
        #expect(RouteRules.isFresh(estimate, now: Self.now.addingTimeInterval(899)))
        #expect(!RouteRules.isFresh(estimate, now: Self.now.addingTimeInterval(900)))

        // A measurement from the future is a clock that moved, not a fresh answer.
        #expect(!RouteRules.isFresh(estimate, now: Self.now.addingTimeInterval(-60)))
    }

    /// An answer given no life of its own is already dead, which fails toward asking again.
    @Test("A measurement nobody dated expires immediately")
    func anUndatedEstimateIsNeverFresh() {
        let raw = RouteEstimate(
            placeKey: "room 2", minutes: 12, transport: .driving, measuredAt: Self.now
        )
        #expect(!RouteRules.isFresh(raw, now: Self.now))
    }

    /// The rule that replaced both the flat freshness and the lookahead horizon.
    @Test("How long an answer lives depends on how far off the journey is")
    func expiryFollowsTheDeparture() {
        // Inside the busy window: fifteen minutes, because now an accident is actionable.
        #expect(Self.expiry(departingIn: 30 * 60) == Self.now.addingTimeInterval(15 * 60))
        #expect(Self.expiry(departingIn: RouteRules.closeIn) == Self.now.addingTimeInterval(15 * 60))

        // Later today, but far enough out that the answer is quiet — and clamped so it dies exactly
        // as the busy window opens rather than a moment after.
        let threeHours = Self.expiry(departingIn: 3 * 60 * 60)
        #expect(threeHours == Self.now.addingTimeInterval(RouteRules.sameDayFreshness))

        let twoHours = Self.expiry(departingIn: 2 * 60 * 60)
        #expect(twoHours == Self.now.addingTimeInterval(2 * 60 * 60 - RouteRules.closeIn),
                "the last quiet answer must expire as the busy window opens, with no second trigger")
    }

    /// The Detroit case: booked from another state, and right the morning you are in the right one.
    @Test("An answer for another day dies at that day's end")
    func tomorrowsJourneyExpiresTonight() {
        let nextWeek = Self.expiry(departingIn: 7 * 24 * 60 * 60)
        let tomorrow = Self.calendar.date(
            byAdding: .day, value: 1, to: Self.calendar.startOfDay(for: Self.now)
        )

        #expect(nextWeek == tomorrow, """
            The first look tomorrow must measure again, from wherever the reader woke up — which is \
            the start-of-day re-measure, expressed as an expiry rather than a scheduler.
            """)
    }

    /// One refusal now, where there used to be two. The lookahead limit is gone: MapKit is given the
    /// real departure date and models the traffic it expects then, so a meeting next week is a fair
    /// question — and refusing to ask was what left a number nobody had earned on the page.
    @Test("Only a journey already gone is past measuring")
    func measuringRefusesOnlyThePast() {
        #expect(RouteRules.isWorthMeasuring(
            departingAt: Self.now.addingTimeInterval(30 * 60), now: Self.now
        ))
        #expect(RouteRules.isWorthMeasuring(
            departingAt: Self.now.addingTimeInterval(9 * 24 * 60 * 60), now: Self.now
        ), "a journey next week is measurable; MapKit is told when it departs")

        let longGone = Self.now.addingTimeInterval(-RouteRules.closeInFreshness - 60)
        #expect(!RouteRules.isWorthMeasuring(departingAt: longGone, now: Self.now),
                "A journey already begun cannot be planned")
    }

    /// Two kinds of "no", retiring at the moments they actually stop being true.
    @Test("A refusal is remembered for as long as it is likely to hold")
    func refusalsRetireSensibly() {
        let tomorrow = Self.calendar.date(
            byAdding: .day, value: 1, to: Self.calendar.startOfDay(for: Self.now)
        )

        for failure in [RouteFailure.placeNotFound, .noRoute, .implausible] {
            #expect(
                RouteRules.retryAt(after: failure, now: Self.now, calendar: Self.calendar) == tomorrow,
                "\(failure) comes right on the day you are in the right city, not before"
            )
        }

        #expect(
            RouteRules.retryAt(after: .unavailable, now: Self.now, calendar: Self.calendar)
                == Self.now.addingTimeInterval(5 * 60),
            "a network that was down comes back"
        )

        #expect(
            RouteRules.retryAt(after: .notAuthorized, now: Self.now, calendar: Self.calendar) == nil,
            "a switch to respect is not a refusal to time"
        )
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
        #expect(measured?.hasSuffix("drive") == true)
        #expect(measured != told)

        let walked = TravelRules.summary(
            leavingAt: moment, travel: .measured(12, transport: .walking, at: moment)
        )
        #expect(walked?.hasSuffix("walk") == true,
                "A walk and a drive of the same length are different meetings")
    }

    @Test("A number knows where it came from")
    func travelNumbersReportTheirSource() {
        #expect(TravelAnswer.told(15).minutes == 15)
        #expect(!TravelAnswer.told(15).isMeasured)
        #expect(TravelAnswer.measured(12, transport: .transit, at: Self.now).minutes == 12)
        #expect(TravelAnswer.measured(12, transport: .transit, at: Self.now).isMeasured)
    }

    /// The case that exists because its absence produced a number nobody had earned.
    @Test("An answer nobody has is an answer, not a default")
    func anUnknownAnswerHasNoNumber() {
        #expect(TravelAnswer.unknown(nil).minutes == nil)
        #expect(TravelAnswer.unknown(.placeNotFound).minutes == nil)
        #expect(!TravelAnswer.unknown(nil).isMeasured)

        // And there is no sentence for it, so a caller cannot render one by accident.
        #expect(TravelRules.summary(leavingAt: Self.now, travel: .unknown(nil)) == nil)
    }

    /// "Nothing to say" against "I tried and could not work it out" — the distinction the reader
    /// actually cares about, and the only thing that decides between silence and an offer.
    @Test("Only a failure the reader can settle invites them to")
    func onlySomeFailuresAskForHelp() {
        #expect(TravelAnswer.unknown(.noRoute).invitesAnAnswer)
        #expect(TravelAnswer.unknown(.implausible).invitesAnAnswer,
                "booked in Detroit from Minnesota: worth a word, because they can fix it and we cannot")

        #expect(!TravelAnswer.unknown(.placeNotFound).invitesAnAnswer,
                "a meeting room does not geocode and does not need to — you are in the building")
        #expect(!TravelAnswer.unknown(.unavailable).invitesAnAnswer,
                "an error that heals itself in five minutes should never have been shown")
        #expect(!TravelAnswer.unknown(nil).invitesAnAnswer, "nothing has been asked yet")
        #expect(!TravelAnswer.told(15).invitesAnAnswer)
        #expect(!TravelAnswer.measured(12, transport: .driving, at: Self.now).invitesAnAnswer)
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
