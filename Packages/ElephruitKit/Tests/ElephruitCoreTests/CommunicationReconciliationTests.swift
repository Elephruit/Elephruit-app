import ElephruitCore
import Foundation
import Testing

/// Matching a report to the message it is about — and, far more often, refusing to.
///
/// The failure being guarded against is not a missing row. It is writing a provider's record of one
/// email onto the intent for another, so that the timeline shows a message the user never sent to a
/// person they never sent it to, with a verification badge on it. A duplicate row is visibly a
/// duplicate; a bad merge is not.
@Suite("Communication reconciliation")
struct CommunicationReconciliationTests {
    private let base = FixedDateProvider.reference.now

    private func intent(
        id: UUID = UUID(),
        channel: CommunicationChannel = .email,
        recipients: [String] = ["maya@example.com"],
        subject: String? = "Lunch",
        createdOffset: TimeInterval = 0,
        fingerprint: String? = nil,
        providerMessageID: String? = nil,
        correlationToken: String = CommunicationCorrelation.makeToken()
    ) -> CommunicationIntent {
        CommunicationIntent(
            id: id,
            channel: channel,
            intendedRecipients: recipients.map { CommunicationRecipient(handle: $0) },
            intendedSubject: subject,
            contentFingerprint: fingerprint,
            createdAt: base.addingTimeInterval(createdOffset),
            providerMessageID: providerMessageID,
            correlationToken: correlationToken
        )
    }

    private func signal(
        channel: CommunicationChannel = .email,
        recipients: [String] = ["maya@example.com"],
        subject: String? = "Lunch",
        offset: TimeInterval = 60,
        intentID: UUID? = nil,
        correlationToken: String? = nil,
        providerMessageID: String? = nil,
        fingerprint: String? = nil
    ) -> CommunicationSignal {
        CommunicationSignal(
            channel: channel,
            state: .providerVerifiedSent,
            evidence: .providerAPI,
            occurredAt: base.addingTimeInterval(offset),
            intentID: intentID,
            correlationToken: correlationToken,
            providerMessageID: providerMessageID,
            recipients: recipients.map { CommunicationRecipient(handle: $0) },
            subject: subject,
            contentFingerprint: fingerprint
        )
    }

    // MARK: Exact identities

    @Test("An identifier the app supplied ends the question")
    func intentIdentifierWins() {
        let target = intent()
        let other = intent()

        let outcome = CommunicationReconciler.match(
            signal: signal(intentID: target.id),
            against: [other, target]
        )

        #expect(outcome.match?.intentID == target.id)
        #expect(outcome.match?.basis == .intentIdentifier)
    }

    @Test("An identifier that resolves to nothing is not an invitation to guess")
    func anUnresolvedIdentifierMatchesNothing() {
        // The caller believed it knew which record this belonged to and was wrong. Falling through
        // to the heuristic here would take a *stated* identity and quietly replace it with a guess,
        // which is the worst available outcome even though the heuristic would have matched.
        let plausible = intent()

        let outcome = CommunicationReconciler.match(
            signal: signal(intentID: UUID()),
            against: [plausible]
        )

        #expect(outcome == .noMatch)
    }

    @Test("A correlation header identifies the message it was stamped on")
    func correlationHeaderMatches() {
        let token = CommunicationCorrelation.makeToken()
        let target = intent(correlationToken: token)
        let decoy = intent(recipients: ["someone@example.com"], subject: "Different")

        let outcome = CommunicationReconciler.match(
            signal: signal(correlationToken: token.lowercased()),
            against: [decoy, target]
        )

        #expect(outcome.match?.intentID == target.id)
        #expect(outcome.match?.basis == .correlationHeader)
    }

    @Test("A header that is not one this app wrote is ignored")
    func malformedTokensAreRejected() {
        // A header arrives from outside and is attacker-controllable, and the reconciler treats a
        // token as proof of identity — so the shape is validated rather than trusted.
        #expect(CommunicationCorrelation.token(fromHeaderValue: "not-a-uuid") == nil)
        #expect(CommunicationCorrelation.token(fromHeaderValue: "") == nil)
        #expect(CommunicationCorrelation.token(fromHeaderValue: "  ") == nil)

        let valid = UUID().uuidString
        #expect(CommunicationCorrelation.token(fromHeaderValue: " \(valid.lowercased()) ") == valid.uppercased())
    }

    @Test("A provider message already recorded is the same message")
    func providerMessageIdentifiersMatch() {
        let target = intent(providerMessageID: "gmail-1")
        let outcome = CommunicationReconciler.match(
            signal: signal(providerMessageID: "gmail-1"),
            against: [intent(), target]
        )

        #expect(outcome.match?.intentID == target.id)
        #expect(outcome.match?.basis == .providerMessageID)
    }

    // MARK: The judgement

    @Test("Recipient, subject, and time together are enough")
    func theHeuristicMatchesWhenEverythingAgrees() {
        let target = intent()
        let outcome = CommunicationReconciler.match(signal: signal(), against: [target])

        #expect(outcome.match?.intentID == target.id)
        #expect(outcome.match?.basis == .recipientSubjectAndTime)
        #expect(outcome.match?.basis.isExact == false, "a judgement must not be presented as an identity")
    }

