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
    /// When a journey stops being a plan and starts being traffic.
    ///
    /// Ninety minutes out, an accident on the route is something you can still act on, so this is
    /// where re-checking earns its cost. Further out it does not: the difference between the
    /// twenty-two minutes it takes today and the twenty-four it will take on Thursday is not worth a
    /// network request an hour.
    public static let closeIn: TimeInterval = 90 * 60

    /// How often to re-check inside ``closeIn``.
    public static let closeInFreshness: TimeInterval = 15 * 60

    /// How long an answer for a journey later today is trusted.
    public static let sameDayFreshness: TimeInterval = 60 * 60

    /// Past which an answer is not believed.
    ///
    /// Eight hours. Two very different things land here and get the same treatment, which is fine
    /// because the app cannot tell them apart from the answer and does not need to:
    ///
    /// - **"Room 2" resolved to a Room 2 on another continent.** A geocoder handed a string with no
    ///   city in it will find *something*, somewhere.
    /// - **You are not there yet.** A meeting booked in Detroit while you are in Minnesota is a true
    ///   ten-hour answer to the wrong question, because the origin is wherever you happen to be
    ///   standing when you book it.
    ///
    /// Both mean "do not render this", and both come right on the day — which is why
    /// ``retryAt(after:now:calendar:)`` sends them to tomorrow rather than forgetting them.
    ///
    /// One casualty worth naming: a genuinely long drive somebody does intend to make is suppressed
    /// too. That reader sets the number themselves, once, and it is remembered.
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

    /// When an answer measured now, for a journey departing at `moment`, stops being trusted.
    ///
    /// ### Why this is a function of the departure and not a constant
    /// Because the three moments a journey is worth re-checking are all really one rule. A flat
    /// fifteen minutes re-measured a meeting nine days out as eagerly as one you are about to leave
    /// for, and a fixed lookahead horizon refused to measure the nine-day one at all — which is how
    /// a meeting booked for next week showed a number nobody had earned.
    ///
    /// - **More than a day out**: good until the small hours. The next time the page is opened is a
    ///   different day, from a possibly different city, and that is exactly when it should be asked
    ///   again — so the start-of-day re-measure is this expiry rather than a scheduler.
    /// - **Later today**: an hour, or until the journey comes within ``closeIn``, whichever is
    ///   sooner. The clamp is what makes the last quiet answer expire precisely as the busy window
    ///   opens, with no separate trigger.
    /// - **Within ``closeIn``**: fifteen minutes, because now an accident is something you can act on.
    ///
    /// Nothing here decides *whether* to measure. A journey is measured whenever the page draws it
    /// and the answer on hand has expired; MapKit is given the real departure date and models the
    /// traffic it expects then, so there is no distance into the future this refuses to ask about.
    public static func expiry(measuredAt now: Date, departingAt moment: Date, calendar: Calendar) -> Date {
        let wait = moment.timeIntervalSince(now)

        if wait <= closeIn { return now.addingTimeInterval(closeInFreshness) }

        if calendar.isDate(moment, inSameDayAs: now) {
            let untilCloseIn = moment.addingTimeInterval(-closeIn)
            return min(now.addingTimeInterval(sameDayFreshness), untilCloseIn)
        }

        // The start of the next day, so the first look tomorrow measures again from wherever the
        // reader has woken up. Falls back to the same-day window if the calendar cannot answer,
        // which is a shorter life rather than a longer one.
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        return tomorrow ?? now.addingTimeInterval(sameDayFreshness)
    }

    /// Whether an answer is still worth using.
    public static func isFresh(_ estimate: RouteEstimate, now: Date) -> Bool {
        now >= estimate.measuredAt && now < estimate.expiresAt
    }

    /// Whether a journey can still be planned at all.
    ///
    /// One refusal now, where there used to be two: a departure already well past cannot be planned.
    /// The lookahead limit is gone — see ``expiry(measuredAt:departingAt:calendar:)``.
    public static func isWorthMeasuring(departingAt moment: Date, now: Date) -> Bool {
        moment.timeIntervalSince(now) > -closeInFreshness
    }

    /// Whether an answer is believable enough to show.
    public static func isPlausible(minutes: Int) -> Bool {
        minutes > 0 && minutes <= implausibleMinutes
    }

    /// How long to leave a refusal alone before asking again.
    ///
    /// ### Why a refusal must be remembered at all
    /// Because without this the feature geocodes "Room 2" every time the page redraws. A route that
    /// failed still costs a network call, a `List` re-renders on every scroll, and the place that
    /// fails is precisely the place that appears in somebody's calendar five times a week. A cache
    /// of successes alone would leave the commonest case — the one that never succeeds — asking
    /// forever.
    ///
    /// When it depends on what kind of "no" it was, because they are genuinely different claims:
    ///
    /// - **A place that does not exist** is a fact about the string somebody typed. "Room 2" will
    ///   not start geocoding this afternoon, so it is left alone for the rest of the day.
    /// - **No route, or an answer too long to believe** is a fact about *where the reader is now* as
    ///   much as about the place. Both come right the morning you are in the right city, so both
    ///   retire at the same moment a stale answer does: tomorrow.
    /// - **A service that was unreachable** is a fact about the moment. Five minutes.
    ///
    /// ``RouteFailure/notAuthorized`` is absent on purpose: that is not a refusal to cache but a
    /// switch to respect, and it is the caller's business rather than a timer's. `nil` means "do not
    /// remember this at all".
    public static func retryAt(after failure: RouteFailure, now: Date, calendar: Calendar) -> Date? {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))

        switch failure {
        case .placeNotFound, .noRoute, .implausible:
            return tomorrow ?? now.addingTimeInterval(sameDayFreshness)
        case .unavailable, .failed:
            return now.addingTimeInterval(5 * 60)
        case .notAuthorized:
            return nil
        }
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

    /// When it stops being trusted, decided by how far off the journey was when it was taken.
    ///
    /// Carried on the answer rather than recomputed at every read, because the departure it was
    /// measured for is not something the reader has to hand — and because an answer that knows its
    /// own life can be sorted, logged and reasoned about without the journey beside it.
    public var expiresAt: Date

    /// - Parameter expiresAt: omitted by a routing provider, which measures a journey without
    ///   knowing anything about the day it belongs to. The default is the moment of measurement —
    ///   that is, **already expired** — so a caller that forgets to set a life re-measures rather
    ///   than trusting an answer forever. The failure that costs a network request is much the
    ///   better one to fall into.
    public init(
        placeKey: String,
        minutes: Int,
        transport: RouteTransport,
        measuredAt: Date,
        expiresAt: Date? = nil
    ) {
        self.placeKey = placeKey
        self.minutes = minutes
        self.transport = transport
        self.measuredAt = measuredAt
        self.expiresAt = expiresAt ?? measuredAt
    }
}

