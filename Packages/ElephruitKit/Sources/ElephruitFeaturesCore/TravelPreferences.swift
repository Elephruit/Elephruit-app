import ElephruitCore
import ElephruitIntegrations
import Foundation
import Observation

/// How long it takes the user to get places.
///
/// ### Two sources, one question
/// The page asks ``minutes(to:)`` and gets a number. It has always been the number its owner gave;
/// it can now be one a routing service measured. Crucially it is still **one question** — the row,
/// the block sheet and the calendar write all read this and none of them knows or cares which
/// source answered. A measured ETA arriving as a second code path would have meant three call sites
/// each deciding when to trust which, and three chances to disagree about what a day looks like.
///
/// The order is fixed and the fallbacks are unconditional:
///
/// 1. a **fresh** measurement for this place, if estimates are on and one has arrived;
/// 2. what the user said about this place;
/// 3. the default nobody has changed.
///
/// Every step down is silent. A place that will not geocode, a phone with no signal, a permission
/// that was refused — all of them land on a number that works, which is the whole reason the told
/// number was never demoted to a fallback of last resort.
///
/// ### Why the told numbers persist and the measurements do not
/// What somebody says about a journey is a fact about their life and survives a relaunch. A
/// measurement is a fact about *where they were standing* fifteen minutes ago, and writing that to
/// disk would be this app keeping a record of the user's whereabouts across launches — which is
/// exactly what it promises not to do, and would be a poor trade for saving one lookup.
///
/// Per-device on purpose, both halves. How long it takes you to reach the office is a fact about
/// where you live, not about your library, and syncing it would put one household's commute on
/// another's phone.
@Observable
@MainActor
public final class TravelPreferences {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let dateProvider: any DateProvider

    private static let defaultKey = "travel.defaultMinutes"
    private static let placesKey = "travel.minutesByPlace"
    private static let estimatesKey = "travel.usesRouteEstimates"
    private static let transportKey = "travel.transport"

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

    // MARK: - Measuring

    /// Whether the app may ask a routing service how long a journey takes.
    ///
    /// Off until somebody turns it on, and the *only* thing that decides whether any location or
    /// mapping framework is touched at all: while this is false the provider is a
    /// ``NoRouteProvider``, which has nothing to ask with.
    public private(set) var isEstimating: Bool

    /// The location permission, as last read. Meaningless while ``isEstimating`` is false.
    public private(set) var authorization: IntegrationAuthorization = .notRequested

    /// How the user gets about.
    ///
    /// A setting rather than a guess, because a fifteen-minute drive and a fifteen-minute walk are
    /// different meetings and there is no way to infer which somebody meant from a calendar.
    public var transport: RouteTransport {
        didSet {
            guard transport != oldValue else { return }
            defaults.set(transport.rawValue, forKey: Self.transportKey)
            // Every answer on hand was about a different journey. Keeping them would have the page
            // report a drive as a walk until each one aged out.
            estimates.removeAll()
            refusals.removeAll()
        }
    }

    /// Measurements that have arrived, keyed by place. In memory only — see the type's note.
    private var estimates: [String: RouteEstimate] = [:]

    /// When each place last refused, so the commonest case does not ask forever.
    ///
    /// A meeting room never geocodes and appears in a calendar five days a week, so without this
    /// every redraw of the page would spend a network call learning the same "no". See
    /// ``RouteRules/retryDelay(after:)``.
    private var refusals: [String: Date] = [:]

    /// Places with a question outstanding, so a scroll does not ask four times about one room.
    @ObservationIgnored private var inFlight: Set<String> = []

    @ObservationIgnored private var provider: any RouteProviding
    @ObservationIgnored private let makeProvider: @Sendable () -> any RouteProviding

    public init(
        defaults: UserDefaults = .standard,
        dateProvider: any DateProvider = SystemDateProvider(),
        makeProvider: @escaping @Sendable () -> any RouteProviding = { MapKitRouteProvider() }
    ) {
        self.defaults = defaults
        self.dateProvider = dateProvider
        self.makeProvider = makeProvider

        let stored = defaults.integer(forKey: Self.defaultKey)
        self.defaultMinutes = stored > 0 ? stored : TravelRules.defaultMinutes
        self.minutesByPlace = defaults.dictionary(forKey: Self.placesKey) as? [String: Int] ?? [:]

        let estimating = defaults.bool(forKey: Self.estimatesKey)
        self.isEstimating = estimating
        self.provider = estimating ? makeProvider() : NoRouteProvider()

        self.transport = defaults.string(forKey: Self.transportKey)
            .flatMap(RouteTransport.init(rawValue:)) ?? .driving
    }

    // MARK: - Answering

    /// How long to allow for a given place, and where the number came from.
    ///
    /// The whole ordering lives here, in one place, so nothing downstream has to decide it.
    public func travel(to location: String?) -> TravelNumber {
        guard let location, case let key = TravelRules.placeKey(for: location), !key.isEmpty else {
            return .told(defaultMinutes)
        }

        if isEstimating, let estimate = estimates[key],
           RouteRules.isFresh(estimate, now: dateProvider.now) {
            return .measured(estimate.minutes, transport: estimate.transport, at: estimate.measuredAt)
        }

        return .told(minutesByPlace[key] ?? defaultMinutes)
    }

