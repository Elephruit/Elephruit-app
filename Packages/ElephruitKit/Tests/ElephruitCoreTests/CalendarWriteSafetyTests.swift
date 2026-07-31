import ElephruitCore
import Foundation
import Testing

/// The acceptance criterion that matters most in Phase D: **no write to any calendar ever occurs.**
///
/// ### Why this needs asserting rather than reviewing
/// EventKit has no read-only permission. Its only requests are `requestFullAccessToEvents()` and
/// `requestWriteOnlyAccessToEvents()`, so an app that merely reads has to ask for **full access** —
/// verified against the macOS SDK headers, where the older combined request is deprecated as of
/// macOS 14.
///
/// So the app holds a permission far broader than what it uses, and the user has no way to grant
/// less. The only thing that makes "read-only" true is the code, and the only thing that keeps it
/// true through later edits is a test.
///
/// Two independent guards, because either alone can be defeated:
///
/// 1. **The protocol has no write method**, so calling one is a compile error rather than a policy.
/// 2. **The EventKit adapter's source contains no mutating EventKit call**, checked here — which
///    catches the case where someone reaches past the protocol to the store directly.
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
    /// forbidden, and anyone adding one has to add it here too.
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

    @Test("The EventKit adapter contains no call that could change a calendar")
    func adapterNeverWrites() throws {
        let files = Self.swiftFiles(under: "ElephruitIntegrations")
        #expect(!files.isEmpty, "The integrations source must be findable, or this test proves nothing")

        var offenders: [String] = []

        for file in files {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }

            for (number, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)

                // Comments are where the forbidden calls are *named*, which is the point of naming
                // them, so they must not count as usage.
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }

                for call in Self.mutatingCalls where text.contains(call) {
                    offenders.append("\(file.lastPathComponent):\(number + 1) — \(call)")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            Elephruit holds full calendar access because EventKit offers nothing narrower, and \
            never writes. These would: \(offenders)
            """
        )
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
}
