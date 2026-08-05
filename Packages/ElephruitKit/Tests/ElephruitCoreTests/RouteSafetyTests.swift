import ElephruitCore
import Foundation
import Testing

/// What a route lookup is allowed to know.
///
/// ### Why this is a source-scanning test and not a code review note
/// The risk here is not somebody deciding to send a meeting's title to Apple. It is somebody adding
/// a field to ``RoutePlace`` for a perfectly good local reason — the sheet wants to show which
/// meeting the journey is for — and the adapter later gaining one line that puts it in the search
/// query, because a query with more context in it geocodes better. Each step is reasonable. The
/// result is "Divorce settlement with Ada" in a request leaving somebody's phone.
///
/// So the field list lives here, the same way ``CalendarWriteSafetyTests`` keeps `EventDraft`'s, and
/// the first step is the one that fails the build. This is the whole of what makes the Settings copy
/// — "only the place ever leaves this device" — a fact about the program rather than an intention.
@Suite("Route safety")
struct RouteSafetyTests {
    private static func sourceRoot() -> URL {
        var url = URL(filePath: #filePath)
        while url.lastPathComponent != "Tests", url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        return url.deletingLastPathComponent().appending(path: "Sources", directoryHint: .isDirectory)
    }

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: sourceRoot().appending(path: path), encoding: .utf8)
    }

    /// Every file that is allowed to talk to a routing service.
    ///
    /// Named individually rather than matched by pattern, so a new one is a deliberate addition
    /// somebody had to type here — which is the moment to ask what it needs to send.
    private static let routeFiles = [
        "ElephruitIntegrations/Routing.swift",
        "ElephruitIntegrations/FixtureRouteProvider.swift",
        "ElephruitIntegrations/MapKitRouteProvider.swift",
    ]

    // MARK: - The query

    /// The exact fields a place may carry. See the suite comment for why this is a list.
    private static let permittedPlaceFields: Set<String> = ["name", "latitude", "longitude"]

    @Test("A place can carry nothing but a place")
    func placeCarriesNothingPrivate() throws {
        let contents = try Self.source("ElephruitCore/Route.swift")

        guard let structRange = contents.range(of: "public struct RoutePlace"),
              let initRange = contents.range(
                of: "public init(", range: structRange.upperBound..<contents.endIndex
              )
        else {
            Issue.record("RoutePlace's declaration could not be found, so this test proves nothing")
            return
        }

        var declared: Set<String> = []
        for line in contents[structRange.upperBound..<initRange.lowerBound].components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("public var ") else { continue }
            let name = trimmed.dropFirst("public var ".count).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            declared.insert(String(name))
        }

        #expect(declared == Self.permittedPlaceFields, """
            A place is the only thing that reaches a routing service, and a routing service is off \
            the device. Anything added here is sent to Apple every time somebody has a meeting \
            somewhere, so a new field is a decision to make out loud: \
            \(declared.symmetricDifference(Self.permittedPlaceFields))
            """)
    }

    /// The other half: a closed type is no use if the question grows a second argument.
    @Test("A route can be asked for nothing but a place, a means, and a time")
    func theQuestionTakesOnlyAPlace() throws {
        let contents = try Self.source("ElephruitIntegrations/Routing.swift")

        // From the opening brace rather than the name, so the protocol's own conformances — it is
        // `Sendable`, and has to be — are not read as arguments to a question.
        guard let declaration = contents.range(of: "public protocol RouteProviding"),
              let open = contents.range(of: "{", range: declaration.upperBound..<contents.endIndex),
              let end = contents.range(of: "\n}", range: open.upperBound..<contents.endIndex)
        else {
            Issue.record("RouteProviding could not be found, so this test proves nothing")
            return
        }

        let body = contents[open.upperBound..<end.lowerBound]

        // The types a question may mention. Anything else — an event, a person, a day, a plan — is
        // context this has no business carrying, however convenient it would be at the call site.
        let permitted = ["RoutePlace", "RouteTransport", "Date", "IntegrationAuthorization",
                         "RouteEstimate", "RouteFailure", "Result", "Void"]

        var offenders: [String] = []
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { continue }

            // Capitalised identifiers are the type names in a declaration.
            var word = ""
            for character in trimmed + " " {
                if character.isLetter || character.isNumber {
                    word.append(character)
                    continue
                }
                defer { word = "" }
                guard let first = word.first, first.isUppercase, !permitted.contains(word) else { continue }
                offenders.append("\(word) in: \(trimmed)")
            }
        }

        #expect(offenders.isEmpty, """
            A route lookup leaves the device. It may be handed a place, how the journey is made, and \
            when — and nothing that could identify the meeting, the people in it, or the user: \
            \(offenders)
            """)
    }

    /// A closed type and a closed question, and then the files that could still reach past both.
    @Test("Nothing that talks to a routing service can see a calendar event")
    func routeFilesCannotSeeAMeeting() throws {
        // The event's own fields, by the names they are read by. `locationName` is absent from this
        // list on purpose — it is the one thing a journey is *about*, and it reaches the adapter as
        // a `RoutePlace`, never as an event.
        let forbidden = [
            "CalendarEventSummary", "EventDraft", "EventAttendee", "DayEvent", "DayPlan",
            ".attendees", ".organizerName", ".notes", ".displayTitle", ".participants",
        ]

        var offenders: [String] = []
        var filesSeen = 0

        for path in Self.routeFiles {
            guard let contents = try? Self.source(path) else { continue }
            filesSeen += 1

            for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Comments are where the forbidden names are *discussed*, which is the point of
                // discussing them, so they must not count as usage.
                guard !trimmed.hasPrefix("//") else { continue }

                for name in forbidden where trimmed.contains(name) {
                    offenders.append("\(path):\(index + 1) — \(name)")
                }
            }
        }

        #expect(filesSeen > 0, "The routing source must be findable, or this test proves nothing")
        #expect(offenders.isEmpty, """
            A file that talks to a routing service must have no way to read a meeting — which is \
            what makes "only the place is sent" structural rather than careful: \(offenders)
            """)
    }

    /// The reason the switch being off is worth anything.
    ///
    /// "When off, none of the frameworks are touched" is a claim about linkage, not intent: while
    /// `NoRouteProvider` is installed there is nothing in the process that could ask where the user
    /// is. This checks the other half — that the import is confined to the adapter, so turning the
    /// feature on is the only thing that ever loads it.
    ///
    /// ### `ElephruitFeatures` is exempt, and it is worth saying why rather than just skipping it
    /// It already imports MapKit, for `MapPlaceSearchField` — the field somebody types a venue into
    /// when they are editing an event, which searches Maps because that is the entire point of the
    /// control. Two things make it a different question from this one: it is macOS-only and absent
    /// from the `ElephruitMobileKit` product, so it is not in the phone's process at all; and it
    /// runs because a person typed into it, which is the opposite of a lookup that happens on its
    /// own while somebody reads their day.
    private static let macOnlyModule = "/ElephruitFeatures/"

    @Test("Only the adapter imports a mapping framework")
    func mapKitIsConfinedToTheAdapter() throws {
        let root = Self.sourceRoot()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else {
            Issue.record("The source tree could not be walked, so this test proves nothing")
            return
        }

        let adapter = "MapKitRouteProvider.swift"
        var offenders: [String] = []

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard url.lastPathComponent != adapter,
                  !url.path().contains(Self.macOnlyModule),
                  let contents = try? String(contentsOf: url, encoding: .utf8)
            else { continue }

            for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                for framework in ["import MapKit", "import CoreLocation"] where trimmed == framework {
                    offenders.append("\(url.lastPathComponent):\(index + 1) — \(framework)")
                }
            }
        }

        #expect(offenders.isEmpty, """
            A user who never turns route estimates on must have nothing in their process that could \
            ask where they are. Confining the import to the one adapter is how that stays true: \
            \(offenders)
            """)
    }
}