/// Why there is no answer.
///
/// Every case is something a person might need telling, which is why each explains itself in
/// ordinary words rather than being logged and swallowed. None of them is exceptional: a place that
/// does not geocode is the *normal* outcome for "Room 2", and the told number covering it is the
/// feature working rather than failing.
public enum RouteFailure: Error, Sendable, Hashable {
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

/// How long a journey takes, and who says so.
///
/// ### Why there is a case for "nobody knows"
/// Because the first version of this had two cases and a fallback, and the fallback was a lie. A
/// journey nobody had measured and nobody had answered for still produced a number — the default
/// fifteen minutes — and the page drew it in the same type, the same weight and the same words as a
/// measurement. The first person to use it read "leave by 5:45" off a meeting the app had never
/// looked up, and asked, reasonably, how it knew.
///
/// So the default is not a travel time. It is the starting position of a picker, and it lives where
/// somebody is actively choosing a number rather than being handed one. What reaches the page is
/// either measured, or told, or **absent**.
public enum TravelAnswer: Sendable, Hashable {
    /// What the user said about *this place*. Not a default, not an assumption: a number they
    /// settled on and the app remembered.
    case told(Int)

    /// What a routing service said, and when.
    case measured(Int, transport: RouteTransport, at: Date)

    /// Nobody has earned a number. Carries the reason when there was one, and `nil` when the journey
    /// has simply not been asked about yet.
    case unknown(RouteFailure?)

    /// The number, when there is one. Deliberately optional: a caller that wants to render a time
    /// has to say what it will do without one.
    public var minutes: Int? {
        switch self {
        case .told(let minutes): minutes
        case .measured(let minutes, _, _): minutes
        case .unknown: nil
        }
    }

    public var isMeasured: Bool {
        if case .measured = self { return true }
        return false
    }

    /// Whether the page should offer to sort this out rather than stay quiet.
    ///
    /// The distinction the reader actually cares about is "there is nothing to say" against "I tried
    /// and could not work it out". A meeting room that will not geocode is the first: you are
    /// already in the building, and a prompt under every such meeting is noise. No route, or an
    /// answer too long to believe — the Detroit-from-Minnesota case — is the second, and it is worth
    /// a word, because the reader can fix it in a way the app cannot.
    ///
    /// A service that was merely unreachable says nothing either: it will retry in five minutes,
    /// and an error that heals itself should never have been shown.
    public var invitesAnAnswer: Bool {
        guard case .unknown(let failure) = self else { return false }
        switch failure {
        case .noRoute, .implausible: return true
        case .placeNotFound, .unavailable, .failed, .notAuthorized, nil: return false
        }
    }
}
