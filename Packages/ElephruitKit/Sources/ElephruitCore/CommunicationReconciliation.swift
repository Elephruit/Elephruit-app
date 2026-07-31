import Foundation

/// The header a Mail extension would write, and the token it would carry.
///
/// ### What this is for, and what it is not
/// One message can be reported on by four different things, and only one of them — an extension
/// running inside the compose window — is in a position to say *which* Elephruit intent a given mail
/// corresponds to. A correlation header is how that certainty travels: the extension stamps the
/// intent's token on the outgoing message, and a later sent-mail record carries it back.
///
/// **No extension ships in this build.** The token is generated and stored regardless, because it
/// costs a UUID and because a record written today is worth reconciling if an extension is ever
/// installed. Without one, the header is never written and the reconciler simply falls through to
/// its other rules — which is why nothing here is required for ordinary use.
///
/// The token is a bare UUID. It names an intent and nothing else: no person, no address, no subject.
/// A header that leaked who a message was about would be a privacy failure visible to every server
/// the mail passed through.
public enum CommunicationCorrelation {
    /// The `X-` header name. Application-specific, and prefixed so it cannot collide with a
    /// standard field.
    public static let headerName = "X-Elephruit-Communication"

    public static func makeToken() -> String {
        UUID().uuidString
    }

    public static func headerValue(for token: String) -> String { token }

    /// The token in a header value, or `nil` when it is not one this app wrote.
    ///
    /// Validates the shape rather than trusting it: a header is attacker-controllable text arriving
    /// from outside, and the reconciler treats a token as proof of identity.
    public static func token(fromHeaderValue value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: trimmed) != nil else { return nil }
        return trimmed.uppercased()
    }
}

// MARK: - Signals

/// One report about a communication, from any of the four sources that can produce one.
///
/// Deliberately uniform. A share callback, a user's answer, a provider submission, and an imported
/// sent-message record differ in what they can prove and in nothing else, so they are one type with
/// an ``CommunicationEvidence`` on it rather than four types with four reconcilers.
public struct CommunicationSignal: Sendable, Hashable {
    public var channel: CommunicationChannel
    public var state: CommunicationState
    public var evidence: CommunicationEvidence
    public var occurredAt: Date

    /// The intent this is known to belong to. Present when the app started the communication itself.
    public var intentID: UUID?

    /// The correlation token carried back by a Mail extension, when one is installed.
    public var correlationToken: String?

    public var providerMessageID: String?
    public var providerThreadID: String?
    public var providerName: String?

    /// The recipients the source reported.
    public var recipients: [CommunicationRecipient]

    public var subject: String?

    /// A digest of the content, when both sides are permitted to hold one.
    public var contentFingerprint: String?

    public var failure: CommunicationFailure?

    public init(
        channel: CommunicationChannel,
        state: CommunicationState,
        evidence: CommunicationEvidence,
        occurredAt: Date,
        intentID: UUID? = nil,
        correlationToken: String? = nil,
        providerMessageID: String? = nil,
        providerThreadID: String? = nil,
        providerName: String? = nil,
        recipients: [CommunicationRecipient] = [],
        subject: String? = nil,
        contentFingerprint: String? = nil,
        failure: CommunicationFailure? = nil
    ) {
        self.channel = channel
        self.state = state
        self.evidence = evidence
        self.occurredAt = occurredAt
        self.intentID = intentID
        self.correlationToken = correlationToken
        self.providerMessageID = providerMessageID
        self.providerThreadID = providerThreadID
        self.providerName = providerName
        self.recipients = recipients
        self.subject = subject
        self.contentFingerprint = contentFingerprint
        self.failure = failure
    }
}

/// Why the reconciler believes a signal belongs to an intent.
///
/// Stored alongside the match so that a merge can be explained and, if it turns out to be wrong,
/// found again. The first three are identities; the fourth is a judgement, and it is the only one
/// that can be mistaken.
public enum CommunicationMatchBasis: String, Sendable, Hashable, Codable, CaseIterable {
    case intentIdentifier
    case correlationHeader
    case providerMessageID
    case recipientSubjectAndTime

    /// Whether the match is an identity rather than an inference.
    public var isExact: Bool { self != .recipientSubjectAndTime }

    public var displayName: String {
        switch self {
        case .intentIdentifier: "Started here"
        case .correlationHeader: "Matched by message header"
        case .providerMessageID: "Matched by provider message"
        case .recipientSubjectAndTime: "Matched by recipient, subject, and time"
        }
    }
}

public struct CommunicationMatch: Sendable, Hashable {
    public var intentID: UUID
    public var basis: CommunicationMatchBasis

    public init(intentID: UUID, basis: CommunicationMatchBasis) {
        self.intentID = intentID
        self.basis = basis
    }
}

public enum CommunicationMatchOutcome: Sendable, Hashable {
    case matched(CommunicationMatch)

    /// Several intents fit equally well. **Nothing is merged.**
    case ambiguous([UUID])

    case noMatch

    public var match: CommunicationMatch? {
        if case .matched(let match) = self { return match }
        return nil
    }
}

// MARK: - The reconciler

