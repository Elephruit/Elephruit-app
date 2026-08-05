import CoreLocation
import ElephruitCore
import Foundation
import MapKit

/// The one adapter that actually asks Apple how long a journey takes.
///
/// ### This is the only file in the app a test cannot reach, and that is on purpose
/// Everything a route lookup *decides* — what may be asked, what is fresh, what is plausible, what
/// to do when there is no answer — lives in ``RouteRules`` and ``TravelPreferences``, where it runs
/// against a fixture in a simulator with no location and no network. What is left here is the
/// translation: a ``RoutePlace`` into an `MKMapItem`, an `MKETAResponse` into minutes, an `NSError`
/// into a ``RouteFailure``. That is deliberately the smallest surface the feature could be built
/// with, because it is the surface nobody can prove correct except by using it.
///
/// ### What leaves the device, in full
/// The destination — a location string, or a coordinate when the organizer set one — and the user's
/// own position, which is what "how long from here" means. Nothing else: not the meeting's title,
/// not who is coming, not the note, not the calendar it lives on. That is not a promise this file
/// keeps by being careful; it is a promise ``RoutePlace`` keeps by having nowhere to put them, and
/// `RouteSafetyTests` fails if that stops being true.
///
/// ### One permission for the process, not one per provider
/// A `CLLocationManager` is how the authorisation is read, and a second one is how a permission
/// prompt ends up firing twice: the service builds a fresh provider every time the switch is turned
/// on, and two managers racing to ask the same question is the sort of thing a user sees and an
/// author does not. There is exactly one location permission on a device, so there is exactly one
/// here, and it lives on the main actor because `CLLocationManager` and its delegate do.
public final class MapKitRouteProvider: RouteProviding {
    @MainActor private static let permission = LocationPermission()

    public init() {}

    public var authorization: IntegrationAuthorization {
        get async { await Self.permission.current }
    }

    public func requestAccess() async -> IntegrationAuthorization {
        await Self.permission.request()
    }

    public func estimate(
        to place: RoutePlace,
        by transport: RouteTransport,
        departingAt moment: Date
    ) async -> Result<RouteEstimate, RouteFailure> {
        guard await Self.permission.current.canRead else { return .failure(.notAuthorized) }

        do {
            let seconds = try await Self.travelTime(to: place, by: transport, departingAt: moment)
            let minutes = RouteRules.minutes(fromSeconds: seconds)

            // The geocoder found a Room 2, just not this one. See `RouteRules.implausibleMinutes`.
            guard RouteRules.isPlausible(minutes: minutes) else {
                Diagnostics.integrations.debug("Discarded an implausible route of \(minutes) minutes")
                return .failure(.implausible)
            }

            return .success(RouteEstimate(
                placeKey: place.key,
                minutes: minutes,
                transport: transport,
                measuredAt: Date()
            ))
        } catch let failure as RouteFailure {
            return .failure(failure)
        } catch {
            return .failure(Self.translate(error))
        }
    }

    // MARK: - Finding the place

    /// A place as a map item, geocoding only when there is nothing better.
    ///
    /// A coordinate the organizer set is used as it stands. Searching for the *name* of a place that
    /// is already resolved is slower, and worse: "Ristorante Da Enzo" matches several restaurants
    /// and the geocoder picks one, whereas the point EventKit holds is the one the meeting is
    /// actually at.
    @MainActor
    private static func resolve(_ place: RoutePlace) async throws -> MKMapItem {
        if let latitude = place.latitude, let longitude = place.longitude {
            return MKMapItem(
                location: CLLocation(latitude: latitude, longitude: longitude),
                address: nil
            )
        }

        guard !place.name.isEmpty, let request = MKGeocodingRequest(addressString: place.name) else {
            throw RouteFailure.placeNotFound
        }

        let found = try await request.mapItems
        guard let first = found.first else { throw RouteFailure.placeNotFound }
        return first
    }

    // MARK: - Asking how long

