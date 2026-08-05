import Foundation

/// Asking the world how long a journey actually takes.
///
/// ### What this stage is, and what ``TravelRules`` still is
/// ``TravelRules`` answers "when do I leave" from a number the user gave. This answers the narrower
/// and much more expensive question of what that number *should* be, by asking a routing service.
/// It does not replace the user's number; it arrives as a better answer to the same question, and
/// when it cannot arrive the told number is still there. That ordering is the whole design — see
/// `TravelPreferences.minutes(to:)`, which is the one place either is read.
///
/// ### The cost, stated plainly
/// A route lookup is a location permission, a network call, and an address leaving the device. Every
/// one of those is a promise this app made about itself, which is why the feature is off until
/// somebody turns it on, and why the thing that crosses the boundary is ``RoutePlace`` — a type with
/// room for a place and nothing else.
public enum RouteRules {
    /// How long a measurement is worth trusting.
    ///
    /// Fifteen minutes. Traffic is the reason there is an upper bound at all: an hour-old ETA is a
    /// guess wearing a measurement's clothes, and presenting it as "12 min" rather than "about
    /// fifteen" is the app being confidently wrong in the one way the told number never is.
    public static let freshness: TimeInterval = 15 * 60

    /// How far ahead a journey is worth measuring.
    ///
    /// Four hours. Beyond that the answer is not knowable — routing services model current traffic,
    /// not Thursday's — so a lookup buys a number that will be wrong, at the price of a location
    /// read. The told number covers everything further out, which is what it was always for.
    public static let horizon: TimeInterval = 4 * 60 * 60

    /// Past which an answer is not believed.
    ///
    /// Eight hours. This is not a cap on long journeys; it is how the app notices that "Room 2"
    /// resolved to a Room 2 on another continent. A geocoder handed a string with no city in it will
    /// find *something* somewhere, and the honest response to a nine-hour drive to a meeting room is
    /// to discard the answer rather than render it.
    public static let implausibleMinutes = 480

    /// Seconds of travel as the minutes a person is told.
    ///
    /// Rounded **up**, always, and never below one. Rounding a ninety-second walk down to a minute is
    /// the app shaving time off somebody's journey to look precise, and the entire value of this
    /// number is that acting on it means arriving.
    public static func minutes(fromSeconds seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 1 }
        return max(1, Int((seconds / 60).rounded(.up)))
    }

    /// Whether a measurement is still recent enough to use.
    public static func isFresh(_ estimate: RouteEstimate, now: Date) -> Bool {
        let age = now.timeIntervalSince(estimate.measuredAt)
        return age >= 0 && age < freshness
    }

    /// Whether this journey is close enough in time to be worth asking about.
    ///
    /// Two refusals, and both are the app declining to spend a location read on nothing: a journey
    /// already begun cannot be planned, and one four hours out cannot be measured.
    public static func isWorthMeasuring(departingAt moment: Date, now: Date) -> Bool {
        let wait = moment.timeIntervalSince(now)
        return wait > -freshness && wait < horizon
    }

    /// Whether an answer is believable enough to show.
    public static func isPlausible(minutes: Int) -> Bool {
        minutes > 0 && minutes <= implausibleMinutes
    }
}

// MARK: - The place

/// Somewhere to go, and the **only** thing that ever reaches a routing service.
///
/// ### Why this is a type rather than two arguments
/// For the reason `EventDraft` is a type: what is absent from it is the guarantee. A route lookup
/// happens against somebody's calendar, and the meeting behind this place has a title, attendees,
/// notes, an organizer and a link — every one of which is a thing a person would mind leaving their
/// phone, and none of which has anywhere to sit here. `RouteSafetyTests` fails if a field is added,
/// which turns "we would never send the title" from a habit into a compile-and-test problem.
///
/// The conversion from an event is ``init(travellingTo:)`` and it is deliberately the only one: a
/// caller cannot assemble a place out of a meeting by hand without noticing they are doing it.
public struct RoutePlace: Sendable, Hashable {
    /// The location string, exactly as the calendar holds it. This is what gets geocoded.
    public var name: String

    /// The coordinate, when the organizer set a real place rather than typing one.
    ///
    /// Carried so a place that is already resolved is not geocoded again — a search for "Ristorante
    /// Da Enzo" is both slower and more likely to be wrong than the point EventKit already holds.
    /// Optional because most events have a string and nothing else.
    public var latitude: Double?
    public var longitude: Double?

