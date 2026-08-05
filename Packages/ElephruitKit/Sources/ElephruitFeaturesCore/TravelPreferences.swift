import ElephruitCore
import Foundation
import Observation

/// How long the user says it takes to get places.
///
/// ### Why the app never guesses this
/// Because the alternative is a route lookup, and a route lookup is a location permission, a network
/// call and somebody's whereabouts leaving the device. Every one of those is a promise this app has
/// made about itself, and none of them is worth "twelve minutes" instead of "fifteen".
///
/// So the number comes from the person, once, and is then remembered *per place*: the second meeting
/// in Room 2 already knows, and the first trip to an address only has to be answered once. Nothing
/// here is a claim about the world — it is a note of what somebody told the app about their own
/// journeys, which is why it cannot be wrong in a way they cannot correct.
///
/// Per-device on purpose. How long it takes you to reach the office is a fact about where you live,
/// not about your library, and syncing it would put one household's commute on another's phone.
@Observable
@MainActor
public final class TravelPreferences {
    @ObservationIgnored private let defaults: UserDefaults

    private static let defaultKey = "travel.defaultMinutes"
    private static let placesKey = "travel.minutesByPlace"

    /// The buffer used for a place nobody has answered for yet.
    public var defaultMinutes: Int {
        didSet {
            guard defaultMinutes != oldValue else { return }
            defaults.set(defaultMinutes, forKey: Self.defaultKey)
        }
    }

    /// What each place has been answered with, keyed by ``TravelRules/placeKey(for:)``.
    private var minutesByPlace: [String: Int] {
        didSet {
            guard minutesByPlace != oldValue else { return }
            defaults.set(minutesByPlace, forKey: Self.placesKey)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let stored = defaults.integer(forKey: Self.defaultKey)
        self.defaultMinutes = stored > 0 ? stored : TravelRules.defaultMinutes
        self.minutesByPlace = defaults.dictionary(forKey: Self.placesKey) as? [String: Int] ?? [:]
    }

    /// How long to allow for a given place.
    public func minutes(to location: String?) -> Int {
        guard let location, case let key = TravelRules.placeKey(for: location), !key.isEmpty,
              let remembered = minutesByPlace[key]
        else { return defaultMinutes }
        return remembered
    }

    /// Remembers what somebody actually allowed for a place.
    ///
    /// Written when a travel block is *created*, not while a picker is being scrolled: the number
    /// somebody settled on is the answer, and every number they passed on the way to it is not.
    public func remember(minutes: Int, to location: String?) {
        guard let location, case let key = TravelRules.placeKey(for: location), !key.isEmpty,
              minutes > 0
        else { return }
        minutesByPlace[key] = minutes
    }

    /// Forgets one place, for when a journey changes — a move, a new office.
    public func forget(_ location: String?) {
        guard let location, case let key = TravelRules.placeKey(for: location), !key.isEmpty
        else { return }
        minutesByPlace.removeValue(forKey: key)
    }

    /// How many places have been answered for, which is the only thing Settings needs to say about
    /// them: a list of every room somebody has ever been to is a screen nobody asked for.
    public var rememberedPlaceCount: Int { minutesByPlace.count }

    public func forgetAllPlaces() {
        minutesByPlace = [:]
    }
}