    /// How long to allow for a given place.
    ///
    /// Unchanged in shape from before there was any such thing as a measurement, which is the point:
    /// the page, the sheet and the calendar write ask exactly what they always asked.
    public func minutes(to location: String?) -> Int {
        travel(to: location).minutes
    }

    // MARK: - Asking

    /// Measures the journey to `place`, unless there is already a good reason not to.
    ///
    /// Safe to call on every redraw, which is what makes it callable from a page that redraws
    /// constantly. Every refusal below is one the caller would otherwise have to remember:
    ///
    /// - estimates are off, or the permission is not granted;
    /// - the journey is too far off, or already begun (``RouteRules/isWorthMeasuring(departingAt:now:)``);
    /// - a fresh answer is already in hand;
    /// - this place refused recently and is still inside its retry delay;
    /// - a question about this place is already outstanding.
    public func refreshEstimate(to place: RoutePlace, departingAt moment: Date) async {
        guard isEstimating else { return }

        // A relaunch arrives with the switch already on and nothing known about the permission:
        // ``enableEstimates()`` is the only thing that ever set ``authorization``, and that happened
        // in some previous session. Without this the app comes back up believing it is allowed to
        // measure, believing it has not been given permission, and quietly measuring nothing —
        // forever, because nothing else would ever ask again.
        //
        // Reading the standing decision is free and never prompts; only ``enableEstimates()`` does
        // that, and only when nobody has decided yet.
        if authorization == .notRequested {
            authorization = await provider.authorization
        }
        guard authorization.canRead else { return }

        let key = place.key
        guard !key.isEmpty, !inFlight.contains(key) else { return }

        let now = dateProvider.now
        guard RouteRules.isWorthMeasuring(departingAt: moment, now: now) else { return }

        if let estimate = estimates[key], RouteRules.isFresh(estimate, now: now) { return }
        if let retryAt = refusals[key], retryAt > now { return }

        inFlight.insert(key)
        defer { inFlight.remove(key) }

        let answer = await provider.estimate(to: place, by: transport, departingAt: moment)

        // The switch can be turned off while a lookup is in flight, and an answer that lands after
        // it must not appear on the page — a number arriving from a service the user has just
        // disconnected from is the app ignoring them.
        guard isEstimating else { return }

        switch answer {
        case .success(let estimate):
            estimates[key] = estimate
            refusals.removeValue(forKey: key)
        case .failure(let failure):
            estimates.removeValue(forKey: key)
            let delay = RouteRules.retryDelay(after: failure)
            if delay > 0 { refusals[key] = dateProvider.now.addingTimeInterval(delay) }
        }
    }

    // MARK: - Turning it on

    /// Turns measuring on and asks for location access, in that order.
    ///
    /// The same ordering, for the same reason, as Calendar and Contacts: a permission dialogue
    /// before anybody has decided the feature is wanted is how an app gets denied permanently.
    @discardableResult
    public func enableEstimates() async -> IntegrationAuthorization {
        isEstimating = true
        defaults.set(true, forKey: Self.estimatesKey)

        provider = makeProvider()
        authorization = await provider.requestAccess()
        return authorization
    }

    /// Turns it off and forgets every measurement.
    ///
    /// The provider goes back to ``NoRouteProvider`` so nothing in the process can ask where the
    /// user is, and the answers already gathered are dropped rather than left to age out — they were
    /// never the app's to keep, and a page still showing "12 min drive" after the switch went off
    /// would be telling somebody the feature is off while it is visibly still on.
    ///
    /// iOS keeps the *permission*; only Settings › Privacy revokes that, and the interface says so
    /// rather than implying this switch undoes it. What the told numbers say is untouched: turning
    /// measuring off is not forgetting what somebody told you.
    public func disableEstimates() {
        isEstimating = false
        defaults.set(false, forKey: Self.estimatesKey)

        provider = NoRouteProvider()
        authorization = .notRequested
        estimates.removeAll()
        refusals.removeAll()
        inFlight.removeAll()
    }

    /// Re-reads the permission without prompting, for a switch that was granted and later revoked
    /// in Settings while the app was not looking.
    public func refreshAuthorization() async {
        guard isEstimating else { return }
        authorization = await provider.authorization
    }

    // MARK: - Remembering

    /// Remembers what somebody actually allowed for a place.
    ///
    /// Written when a travel block is *created*, not while a picker is being scrolled: the number
    /// somebody settled on is the answer, and every number they passed on the way to it is not.
    ///
    /// This is recorded whether the figure started life as a measurement or a guess, and that is
    /// deliberate — a person who accepts a measured twelve minutes and books it has told the app
    /// something about that journey, and it should still be there next week when the network is not.
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
        estimates.removeValue(forKey: key)
        refusals.removeValue(forKey: key)
    }

    /// How many places have been answered for, which is the only thing Settings needs to say about
    /// them: a list of every room somebody has ever been to is a screen nobody asked for.
    public var rememberedPlaceCount: Int { minutesByPlace.count }

    public func forgetAllPlaces() {
        minutesByPlace = [:]
        estimates.removeAll()
        refusals.removeAll()
    }
}
