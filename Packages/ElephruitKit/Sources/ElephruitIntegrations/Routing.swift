import ElephruitCore
import Foundation

/// Asking how long a journey takes.
///
/// ### The narrowest interface in the app, deliberately
/// One question, and it takes a ``RoutePlace``, a ``RouteTransport`` and a departure time. There is
/// no method that takes an event, a person, or a day, and there is no way to hand this a calendar —
/// which is what makes "only the place ever leaves the device" a shape rather than a promise.
/// `RouteSafetyTests` reads this file and fails if the question grows an argument.
///
/// ### Why this is a protocol at all
/// Because the simulator has no location and no route to anywhere, so an adapter that talks to
/// MapKit directly is a feature nobody can look at, screenshot, or test. The calendar solved this
/// once already: a protocol, a real adapter, a fixture, and a launch argument choosing between them
/// — see ``CalendarProviding``. This is the same arrangement for the same reason, and it leaves
/// exactly one file in the app that is unreachable from a test, which is the adapter itself.
///
/// ### There is no write half and never will be
/// Route lookups read. Nothing here creates, changes or deletes anything, on the device or off it,
/// so the whole category of "the CRM leaked into somebody's account" that `CalendarWriteSafetyTests`
/// exists to prevent does not arise. What replaces it as the risk is the *query*, and that is what
/// ``RoutePlace`` is for.
public protocol RouteProviding: Sendable {
    /// The current location authorisation, read without prompting.
    var authorization: IntegrationAuthorization { get async }

    /// Prompts, if and only if the user has never been asked.
    func requestAccess() async -> IntegrationAuthorization

    /// How long it takes to reach `place`, setting off at `moment`.
    ///
    /// - Returns: a ``RouteEstimate``, or the ``RouteFailure`` that stopped one arriving. Most
    ///   failures are ordinary — a meeting room does not geocode, and the told number was always
    ///   going to cover it — which is why this reports rather than throws.
    func estimate(
        to place: RoutePlace,
        by transport: RouteTransport,
        departingAt moment: Date
    ) async -> Result<RouteEstimate, RouteFailure>
}

/// The default, and what the app holds until somebody turns route estimates on.
///
/// Reports ``IntegrationAuthorization/notRequested`` and refuses every question, so the path a user
/// who never grants location takes is a real implementation exercised from the first launch rather
/// than a `nil` branch nobody runs. While this is installed, no location framework is touched at
/// all — that is the substance of "when off, none of the frameworks are reached", not a comment
/// about intent.
public struct NoRouteProvider: RouteProviding {
    public init() {}

    public var authorization: IntegrationAuthorization { .notRequested }

    public func requestAccess() async -> IntegrationAuthorization {
        Diagnostics.integrations.debug("A route was requested but no provider is configured")
        return .unavailable
    }

    public func estimate(
        to place: RoutePlace,
        by transport: RouteTransport,
        departingAt moment: Date
    ) async -> Result<RouteEstimate, RouteFailure> {
        .failure(.notAuthorized)
    }
}
