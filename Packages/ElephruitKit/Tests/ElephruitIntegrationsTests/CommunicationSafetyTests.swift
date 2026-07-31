import ElephruitCore
// `@testable` so the mapping decisions can be asserted where they are made — which service name a
// channel asks for, how an `NSError` is read, what a request becomes as items. Each is a small pure
// function that is deliberately not public, and each is a place a plausible-looking change would
// quietly widen what the app claims.
@testable import ElephruitIntegrations
import Foundation
import Testing

/// The promises this module makes about what it does **not** touch, asserted rather than reviewed.
///
/// ### Why a source scan and not a code review
/// The rules here — no private frameworks, no reading the Messages database, no claiming delivery —
/// are exactly the kind that hold until somebody is one afternoon from shipping and finds an
/// `IMCore` symbol that would answer the question. A review catches that if the reviewer knows to
/// look. A failing test catches it whether or not anybody is looking, and forces the person who
/// wants to cross the line to delete an assertion that says why it is there.
///
/// It is a text scan, like `SourceHygieneTests`, and honest about its limits: it reads source, so it
/// cannot see a symbol assembled at runtime, and a determined author could evade it. Its job is to
/// catch the ordinary case, which is how this arrives in practice.
@Suite("Communication platform safety")
struct CommunicationSafetyTests {
    private static func sourceRoot() -> URL {
        var url = URL(filePath: #filePath)
        while url.lastPathComponent != "Tests", url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        return url.deletingLastPathComponent().appending(path: "Sources", directoryHint: .isDirectory)
    }

    private static func swiftFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot(), includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Source with comments stripped, so a doc comment explaining why `IMCore` is forbidden does not
    /// fail the test that forbids it.
    private static func codeLines(of url: URL) -> [(number: Int, text: String)] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var result: [(Int, String)] = []
        var insideBlockComment = false

        for (index, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
            var line = rawLine

            if insideBlockComment {
                guard let end = line.range(of: "*/") else { continue }
                line = String(line[end.upperBound...])
                insideBlockComment = false
            }
            while let start = line.range(of: "/*") {
                if let end = line.range(of: "*/", range: start.upperBound..<line.endIndex) {
                    line = String(line[line.startIndex..<start.lowerBound]) + String(line[end.upperBound...])
                } else {
                    line = String(line[line.startIndex..<start.lowerBound])
                    insideBlockComment = true
                    break
                }
            }
            if let comment = line.range(of: "//") {
                line = String(line[line.startIndex..<comment.lowerBound])
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            result.append((index + 1, trimmed))
        }
        return result
    }

    @Test("The scan can find the source tree")
    func scanIsWiredUp() {
        #expect(Self.swiftFiles().count > 15, "the module sources must be discoverable, or this proves nothing")
    }

    // MARK: - Messages

    /// Every route to somebody's messages that this app must not take.
    ///
    /// Named individually rather than matched by pattern, on the same terms as the calendar and
    /// Contacts lists: a roster of exact symbols and paths says what is forbidden, and anybody adding
    /// one has to add it here too.
    private static let forbiddenMessageAccess = [
        // The private frameworks. There is no supported general-purpose API for a normal macOS app
        // to read sent iMessage content or message history, and these are how people reach for one.
        "IMCore",
        "IMDPersistence",
        "IMHandle",
        "IMChat",
        "IMDaemonController",
        "ChatKit",

        // The database itself, reachable only with Full Disk Access and never with a good reason.
        "Library/Messages",
        "chat.db",
        "sms.db",
        "com.apple.messages",
        "com.apple.imagent",

        // Driving the Messages interface instead of asking it properly.
        "AXUIElement",
        "CGWindowListCopyWindowInfo",
    ]

    @Test("Nothing reaches into Messages")
    func messagesAreNeverRead() {
        var offenders: [String] = []

        for file in Self.swiftFiles() {
            for line in Self.codeLines(of: file) {
                for symbol in Self.forbiddenMessageAccess where line.text.contains(symbol) {
                    offenders.append("\(file.lastPathComponent):\(line.number) — \(symbol)")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            There is no supported way for a normal macOS app to read the user's messages, and every \
            unsupported way is either a private framework, a protected database, or screen scraping. \
            An app that reached for one would be trading the user's entire conversation history for \
            a status label: \(offenders)
            """
        )
    }

    @Test("No mail automation stands in for a supported API")
    func mailIsNotScripted() {
        // AppleScript and ScriptingBridge are *permitted* as an optional power-user feature behind an
        // explicit Automation permission — but not as the architecture, and nothing here uses them.
        // If one is ever added it belongs behind its own protocol with its own entitlement, and this
        // assertion is the thing that has to change deliberately.
        var offenders: [String] = []

        for file in Self.swiftFiles() {
            for line in Self.codeLines(of: file) {
                for symbol in ["NSAppleScript", "SBApplication", "ScriptingBridge", "osascript", "NSAppleEventDescriptor"]
                where line.text.contains(symbol) {
                    offenders.append("\(file.lastPathComponent):\(line.number) — \(symbol)")
                }
            }
        }

        #expect(offenders.isEmpty, "Mail scripting is not the primary architecture: \(offenders)")
    }

    // MARK: - Claims

    @Test("Nothing in the app produces a delivered state")
    func deliveredIsUnreachable() {
        // `CommunicationState.delivered` exists so that the absence of delivery evidence is a
        // *modelled* absence rather than an unnamed gap. Nothing may assign it: no macOS API reports
        // that a message arrived, and the mail provider APIs this design allows for report
        // submission rather than arrival.
        var offenders: [String] = []

        for file in Self.swiftFiles() {
            for line in Self.codeLines(of: file) {
                // Reading the case — in a `switch`, a label, or a comparison — is fine and necessary.
                // Producing one is not, and every way of producing one names it after `state:` or an
                // assignment.
                let producers = ["state = .delivered", "state: .delivered", "return .delivered"]
                for producer in producers where line.text.contains(producer) {
                    offenders.append("\(file.lastPathComponent):\(line.number) — \(producer)")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            Nothing in the deployment SDK reports that a message reached its recipient. A code path \
            that sets `delivered` is claiming knowledge the platform does not supply: \(offenders)
            """
        )
    }

    @Test("A launcher's outcomes never exceed what the framework reported")
    func outcomesMapConservatively() {
        // The mapping, asserted directly rather than inferred from the source: a completed share is
        // `shareCompleted` and never `submitted` or above, and an opened URL is `composerOpened` and
        // never anything else.
        #expect(CommunicationLaunchOutcome.composerOpened.state == .composerOpened)
        #expect(CommunicationLaunchOutcome.shareCompleted.state == .shareCompleted)
        #expect(!CommunicationLaunchOutcome.shareCompleted.state.claimsTheMessageLeft)
        #expect(!CommunicationLaunchOutcome.shareCompleted.state.countsAsReachingOut)
        #expect(CommunicationLaunchOutcome.canceled(.userCanceled).state == .canceled)
        #expect(CommunicationLaunchOutcome.failed(.noHandler).state == .failed)

        // Nothing was attempted, so the record stays where it was.
        #expect(CommunicationLaunchOutcome.unavailable.state == .draftPrepared)
    }

    @Test("Everything a launcher knows, it learned from a framework")
    func launcherReportsCarrySystemEvidence() {
        for outcome in [
            CommunicationLaunchOutcome.composerOpened,
            .shareCompleted,
            .canceled(.userCanceled),
            .failed(.noHandler),
            .unavailable,
        ] {
            let report = CommunicationLaunchReport(
                intentID: UUID(), channel: .email, mechanism: .sharingService,
                outcome: outcome, occurredAt: Date()
            )
            #expect(report.signal.evidence == .systemCallback)
            #expect(report.signal.intentID == report.intentID, "a launcher's report never needs guessing at")
        }
    }
}

// MARK: - The inert defaults

@Suite("Communication launchers")
@MainActor
struct CommunicationLauncherTests {
    @Test("The default launcher opens nothing and says so")
    func inertLauncherIsInert() {
        let launcher = InertCommunicationLauncher()
        let request = CommunicationLaunchRequest(
            id: UUID(),
            channel: .email,
            recipients: [CommunicationRecipient(handle: "maya@example.com")],
            subject: "Lunch"
        )

        let report = launcher.launch(request)

        #expect(report.outcome == .unavailable)
        #expect(launcher.launched.count == 1, "it records what it would have opened")
        #expect(launcher.launched.first?.recipientHandles == ["maya@example.com"])
    }

    @Test("A URL launcher builds the scheme and claims nothing beyond opening it")
    func urlLauncherOpensAndStops() {
        var opened: [URL] = []
        let launcher = URLSchemeCommunicationLauncher(
            open: { url in
                opened.append(url)
                return true
            },
            now: { FixedDateProvider.reference.now }
        )

        let report = launcher.launch(
            CommunicationLaunchRequest(
                id: UUID(),
                channel: .email,
                recipients: [CommunicationRecipient(handle: "maya@example.com")],
                subject: "Lunch",
                preferredMechanism: .urlScheme
            )
        )

        #expect(opened.count == 1)
        #expect(opened.first?.scheme == "mailto")
        #expect(report.outcome == .composerOpened)
        #expect(report.mechanism == .urlScheme)
        #expect(!report.mechanism.reportsCompletion, "there is no callback coming, ever")
    }

    @Test("A group email hides the recipients from each other")
    func groupEmailUsesBlindCopy() {
        var opened: [URL] = []
        let launcher = URLSchemeCommunicationLauncher(open: { opened.append($0); return true })

        launcher.launch(
            CommunicationLaunchRequest(
                id: UUID(),
                channel: .email,
                recipients: [
                    CommunicationRecipient(handle: "maya@example.com"),
                    CommunicationRecipient(handle: "sam@example.com"),
                ],
                preferredMechanism: .urlScheme
            )
        )

        let text = opened.first?.absoluteString ?? ""
        #expect(text.contains("bcc="), "a group email that discloses everyone's address is a privacy failure")
    }

    @Test("Nowhere to send it is a failure, not a silent success")
    func unroutableRequestsFail() {
        let launcher = URLSchemeCommunicationLauncher(open: { _ in true })

        let report = launcher.launch(
            CommunicationLaunchRequest(id: UUID(), channel: .phoneCall, recipients: [], preferredMechanism: .urlScheme)
        )

        guard case .failed = report.outcome else {
            Issue.record("expected a failure, got \(report.outcome)")
            return
        }
    }

    @Test("No handler on the machine is reported rather than assumed away")
    func refusedOpensAreFailures() {
        let launcher = URLSchemeCommunicationLauncher(open: { _ in false })

        let report = launcher.launch(
            CommunicationLaunchRequest(
                id: UUID(),
                channel: .facetimeVideo,
                recipients: [CommunicationRecipient(handle: "5125550192")],
                preferredMechanism: .urlScheme
            )
        )

        #expect(report.outcome == .failed(.noHandler))
    }

    @Test("A dismissed share sheet is a cancellation, and anything else is a failure")
    func cancellationIsToldApartFromFailure() {
        let cancelled = SharingServiceCommunicationLauncher.failure(
            from: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        )
        #expect(cancelled.wasCanceledByUser)

        // Anything unfamiliar surfaces as a problem the user can see rather than being quietly filed
        // as "you changed your mind" — which would hide a broken mail setup behind a shrug.
        let unknown = SharingServiceCommunicationLauncher.failure(
            from: NSError(domain: "SomeFrameworkDomain", code: 42)
        )
        #expect(!unknown.wasCanceledByUser)
        #expect(unknown.technicalDetail == "SomeFrameworkDomain 42")
        #expect(!unknown.summary.contains("42"), "an error code must not reach the sentence shown")
    }

    @Test("A sharing service is asked for only where macOS offers one")
    func sharingServiceNamesAreCorrect() {
        #expect(SharingServiceCommunicationLauncher.serviceName(for: .email) == .composeEmail)
        #expect(SharingServiceCommunicationLauncher.serviceName(for: .message) == .composeMessage)
        #expect(SharingServiceCommunicationLauncher.serviceName(for: .phoneCall) == nil)
        #expect(SharingServiceCommunicationLauncher.serviceName(for: .facetimeVideo) == nil)
        #expect(SharingServiceCommunicationLauncher.serviceName(for: .facetimeAudio) == nil)
    }

    @Test("A body travels as text, not as a percent-encoded URL")
    func sharingServiceItemsCarryTheBody() {
        // The reason to prefer a sharing service: a message containing a newline, an ampersand, or
        // an emoji arrives intact rather than surviving a round trip through URL escaping.
        let items = SharingServiceCommunicationLauncher.items(
            for: CommunicationLaunchRequest(
                id: UUID(),
                channel: .email,
                recipients: [CommunicationRecipient(handle: "maya@example.com")],
                body: "Thursday & Friday\nboth work 🙂"
            )
        )

        #expect(items.count == 1)
        #expect(items.first as? String == "Thursday & Friday\nboth work 🙂")

        // A message with nothing in it yet is legitimate: the user is about to type it.
        let empty = SharingServiceCommunicationLauncher.items(
            for: CommunicationLaunchRequest(id: UUID(), channel: .email, recipients: [])
        )
        #expect(empty.count == 1)
    }
}

// MARK: - Providers

@Suite("Provider message services")
struct ProviderMessageServiceTests {
    @Test("The shipping provider is inert")
    func noProviderIsConfigured() async {
        // Elephruit has no network entitlement, so a Gmail or Microsoft Graph conformance cannot be
        // added without adding one in the same commit — standing rule R3. Until then this is what
        // every build runs, and it is a real code path rather than a nil branch.
        // Through the existential, so the async witnesses the protocol declares are the ones called —
        // which is how every call site reaches it.
        let provider: any ProviderMessageService = NoProviderMessageService()

        let authorization = await provider.authorization
        let requested = await provider.requestAccess()
        let sent = await provider.sentMessages(matching: ProviderSentQuery(range: Date()..<Date()))

        #expect(authorization == .notRequested)
        #expect(requested == .unavailable)
        #expect(sent.isEmpty)
    }

    @Test("A provider record verifies submission, never delivery")
    func providerRecordsClaimSubmissionOnly() {
        let record = ProviderMessageRecord(
            id: "gmail-1",
            threadID: "thread-1",
            providerName: "Gmail",
            recipients: [CommunicationRecipient(handle: "maya@example.com")],
            subject: "Lunch",
            submittedAt: FixedDateProvider.reference.now
        )

        let signal = record.signal()
        #expect(signal.state == .providerVerifiedSent)
        #expect(signal.state != .delivered)
        #expect(signal.evidence == .providerAPI)
        #expect(signal.providerMessageID == "gmail-1")
    }

    @Test("Sent-mail reconciliation does not ask for bodies by default")
    func queriesAreBoundedAndContentFree() {
        let query = ProviderSentQuery(range: Date()..<Date())
        #expect(!query.includesBodies)
    }

    @Test("A send cannot be built without a preview the user saw")
    func sendingRequiresAConfirmation() {
        // `SendConfirmation` has a private initialiser, so the only way to obtain one is
        // `granted(previewShownAt:)` — which the send sheet calls after the user has read what is
        // about to go out. A provider implementation therefore cannot be handed something to send
        // that was never previewed, because there is no way to construct the argument.
        let confirmation = SendConfirmation.granted(previewShownAt: FixedDateProvider.reference.now)
        let request = ConfirmedSendRequest(
            intentID: UUID(),
            recipients: [CommunicationRecipient(handle: "maya@example.com")],
            subject: "Lunch",
            body: "Thursday?",
            correlationToken: CommunicationCorrelation.makeToken(),
            confirmation: confirmation
        )

        #expect(request.confirmedAt == FixedDateProvider.reference.now)
    }
}