    /// The ETA from wherever the user is now.
    ///
    /// `forCurrentLocation()` rather than a position this app fetched and held: MapKit resolves it
    /// inside the request, so the coordinate never becomes a value in Elephruit's memory that
    /// something else could later read, log, or write down.
    ///
    /// `departureDate` is set because it changes the answer — the traffic at eight is not the
    /// traffic at eleven — and because transit routing requires one.
    ///
    /// Finding the place and asking about it happen in one hop rather than two, because `MKMapItem`
    /// is not `Sendable` and so cannot leave the main actor. That is a fair constraint rather than a
    /// nuisance: the only thing worth carrying back across the boundary is a number of seconds.
    @MainActor
    private static func travelTime(
        to place: RoutePlace,
        by transport: RouteTransport,
        departingAt moment: Date
    ) async throws -> TimeInterval {
        let destination = try await resolve(place)

        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = destination
        request.transportType = transport.mapKitType
        request.departureDate = moment

        let response = try await MKDirections(request: request).calculateETA()
        return response.expectedTravelTime
    }

    // MARK: - What went wrong

    /// A framework error as something the app has already decided what to do about.
    ///
    /// Most of these end up silent, which is right: a meeting room that does not geocode is the
    /// ordinary case, and the told number was always going to cover it. See ``RouteFailure``.
    private static func translate(_ error: any Error) -> RouteFailure {
        let error = error as NSError
        guard error.domain == MKErrorDomain, error.code >= 0,
              let code = MKError.Code(rawValue: UInt(error.code))
        else { return .unavailable }

        switch code {
        case .placemarkNotFound: return .placeNotFound
        case .directionsNotFound: return .noRoute
        // Everything else — a throttled load, a server failure, a response that would not decode —
        // is the same thing from where the page is standing: no answer this time, keep the number
        // its owner gave, and say nothing.
        default: return .unavailable
        }
    }
}

extension RouteTransport {
    /// Transit is ETA-only in MapKit, which is exactly and only what this asks for.
    var mapKitType: MKDirectionsTransportType {
        switch self {
        case .driving: .automobile
        case .walking: .walking
        case .transit: .transit
        }
    }
}

// MARK: - The permission

/// Reading and requesting location access, and nothing else.
///
/// No position is ever fetched here. The app needs to know *whether* it may ask about a route, and
/// MapKit resolves "from here" inside the request — so there is no code path in Elephruit that turns
/// the user's location into a value it holds. That is worth the separate type: the difference
/// between an app that may use your location and an app that keeps it is not visible in a
/// permission dialogue, and this is the shape that makes it visible here.
@MainActor
private final class LocationPermission {
    private let manager = CLLocationManager()
    private let observer = AuthorizationObserver()

    init() {
        manager.delegate = observer
    }

    var current: IntegrationAuthorization { Self.translate(manager.authorizationStatus) }

    /// Prompts, once, and only when nobody has decided yet.
    ///
    /// iOS records the answer permanently, so asking again after a refusal shows nothing at all —
    /// which is why this returns the standing decision rather than pretending to have asked. See
    /// ``IntegrationAuthorization/isWorthAsking``.
    func request() async -> IntegrationAuthorization {
        guard manager.authorizationStatus == .notDetermined else { return current }

        let status: CLAuthorizationStatus = await withCheckedContinuation { continuation in
            observer.awaiting = continuation
            manager.requestWhenInUseAuthorization()
        }
        return Self.translate(status)
    }

    /// Location has no "write-only" tier to disallow, but it does have a coarse one.
    ///
    /// Reduced accuracy is reported as authorized on purpose. A route measured from a rough position
    /// is a rougher answer, not a refused one, and it is a strictly better one than the number
    /// somebody typed once — refusing it would be the app declining help because the help is
    /// imperfect. Always-on is treated the same as when-in-use because this feature never asks for
    /// more than when-in-use, and a user who granted more elsewhere has not granted this more.
    private static func translate(_ status: CLAuthorizationStatus) -> IntegrationAuthorization {
        switch status {
        case .notDetermined: .notRequested
        case .restricted: .restricted
        case .denied: .denied
        case .authorizedWhenInUse, .authorizedAlways: .authorized
        @unknown default: .unavailable
        }
    }
}

/// The delegate, which exists for exactly one message.
///
/// `requestWhenInUseAuthorization()` reports through the delegate rather than a completion handler,
/// so this is the bridge to an `await`. Resuming a continuation twice is a crash, and iOS does send
/// this message more than once — on first answer, and again whenever the setting changes while the
/// app is alive — so the continuation is cleared before it is resumed rather than after.
@MainActor
private final class AuthorizationObserver: NSObject, CLLocationManagerDelegate {
    var awaiting: CheckedContinuation<CLAuthorizationStatus, Never>?

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard let continuation = awaiting else { return }
            awaiting = nil
            continuation.resume(returning: status)
        }
    }
}
