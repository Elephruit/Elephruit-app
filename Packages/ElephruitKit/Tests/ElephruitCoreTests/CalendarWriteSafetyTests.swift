import ElephruitCore
import Foundation
import Testing

/// What the calendar module is and is not allowed to do to somebody's calendar.
///
/// ### What changed, and why the old guarantee had to go
/// Until the calendar module, the guarantee was absolute: `CalendarProviding` had no write method, so
/// writing was a compile error. That was the right shape for a feature that only showed events beside
/// tasks, and it is the wrong shape for a calendar application — an app that cannot create an event
/// is not one.
///
/// The guarantee that replaces it is narrower and, for this feature, harder to break by accident:
///
/// 1. **Writes take an `EventDraft` and nothing else.** A draft holds only fields a person decides.
///    It cannot carry a linked person, a meeting note, a project, or a prior interaction, so the CRM
///    cannot reach a synced calendar event however the calling code is later edited. Adding a field
///    to it fails ``draftCarriesNothingPrivate()`` and forces the question to be asked out loud.
/// 2. **Mutating EventKit calls live in exactly three methods.** ``mutationsAreConfinedToWriteMethods()``
///    reads the adapter and fails if one appears anywhere else — including inside a method whose name
///    says it reads, which is the shape this would actually arrive in.
/// 3. **Nothing else in the integrations module writes at all.**
///
/// EventKit still offers no read-only tier — its only requests are `requestFullAccessToEvents()` and
/// `requestWriteOnlyAccessToEvents()`, the older combined request being deprecated as of macOS 14 —
/// so the permission remains broader than any single use, and these checks remain the only thing
/// standing between that permission and a mistake.
@Suite("Calendar write safety")
struct CalendarWriteSafetyTests {
    private static func sourceRoot() -> URL {
        var url = URL(filePath: #filePath)
        while url.lastPathComponent != "Tests", url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        return url.deletingLastPathComponent().appending(path: "Sources", directoryHint: .isDirectory)
    }

    private static func swiftFiles(under directory: String) -> [URL] {
        let root = sourceRoot().appending(path: directory, directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Every EventKit call that changes something, plus the commit that would flush it.
    ///
    /// Named individually rather than matched by pattern: a list of exact symbols says what is
    /// controlled, and anyone adding one has to add it here too.
    private static let mutatingCalls = [
        "store.save(",
        "store.remove(",
        "store.commit(",
        "store.reset(",
        ".saveEvent(",
        ".removeEvent(",
        ".saveCalendar(",
        ".removeCalendar(",
        ".saveReminder(",
        ".removeReminder(",
        "requestWriteOnlyAccessToEvents",
    ]

    /// The three methods a write may occur in. Nothing else, ever.
    private static let writeMethods: Set<String> = ["createEvent", "updateEvent", "deleteEvent"]

    /// Lines paired with the name of the method they sit in.
    ///
    /// Crude — it recognises a declaration by `func <name>` and takes the innermost one seen — but the
    /// thing it is looking for is a mutating call added to the wrong method during an ordinary edit,
    /// and that is exactly what this shape catches.
    private static func linesWithEnclosingMethod(of url: URL) -> [(number: Int, text: String, method: String)] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var result: [(Int, String, String)] = []
        var currentMethod = "<file scope>"

        for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let range = trimmed.range(of: "func ") {
                let afterKeyword = trimmed[range.upperBound...]
                let name = afterKeyword.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if !name.isEmpty { currentMethod = String(name) }
            }

            result.append((index + 1, trimmed, currentMethod))
        }

        return result
    }

    @Test("Mutating EventKit calls appear only in the three declared write methods")
    func mutationsAreConfinedToWriteMethods() {
        let files = Self.swiftFiles(under: "ElephruitIntegrations")
        #expect(!files.isEmpty, "The integrations source must be findable, or this test proves nothing")

        var offenders: [String] = []
        var writesSeen = 0

        for file in files {
            for line in Self.linesWithEnclosingMethod(of: file) {
                // Comments are where the forbidden calls are *named*, which is the point of naming
                // them, so they must not count as usage.
                guard !line.text.hasPrefix("//") else { continue }

                for call in Self.mutatingCalls where line.text.contains(call) {
                    guard Self.writeMethods.contains(line.method) else {
                        offenders.append("\(file.lastPathComponent):\(line.number) in \(line.method) — \(call)")
                        continue
                    }
                    writesSeen += 1
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            A calendar write may only happen in createEvent, updateEvent, or deleteEvent — each of \
            which takes an explicit scope and an EventDraft. These do not: \(offenders)
            """
        )
        #expect(writesSeen > 0, "If nothing writes at all, this test has stopped proving anything")
    }

    /// The exact fields a draft may carry.
    ///
    /// ### Why a list rather than a principle
    /// The risk is not somebody deliberately putting a person's private history into a calendar
    /// event. It is somebody adding `linkedPersonIDs` to the draft for a perfectly good local reason
    /// — the editor needs to know who is attached — and the adapter later gaining one line that
    /// writes it into the notes so it survives a sync. Each step is reasonable; the result is a
    /// user's CRM in an Exchange calendar their employer can read.
    ///
    /// Keeping the list here makes the first step visible. Local links live on ``EventAnnotation``
    /// in the store, which the provider cannot see.
    private static let permittedDraftFields: Set<String> = [
        "calendarIdentifier", "title", "startAt", "endAt", "isAllDay",
        "timeZoneIdentifier", "location", "notes", "url", "availability", "alarms", "recurrence",
    ]

    @Test("An event draft can carry nothing private")
    func draftCarriesNothingPrivate() throws {
        let file = Self.sourceRoot()
            .appending(path: "ElephruitCore", directoryHint: .isDirectory)
            .appending(path: "EventDraft.swift")
        let contents = try String(contentsOf: file, encoding: .utf8)

        // Stored properties of the draft: `public var <name>:` before the struct's initialiser.
        guard let structRange = contents.range(of: "public struct EventDraft"),
              let initRange = contents.range(of: "public init(", range: structRange.upperBound..<contents.endIndex)
        else {
            Issue.record("EventDraft's declaration could not be found, so this test proves nothing")
            return
        }

        var declared: Set<String> = []
        for line in contents[structRange.upperBound..<initRange.lowerBound].components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("public var ") else { continue }
            let name = trimmed.dropFirst("public var ".count).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            declared.insert(String(name))
        }

        #expect(declared == Self.permittedDraftFields, """
            An event draft is the only thing that can be written to somebody's calendar. Anything \
            added here can be synced to an account other people can read, so a new field is a \
            decision to make deliberately: \(declared.symmetricDifference(Self.permittedDraftFields))
            """)
    }

    @Test("Nothing in the integrations module can read the store or the CRM")
    func integrationsCannotReachTheLibrary() {
        var offenders: [String] = []

        for file in Self.swiftFiles(under: "ElephruitIntegrations") {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }

            for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                for banned in ["import ElephruitModel", "import ElephruitPersistence", "import SwiftData"]
                where trimmed.hasPrefix(banned) {
                    offenders.append("\(file.lastPathComponent):\(index + 1) — \(banned)")
                }
            }
        }

        #expect(offenders.isEmpty, """
            The calendar adapter must have no way to reach a person, a note, or a project — which is \
            what makes "the CRM is never written to a calendar" structural rather than careful: \(offenders)
            """)
    }

    @Test("The read-only guarantee does not depend on the permission granted")
    func writeOnlyIsTreatedAsNoAccess() {
        // Write-only is a state this app never asks for, but it is representable — a user could have
        // granted it to an earlier build. It must read as "cannot see anything" rather than as some
        // partial success, because an app that can only write is useless *and* dangerous here.
        #expect(!IntegrationAuthorization.denied.canRead)
        #expect(!IntegrationAuthorization.restricted.canRead)
        #expect(!IntegrationAuthorization.notRequested.canRead)
        #expect(!IntegrationAuthorization.unavailable.canRead)
        #expect(IntegrationAuthorization.authorized.canRead)
    }

    @Test("Only an undecided permission is worth asking about again")
    func askingAgainIsPointlessOnceDecided() {
        // macOS records the decision permanently. A "try again" button that shows no prompt is worse
        // than no button, so the interface has to know the difference.
        #expect(IntegrationAuthorization.notRequested.isWorthAsking)
        #expect(!IntegrationAuthorization.denied.isWorthAsking)
        #expect(!IntegrationAuthorization.restricted.isWorthAsking)
    }

    @Test("Every refused state explains itself")
    func refusalsAreExplained() {
        for authorization in [
            IntegrationAuthorization.notRequested,
            .denied,
            .restricted,
            .unavailable,
        ] {
            #expect(authorization.explanation?.isEmpty == false,
                    "\(authorization) must say something a user can act on")
        }
        #expect(IntegrationAuthorization.authorized.explanation == nil,
                "A working integration has nothing to explain")
    }

    @Test("A read-only calendar says why, in words the user can act on")
    func readOnlyCalendarsExplainThemselves() {
        let subscribed = CalendarInfo(
            id: "s", title: "Holidays", accountName: "iCloud",
            accountKind: .subscribed, allowsModification: true
        )
        #expect(!subscribed.allowsModification, "A subscribed feed is read-only whatever its flag says")
        #expect(subscribed.readOnlyExplanation?.contains("subscribed") == true)

        let delegated = CalendarInfo(
            id: "d", title: "Team", accountName: "Acme Exchange",
            accountKind: .exchange, allowsModification: false
        )
        #expect(delegated.readOnlyExplanation?.contains("Acme Exchange") == true)

        let ordinary = CalendarInfo(id: "o", title: "Home", accountKind: .iCloud)
        #expect(ordinary.readOnlyExplanation == nil, "A writable calendar has nothing to explain")
    }
}
