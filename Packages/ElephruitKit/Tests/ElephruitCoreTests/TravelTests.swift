import ElephruitCore
import Foundation
import Testing

/// Which entries are somewhere you have to go, and when to set off for them.
///
/// The whole feature is a subtraction, so what is worth testing is the *refusals* — the entries this
/// must not put a "leave by" line under. Each one is a way an eager version tells somebody to set
/// off for a video call, or for a four-day trip, at a quarter to.
@Suite("Getting there")
struct TravelTests {
    static let start = Date(timeIntervalSinceReferenceDate: 757_425_600)

    static func event(
        _ title: String,
        location: String? = nil,
        url: URL? = nil,
        notes: String? = nil,
        allDay: Bool = false,
        status: EventStatus = .confirmed
    ) -> CalendarEventSummary {
        CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: title),
            title: title,
            startAt: start,
            endAt: start.addingTimeInterval(3_600),
            isAllDay: allDay,
            locationName: location,
            notes: notes,
            url: url,
            status: status
        )
    }

    @Test("A meeting in a room is somewhere to go")
    func aPlaceIsAJourney() {
        #expect(TravelRules.isJourney(to: Self.event("Design review", location: "Room 2")))
        #expect(TravelRules.isJourney(to: Self.event("Lunch", location: "12 Rue Oberkampf, Paris")))
    }

    @Test("A video call is not, however the link got into the location field")
    func aLinkIsNotAPlace() {
        // Half the world puts the link where the room goes. A "leave by" line under one of those is
        // the app telling somebody to set off for their own desk.
        #expect(!TravelRules.isJourney(to: Self.event("Sync", location: "https://zoom.us/j/123")))
        #expect(!TravelRules.isJourney(
            to: Self.event("Sync", location: "Room 2", url: URL(string: "https://meet.google.com/abc"))
        ))
    }

    @Test("Nothing to travel to is not a journey")
    func theRefusals() {
        #expect(!TravelRules.isJourney(to: Self.event("Focus")))
        #expect(!TravelRules.isJourney(to: Self.event("Focus", location: "   ")))
        // A trip to Berlin is not something you leave for at a quarter to.
        #expect(!TravelRules.isJourney(to: Self.event("Berlin", location: "Berlin", allDay: true)))
        #expect(!TravelRules.isJourney(to: Self.event("Off", location: "Room 2", status: .cancelled)))
    }

    @Test("Leaving is the start, minus what the user said it takes")
    func leavingIsASubtraction() {
        let event = Self.event("Design review", location: "Room 2")
        #expect(TravelRules.leaveBy(event, minutes: 15) == Self.start.addingTimeInterval(-900))
        // Never zero, and never negative: a block with no length is not a plan.
        #expect(TravelRules.leaveBy(event, minutes: 0) < event.startAt)
        #expect(TravelRules.leaveBy(event, minutes: -30) < event.startAt)
    }

    @Test("A moment already past is not worth saying")
    func lateIsNotWorthSaying() {
        let event = Self.event("Design review", location: "Room 2")
        let leaving = TravelRules.leaveBy(event, minutes: 15)

        #expect(TravelRules.isWorthSaying(event, minutes: 15, now: leaving.addingTimeInterval(-60)))
        // "Leave by 9:45" under a meeting you are already late for is a reproach, not a plan.
        #expect(!TravelRules.isWorthSaying(event, minutes: 15, now: leaving.addingTimeInterval(60)))
    }

    @Test("One room is one room, however it was typed")
    func placesAreRememberedLoosely() {
        let key = TravelRules.placeKey(for: "Room 2")
        #expect(TravelRules.placeKey(for: " room 2 ") == key)
        #expect(TravelRules.placeKey(for: "ROOM  2") == key)
        #expect(TravelRules.placeKey(for: "Room 3") != key)
    }

    @Test("A travel block is named after the place, never the meeting")
    func blocksAreNamedAfterThePlace() {
        // The meeting's title may be somebody's name, or a subject they would rather not publish to
        // a shared calendar twice.
        #expect(TravelRules.blockTitle(to: "Room 2 ") == "Travel to Room 2")
    }

    @Test("The line says both halves of the answer")
    func theLineSaysWhenAndHowLong() {
        let summary = TravelRules.summary(leavingAt: Self.start, minutes: 20)
        #expect(summary.hasPrefix("Leave by "))
        #expect(summary.hasSuffix("20m"))
    }
}