    @Test("Two equally plausible records means neither is touched")
    func ambiguityRefusesToGuess() {
        // Two emails to the same person about the same thing, minutes apart. Nothing here can tell
        // them apart, so nothing here gets to choose.
        let first = intent(createdOffset: 0)
        let second = intent(createdOffset: 120)

        let outcome = CommunicationReconciler.match(signal: signal(offset: 60), against: [first, second])

        guard case .ambiguous(let ids) = outcome else {
            Issue.record("expected an ambiguous outcome, got \(outcome)")
            return
        }
        #expect(Set(ids) == [first.id, second.id])
        #expect(outcome.match == nil)
    }

    @Test("A different person is a different message")
    func recipientsMustOverlap() {
        let outcome = CommunicationReconciler.match(
            signal: signal(recipients: ["someone.else@example.com"]),
            against: [intent()]
        )
        #expect(outcome == .noMatch)
    }

    @Test("A different subject is a different message")
    func subjectsMustAgree() {
        let outcome = CommunicationReconciler.match(
            signal: signal(subject: "Something else entirely"),
            against: [intent()]
        )
        #expect(outcome == .noMatch)
    }

    @Test("A subject on one side and none on the other is a discrepancy, not a silence")
    func aMissingSubjectDoesNotMatchAPresentOne() {
        #expect(CommunicationReconciler.match(signal: signal(subject: nil), against: [intent()]) == .noMatch)
        #expect(
            CommunicationReconciler.match(signal: signal(), against: [intent(subject: nil)]) == .noMatch
        )

        // Two messages that never had a subject do agree, which is what makes the rule usable for
        // Messages — a conversation has no subject and never will.
        let conversation = intent(channel: .message, recipients: ["(512) 555-0192"], subject: nil)
        let reply = signal(channel: .message, recipients: ["512-555-0192"], subject: nil)
        #expect(CommunicationReconciler.match(signal: reply, against: [conversation]).match != nil)
    }

    @Test("A country code is not stripped, and that is deliberate")
    func numbersAreComparedStrictly() {
        // `+15125550192` and `5125550192` do not match, and making them match would mean deciding
        // that a leading `1` is a country code rather than part of the number — which is true in
        // North America and false in several other plans.
        //
        // The reason this costs nothing: email is the only channel with a provider that can report
        // a send, and email addresses normalise cleanly. There is no supported API that reports a
        // Messages send to a third-party app, so a number reported by one source and stored by
        // another is a situation this module does not have. Adding a lenient rule nothing exercises
        // would buy a class of wrong merge for no benefit.
        let stored = CommunicationIntent(
            channel: .message,
            intendedRecipients: [CommunicationRecipient(handle: "5125550192")],
            intendedSubject: nil,
            createdAt: base
        )
        let international = signal(
            channel: .message, recipients: ["+1 (512) 555-0192"], subject: nil, offset: 60
        )

        #expect(CommunicationReconciler.match(signal: international, against: [stored]) == .noMatch)
    }

    @Test("A different channel is a different message")
    func channelsMustAgree() {
        let outcome = CommunicationReconciler.match(
            signal: signal(channel: .message, recipients: ["maya@example.com"], subject: nil),
            against: [intent()]
        )
        #expect(outcome == .noMatch)
    }

    @Test("Outside the window is a different message")
    func theTimeWindowIsEnforced() {
        let outcome = CommunicationReconciler.match(
            signal: signal(offset: CommunicationReconciler.defaultWindow + 60),
            against: [intent()]
        )
        #expect(outcome == .noMatch)
    }

    @Test("Disagreeing fingerprints rule a match out; a missing one does not rule it in or out")
    func fingerprintsCorroborateOnly() {
        let target = intent(fingerprint: "aaa")

        #expect(
            CommunicationReconciler.match(signal: signal(fingerprint: "bbb"), against: [target]) == .noMatch,
            "two different bodies are two different messages"
        )
        #expect(
            CommunicationReconciler.match(signal: signal(fingerprint: "aaa"), against: [target]).match != nil
        )
        #expect(
            CommunicationReconciler.match(signal: signal(), against: [target]).match != nil,
            "the default privacy setting stores no digest, so requiring one would break matching for it"
        )
    }

    @Test("A record already tied to another provider message is not this one")
    func adoptedRecordsAreExcluded() {
        // The check that stops a second email in a thread landing on the first one's record.
        let taken = intent(providerMessageID: "gmail-1")
        let outcome = CommunicationReconciler.match(signal: signal(providerMessageID: "gmail-2"), against: [taken])
        #expect(outcome == .noMatch)
    }

    @Test("A number written two ways is one number")
    func handlesAreNormalisedForMatching() {
        #expect(CommunicationRecipient(handle: "+1 (512) 555-0192").matchKey == "15125550192")
        #expect(CommunicationRecipient(handle: "  Maya@Example.COM ").matchKey == "maya@example.com")

        // Not so normalised that two different numbers collide: dropping a country code to make
        // these agree would merge two people who differ by one digit.
        #expect(
            CommunicationRecipient(handle: "5125550192").matchKey
                != CommunicationRecipient(handle: "5125550193").matchKey
        )
    }

    @Test("No candidates at all is a clean miss")
    func nothingToMatchAgainst() {
        #expect(CommunicationReconciler.match(signal: signal(), against: []) == .noMatch)
    }
}
