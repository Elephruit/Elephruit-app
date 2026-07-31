import Foundation

/// Everything needed to open somebody else's composer, and nothing more.
///
/// The body is optional and, under the default privacy setting, is supplied to the composer without
/// ever being stored. Passing text through to another application and keeping a copy of it are two
/// separate decisions, and only the second one is the user's to make.
public struct CommunicationLaunchRequest: Sendable, Hashable, Identifiable {
    /// The intent this belongs to. Carried through so that whatever comes back can be attributed
    /// without guessing — see ``CommunicationReconciler``.
    public var id: UUID

    public var channel: CommunicationChannel
    public var recipients: [CommunicationRecipient]
    public var subject: String?
    public var body: String?

    /// Files to attach, where they already live. Nothing is copied.
    public var attachmentURLs: [URL]

    /// Which mechanism the caller would rather use, if it is available.
    public var preferredMechanism: CommunicationLaunchMechanism

    public init(
        id: UUID,
        channel: CommunicationChannel,
        recipients: [CommunicationRecipient],
        subject: String? = nil,
        body: String? = nil,
        attachmentURLs: [URL] = [],
        preferredMechanism: CommunicationLaunchMechanism = .sharingService
    ) {
        self.id = id
        self.channel = channel
        self.recipients = recipients
        self.subject = subject
        self.body = body
        self.attachmentURLs = attachmentURLs
        self.preferredMechanism = preferredMechanism
    }

    public var recipientHandles: [String] {
        recipients.map(\.handle).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

// MARK: - Outcomes

/// What a launcher observed. **Each case is the strongest thing it is entitled to say.**
///
/// ### On `shareCompleted`, which is the one that misleads
/// `sharingService(_:didShareItems:)` means the sharing service reported that sharing finished. It
/// does **not** mean a server accepted the mail, that the recipient received it, that the final body
/// matches the one supplied, or that the final recipients match the ones supplied. AppKit gives the
/// app the items *it* handed over, not the message the user sent. Anything stronger than "handed
/// off" is the app inventing a fact.
public enum CommunicationLaunchOutcome: Sendable, Hashable {
    /// The composer is open. Nothing has been sent, and for a URL scheme nothing further will ever
    /// be reported.
    case composerOpened

    /// The sharing service finished. See the note above for what that is and is not.
    case shareCompleted

    /// The user closed the composer without sending, as far as the framework reported.
    case canceled(CommunicationFailure)

    /// The handoff itself failed — no handler, a malformed destination, a framework error.
    case failed(CommunicationFailure)

    /// No launcher is configured for this channel. Nothing was attempted.
    case unavailable

    /// The state this outcome justifies, and no more.
    public var state: CommunicationState {
        switch self {
        case .composerOpened: .composerOpened
        case .shareCompleted: .shareCompleted
        case .canceled: .canceled
        case .failed: .failed
        case .unavailable: .draftPrepared
        }
    }

    public var failure: CommunicationFailure? {
        switch self {
        case .canceled(let failure), .failed(let failure): failure
        case .composerOpened, .shareCompleted, .unavailable: nil
        }
    }
}

/// What a launcher reported, and when.
public struct CommunicationLaunchReport: Sendable, Hashable {
    /// The intent the report is about.
    public var intentID: UUID

    public var channel: CommunicationChannel
    public var mechanism: CommunicationLaunchMechanism
    public var outcome: CommunicationLaunchOutcome
    public var occurredAt: Date

    public init(
        intentID: UUID,
        channel: CommunicationChannel,
        mechanism: CommunicationLaunchMechanism,
        outcome: CommunicationLaunchOutcome,
        occurredAt: Date
    ) {
        self.intentID = intentID
        self.channel = channel
        self.mechanism = mechanism
        self.outcome = outcome
        self.occurredAt = occurredAt
    }

    /// The report as a signal the reconciler can weigh against the record.
    ///
    /// Always ``CommunicationEvidence/systemCallback``: everything a launcher knows, it learned from
    /// a framework. It carries the intent identifier, so this signal never needs to be matched by
    /// guesswork.
    public var signal: CommunicationSignal {
        CommunicationSignal(
            channel: channel,
            state: outcome.state,
            evidence: .systemCallback,
            occurredAt: occurredAt,
            intentID: intentID,
            failure: outcome.failure
        )
    }
}
