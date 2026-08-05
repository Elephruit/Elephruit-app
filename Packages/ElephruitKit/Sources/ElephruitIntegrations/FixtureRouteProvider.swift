import ElephruitCore
import Foundation

/// A routing service that knows about a handful of invented places and nothing else.
///
/// ### What this is for, and why it is not a stub that always says twelve
/// A simulator has no location and no route to anywhere, so without this the entire feature — the
/// line on Today, the block it writes, the Settings switch — could be neither photographed nor
/// tested. That is the same hole ``FixtureCalendarProvider`` fills, and it is chosen the same way,
/// by a launch argument.
///
/// The answers below are not filler. They are the two cases that actually differ:
///
/// - **A street address answers.** "Northwind Studio, 40 Rivington Street" is the shape of place a
///   geocoder resolves, and it is what a measured "leave by" line is supposed to look like.
/// - **A room does not.** "Room 2" and "Assembly hall" are places you are already in the building
///   for, they resolve to nothing, and the told number stands. This is by far the more common
///   outcome in a real calendar, so a fixture that answered for everything would make the feature
///   look like it works far more often than it does — and would hide the fallback that is doing
///   most of the work.
///
/// Deterministic: the same place gets the same answer every run, because a screenshot that changes
/// between launches is a screenshot nobody can review.
public struct FixtureRouteProvider: RouteProviding {
    /// What each invented place is worth, in minutes by car, keyed by ``RoutePlace/key``.
    ///
    /// A dictionary rather than a rule, because the point is to be exactly as arbitrary as the world
    /// is: there is no relationship between how a place is spelled and how far away it is, and a
    /// fixture that derived one from a hash of the string would quietly teach that there is.
    private static let drivingMinutes: [String: Int] = [
        TravelRules.placeKey(for: "Northwind Studio, 40 Rivington Street"): 12,
        TravelRules.placeKey(for: "Aba, 302 North Green Street"): 23,
    ]

    /// Multipliers off the driving figure, so walking is slower and transit is in between.
    ///
    /// Crude on purpose. What the app has to get right is that the three differ and are labelled
    /// correctly; modelling a city's actual transit network is not this file's job.
    private static func minutes(driving: Int, by transport: RouteTransport) -> Int {
        switch transport {
        case .driving: driving
        case .walking: driving * 4
        case .transit: driving * 2
        }
    }

    private let dateProvider: any DateProvider
    private let storedAuthorization: IntegrationAuthorization

    public init(
        authorization: IntegrationAuthorization = .authorized,
        dateProvider: any DateProvider = SystemDateProvider()
    ) {
        self.storedAuthorization = authorization
        self.dateProvider = dateProvider
    }

    public var authorization: IntegrationAuthorization { storedAuthorization }

    public func requestAccess() async -> IntegrationAuthorization { storedAuthorization }

    public func estimate(
        to place: RoutePlace,
        by transport: RouteTransport,
        departingAt moment: Date
    ) async -> Result<RouteEstimate, RouteFailure> {
        guard storedAuthorization.canRead else { return .failure(.notAuthorized) }

        // The ordinary outcome, and the one the real world produces most often.
        guard let driving = Self.drivingMinutes[place.key] else { return .failure(.placeNotFound) }

        let minutes = Self.minutes(driving: driving, by: transport)
        guard RouteRules.isPlausible(minutes: minutes) else { return .failure(.implausible) }

        return .success(RouteEstimate(
            placeKey: place.key,
            minutes: minutes,
            transport: transport,
            measuredAt: dateProvider.now
        ))
    }
}