/// Decides which existing intent a signal belongs to, or that it belongs to none.
///
/// ### Why this refuses rather than guesses
/// The failure this prevents is not a missing row. It is *merging two different messages* — writing
/// a provider's record of one email onto the intent for another, so that the timeline shows a
/// message the user never sent to a person they never sent it to, with a verification badge on it.
/// That is worse than a duplicate row, because a duplicate is visibly a duplicate and a bad merge is
/// not.
///
/// So: an exact identity wins immediately, a heuristic match must satisfy every condition at once,
/// and two candidates that both satisfy them produce ``CommunicationMatchOutcome/ambiguous(_:)``
/// rather than a coin toss. The caller's correct response to `ambiguous` and to `noMatch` is the
/// same — leave the intents alone — and the two are distinguished only so the situation can be
/// logged and, if it recurs, understood.
public enum CommunicationReconciler {
    /// How far apart a signal and an intent may be and still be the same message.
    ///
    /// Thirty minutes. Long enough for somebody to open a composer, get distracted, and send; short
    /// enough that two emails to the same person about the same subject on the same afternoon are
    /// not assumed to be one. It is a parameter because the right answer depends on the source: a
    /// sent-mail import reconciling a week of history wants a tighter window, not a looser one.
    public static let defaultWindow: TimeInterval = 30 * 60

    public static func match(
        signal: CommunicationSignal,
        against candidates: [CommunicationIntent],
        window: TimeInterval = defaultWindow
    ) -> CommunicationMatchOutcome {
        // 1. The app started it and said so. An identifier that resolves is the end of the question;
        //    one that does not is *not* an invitation to fall through and guess, because a caller
        //    that supplied an identifier believed it knew, and a wrong merge is worse than none.
        if let intentID = signal.intentID {
            guard candidates.contains(where: { $0.id == intentID }) else { return .noMatch }
            return .matched(CommunicationMatch(intentID: intentID, basis: .intentIdentifier))
        }

        // 2. A correlation header written into the message itself.
        if let token = signal.correlationToken.flatMap(CommunicationCorrelation.token(fromHeaderValue:)) {
            let hits = candidates.filter { $0.correlationToken.uppercased() == token }
            if hits.count == 1, let hit = hits.first {
                return .matched(CommunicationMatch(intentID: hit.id, basis: .correlationHeader))
            }
            if hits.count > 1 { return .ambiguous(hits.map(\.id)) }
        }

        // 3. A provider message identifier already recorded against an intent — the second report
        //    about a message the app has already reconciled once.
        if let messageID = signal.providerMessageID, !messageID.isEmpty {
            let hits = candidates.filter { $0.providerMessageID == messageID }
            if hits.count == 1, let hit = hits.first {
                return .matched(CommunicationMatch(intentID: hit.id, basis: .providerMessageID))
            }
            if hits.count > 1 { return .ambiguous(hits.map(\.id)) }
        }

        // 4. The judgement. Every condition, or nothing.
        let plausible = candidates.filter { isPlausible(signal: signal, intent: $0, window: window) }

        switch plausible.count {
        case 0: return .noMatch
        case 1:
            guard let only = plausible.first else { return .noMatch }
            return .matched(CommunicationMatch(intentID: only.id, basis: .recipientSubjectAndTime))
        default: return .ambiguous(plausible.map(\.id))
        }
    }

    /// Whether a signal could be about this intent, on every axis at once.
    static func isPlausible(signal: CommunicationSignal, intent: CommunicationIntent, window: TimeInterval) -> Bool {
        guard signal.channel == intent.channel else { return false }

        // An intent already tied to a different provider message is a different message. This is the
        // check that keeps a second email in the same thread from landing on the first one's record.
        if let existing = intent.providerMessageID, let incoming = signal.providerMessageID,
           existing != incoming {
            return false
        }

        guard abs(signal.occurredAt.timeIntervalSince(intent.createdAt)) <= window else { return false }

        // At least one recipient in common. Not *all* — a user who added somebody in the composer
        // still sent the message the intent was about — but a message sharing no recipient at all
        // with the intent is not that message.
        let signalKeys = Set(signal.recipients.map(\.matchKey)).subtracting([""])
        let intentKeys = intent.recipientMatchKeys.subtracting([""])
        guard !signalKeys.isEmpty, !intentKeys.isEmpty, !signalKeys.isDisjoint(with: intentKeys) else {
            return false
        }

        guard subjectsAgree(signal.subject, intent.intendedSubject) else { return false }

        // Fingerprints are corroboration, never grounds on their own: when both sides hold one they
        // must agree, and when either is missing the other conditions decide. A digest exists only
        // when the user opted into one, so requiring it would make matching worse for the default.
        if let left = signal.contentFingerprint, let right = intent.contentFingerprint, left != right {
            return false
        }

        return true
    }

    /// Whether two subjects are the same subject.
    ///
    /// Both absent counts as agreement — a Messages conversation has no subject and never will, so
    /// requiring one would disqualify every message signal. One present and the other absent does
    /// not: the app supplied a subject and the record has none, which is a discrepancy rather than a
    /// silence.
    static func subjectsAgree(_ left: String?, _ right: String?) -> Bool {
        let leftFolded = left.map(TextNormalizer.foldedForMatching)?.trimmingCharacters(in: .whitespaces)
        let rightFolded = right.map(TextNormalizer.foldedForMatching)?.trimmingCharacters(in: .whitespaces)

        switch (leftFolded?.isEmpty == false ? leftFolded : nil, rightFolded?.isEmpty == false ? rightFolded : nil) {
        case (nil, nil): return true
        case (let a?, let b?): return a == b
        default: return false
        }
    }
}