    public init(name: String, latitude: Double? = nil, longitude: Double? = nil) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.latitude = latitude
        self.longitude = longitude
    }

    /// The place an event is at, or `nil` when it is not somewhere you go.
    ///
    /// Delegates the question to ``TravelRules/isJourney(to:)`` rather than re-deciding it, so a
    /// video call cannot become a route lookup by way of a second opinion. Everything else about the
    /// event is dropped here, at the one boundary, in one place somebody can read.
    public init?(travellingTo event: CalendarEventSummary) {
        guard TravelRules.isJourney(to: event), let location = event.locationName else { return nil }
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.init(name: trimmed, latitude: event.locationLatitude, longitude: event.locationLongitude)
    }

    /// Whether this place already knows where it is.
    public var hasCoordinate: Bool { latitude != nil && longitude != nil }

    /// The key this place is remembered and cached under. The same key the told number uses, so a
    /// measurement and an answer are about the same room.
    public var key: String { TravelRules.placeKey(for: name) }
}

/// How the journey is made.
///
/// Offered because the feature is wrong without it: a fifteen-minute drive and a fifteen-minute walk
/// are different meetings, and an app that assumes a car tells somebody who takes the train to leave
/// far too late. Three options rather than every mode a map knows, because these are the three that
/// change the answer.
public enum RouteTransport: String, Sendable, Hashable, CaseIterable, Codable {
    case driving
    case walking
    case transit

    public var label: String {
        switch self {
        case .driving: "Driving"
        case .walking: "Walking"
        case .transit: "Transit"
        }
    }

    /// The word the travel line uses — "12 min drive". Lower case, because it sits mid-sentence.
    public var journeyNoun: String {
        switch self {
        case .driving: "drive"
        case .walking: "walk"
        case .transit: "journey"
        }
    }

    public var symbolName: String {
        switch self {
        case .driving: "car"
        case .walking: "figure.walk"
        case .transit: "tram"
        }
    }
}

// MARK: - The answer

/// What a routing service said, and when it said it.
public struct RouteEstimate: Sendable, Hashable {
    /// The place this is about, as ``RoutePlace/key``.
    public var placeKey: String

    /// How long the journey takes, rounded the generous way. See ``RouteRules/minutes(fromSeconds:)``.
    public var minutes: Int

    /// How the journey was assumed to be made, so a walking answer is never read as a driving one.
    public var transport: RouteTransport

    /// When this was measured. The reason a stale answer can be recognised rather than trusted.
    public var measuredAt: Date

    public init(placeKey: String, minutes: Int, transport: RouteTransport, measuredAt: Date) {
        self.placeKey = placeKey
        self.minutes = minutes
        self.transport = transport
        self.measuredAt = measuredAt
    }
}

/// Why there is no answer.
///
/// Every case is something a person might need telling, which is why each explains itself in
/// ordinary words rather than being logged and swallowed. None of them is exceptional: a place that
/// does not geocode is the *normal* outcome for "Room 2", and the told number covering it is the
/// feature working rather than failing.
public enum RouteFailure: Sendable, Hashable {
    /// Location access has not been granted, or the feature is off. Nothing was attempted.
    case notAuthorized

    /// The location string did not resolve to anywhere. Ordinary, and usually right.
    case placeNotFound

    /// Somewhere real, with no route to it by the chosen means.
    case noRoute

    /// An answer arrived and was not believed. See ``RouteRules/implausibleMinutes``.
    case implausible

    /// No routing service on this device, or the network is down.
    case unavailable

    case failed(String)

    /// What to say, or `nil` when the page should simply keep the told number and stay quiet.
    ///
    /// Most of these return `nil` on purpose. A meeting room that does not geocode must not put an
    /// error under somebody's calendar every morning; the user's own number is already the answer,
    /// and saying "we could not measure Room 2" is the app narrating its own plumbing.
    public var explanation: String? {
        switch self {
        case .notAuthorized:
            "Elephruit does not have permission to use your location."
        case .placeNotFound, .noRoute, .implausible, .unavailable:
            nil
        case .failed(let reason):
            reason
        }
    }
}

/// How long a journey is expected to take, and where that number came from.
///
/// The page reads this rather than a bare `Int` so it can say "15 min" about a number somebody gave
/// and "12 min drive" about one that was measured. Presenting the two identically would be the app
/// borrowing the authority of a measurement for a guess.
public enum TravelNumber: Sendable, Hashable {
    /// What the user said, or the default nobody has changed.
    case told(Int)

    /// What a routing service said, and when.
    case measured(Int, transport: RouteTransport, at: Date)

    public var minutes: Int {
        switch self {
        case .told(let minutes): minutes
        case .measured(let minutes, _, _): minutes
        }
    }

    public var isMeasured: Bool {
        if case .measured = self { return true }
        return false
    }
}
