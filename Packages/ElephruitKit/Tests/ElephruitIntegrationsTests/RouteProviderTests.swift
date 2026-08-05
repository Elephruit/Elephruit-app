import ElephruitCore
import ElephruitIntegrations
import Foundation
import Testing

/// The two route providers a test can actually reach.
///
/// The third — ``MapKitRouteProvider`` — is not imported here and cannot be: it needs a device with
/// a location and a network, and constructing one in a test would be a test of Apple's servers.
/// That is the whole reason the protocol exists, and it is why these two must be exercised properly:
/// between them they are every code path a user meets, because the real adapter's job is to produce
/// one of these same outcomes and hand it back.
@Suite("Route providers")
struct RouteProviderTests {
    static let now = Date(timeIntervalSinceReferenceDate: 757_425_600)

    /// The default, and the state of a user who never turns this on.
    ///
    /// It must refuse rather than return nothing-in-particular: a caller told "no route" would stop
    /// falling back to the number its owner gave, which is the one thing that must never happen.
    @Test("A provider that is not configured refuses, and refuses as unauthorized")
    func theInertDefaultRefuses() async {
        let provider = NoRouteProvider()

        #expect(provider.authorization == .notRequested)
        #expect(await provider.requestAccess() == .unavailable)

        let answer = await provider.estimate(
            to: RoutePlace(name: "Northwind Studio, 40 Rivington Street"),
            by: .driving,
            departingAt: Self.now
        )
        #expect(answer == .failure(.notAuthorized))
    }

    @Test("A street address is measured")
    func aStreetAddressAnswers() async throws {
        let provider = FixtureRouteProvider(dateProvider: FixedDate(now: Self.now))

        let answer = await provider.estimate(
            to: RoutePlace(name: "Northwind Studio, 40 Rivington Street"),
            by: .driving,
            departingAt: Self.now
        )

        let estimate = try answer.get()
        #expect(estimate.minutes == 12)
        #expect(estimate.transport == .driving)
        #expect(estimate.measuredAt == Self.now)
        #expect(estimate.placeKey == TravelRules.placeKey(for: "Northwind Studio, 40 Rivington Street"))
    }

    /// By far the commoner outcome in a real calendar, and the one the told number exists for.
    @Test("A meeting room does not resolve, and that is the ordinary case")
    func aRoomDoesNotAnswer() async {
        let provider = FixtureRouteProvider(dateProvider: FixedDate(now: Self.now))

        for room in ["Room 2", "Assembly hall"] {
            let answer = await provider.estimate(
                to: RoutePlace(name: room), by: .driving, departingAt: Self.now
            )
            #expect(answer == .failure(.placeNotFound), "\(room) is somewhere you are already")
        }
    }

    /// A fifteen-minute drive and a fifteen-minute walk are different meetings.
    @Test("How the journey is made changes the answer and the label")
    func transportChangesTheAnswer() async throws {
        let provider = FixtureRouteProvider(dateProvider: FixedDate(now: Self.now))
        let place = RoutePlace(name: "Aba, 302 North Green Street")

        var minutes: [RouteTransport: Int] = [:]
        for transport in RouteTransport.allCases {
            let estimate = try await provider.estimate(
                to: place, by: transport, departingAt: Self.now
            ).get()
            #expect(estimate.transport == transport, "An answer must not forget how it was arrived at")
            minutes[transport] = estimate.minutes
        }

        let driving = try #require(minutes[.driving])
        let transit = try #require(minutes[.transit])
        let walking = try #require(minutes[.walking])
        #expect(driving < transit && transit < walking)
    }

    /// The same place answers the same way every launch, or a screenshot is unreviewable.
    @Test("The fixture is deterministic")
    func theFixtureDoesNotWander() async throws {
        let provider = FixtureRouteProvider(dateProvider: FixedDate(now: Self.now))
        let place = RoutePlace(name: "northwind studio,  40 RIVINGTON STREET")

        let first = try await provider.estimate(to: place, by: .driving, departingAt: Self.now).get()
        let second = try await provider.estimate(to: place, by: .driving, departingAt: Self.now).get()

        #expect(first == second)
        // And it is the same place as the canonically-spelled one, because the key says so.
        #expect(first.minutes == 12, "One room is one room, however it was typed")
    }

    /// A fixture that answers while the permission says otherwise would make the off state
    /// untestable, which is the state most users are in.
    @Test("The fixture honours a refused permission")
    func theFixtureRespectsAuthorization() async {
        for authorization in [IntegrationAuthorization.denied, .notRequested, .restricted] {
            let provider = FixtureRouteProvider(
                authorization: authorization, dateProvider: FixedDate(now: Self.now)
            )
            let answer = await provider.estimate(
                to: RoutePlace(name: "Aba, 302 North Green Street"),
                by: .driving,
                departingAt: Self.now
            )
            #expect(answer == .failure(.notAuthorized), "\(authorization) must measure nothing")
        }
    }
}

/// A clock that does not move, so `measuredAt` is an assertion rather than a race.
private struct FixedDate: DateProvider {
    let now: Date
    var calendar = Calendar(identifier: .gregorian)
}
