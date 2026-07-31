import ElephruitCore
import Foundation

/// A message as a provider's own records describe it.
///
/// Everything here comes from the provider. Nothing is inferred, and the fields Elephruit merely
/// *intended* stay on the intent — which is what makes a disagreement between the two visible rather
/// than overwritten.
public struct ProviderMessageRecord: Sendable, Hashable, Identifiable {
    /// The provider's own identifier for the message.
    public var id: String

    /// The provider's identifier for the conversation, when it has one.
    public var threadID: String?

    /// Which provider this came from — "Gmail", "Microsoft 365". Shown as "verified by Gmail".
    public var providerName: String

    /// The recipients the provider recorded, which is what actually went out.
    public var recipients: [CommunicationRecipient]

    public var subject: String?

    /// When the provider says it was submitted.
    public var submittedAt: Date

    /// The correlation token found on the message, when a compose-session extension wrote one.
    public var correlationToken: String?

    /// The body, present only when the user's retention setting asked for it *and* the caller
    /// requested it. Absent by default.
    public var body: String?

    /// A digest of the body, when the privacy setting permits one.
    public var contentFingerprint: String?

    public init(
        id: String,
        threadID: String? = nil,
        providerName: String,
        recipients: [CommunicationRecipient] = [],
        subject: String? = nil,
        submittedAt: Date,
        correlationToken: String? = nil,
        body: String? = nil,
        contentFingerprint: String? = nil
    ) {
        self.id = id
        self.threadID = threadID
        self.providerName = providerName
        self.recipients = recipients
        self.subject = subject
        self.submittedAt = submittedAt
        self.correlationToken = correlationToken
        self.body = body
        self.contentFingerprint = contentFingerprint
    }

    /// The record as a signal, carrying the strongest evidence there is.
    ///
    /// ``CommunicationState/providerVerifiedSent`` and not ``CommunicationState/delivered``: a
    /// provider that returns a sent-message record has told the app the message was submitted and
    /// accepted. Neither Gmail nor Microsoft Graph reports that a human being received it, and there
    /// is no branch anywhere in this module that turns one into the other.
    public func signal(occurredAt: Date? = nil) -> CommunicationSignal {
        CommunicationSignal(
            channel: .email,
            state: .providerVerifiedSent,
            evidence: .providerAPI,
            occurredAt: occurredAt ?? submittedAt,
            correlationToken: correlationToken,
            providerMessageID: id,
            providerThreadID: threadID,
            providerName: providerName,
            recipients: recipients,
            subject: subject,
            contentFingerprint: contentFingerprint
        )
    }
}

/// Which sent messages to look for when reconciling.
public struct ProviderSentQuery: Sendable, Hashable {
    /// The window to search. Bounded on purpose: a reconciliation pass reads the user's sent mail,
    /// and reading more of it than the question needs is not a thing to do casually.
    public var range: Range<Date>

    /// Restrict to messages addressed to these handles. Empty means no restriction.
    public var recipientHandles: [String]

    /// Whether to ask the provider for message bodies.
    ///
    /// **False unless the user's retention setting is ``CommunicationPrivacyPreference/retainContent``.**
    /// A reconciliation needs the subject, the recipients, and the time; the body is a separate ask
    /// with a separate consequence.
    public var includesBodies: Bool

    public init(range: Range<Date>, recipientHandles: [String] = [], includesBodies: Bool = false) {
        self.range = range
        self.recipientHandles = recipientHandles
        self.includesBodies = includesBodies
    }
}

/// A message the user has previewed and told the app to send.
///
/// ### Why this type cannot be constructed casually
/// Its initialiser requires a ``SendConfirmation``, which is only obtainable by calling
/// ``SendConfirmation/granted(previewShownAt:)`` — and the one place that is called is the send
/// sheet, after the user has read what is about to go out and pressed the button. A provider
/// implementation therefore *cannot* be handed something to send that was not previewed, because
/// there is no way to build the argument.
///
/// That is deliberately stronger than a rule in a document. "Do not send email directly through a
/// provider without an explicit preview and send confirmation" is the kind of requirement that
/// survives exactly as long as the person who wrote it, unless the type system carries it.
public struct ConfirmedSendRequest: Sendable, Hashable {
    /// The intent this fulfils.
    public var intentID: UUID

    public var recipients: [CommunicationRecipient]
    public var subject: String?
    public var body: String
    public var attachmentURLs: [URL]

    /// The correlation token to stamp on the outgoing message.
    public var correlationToken: String

    /// When the user saw the preview and agreed.
    public var confirmedAt: Date

    public init(
        intentID: UUID,
        recipients: [CommunicationRecipient],
        subject: String?,
        body: String,
        attachmentURLs: [URL] = [],
        correlationToken: String,
        confirmation: SendConfirmation
    ) {
        self.intentID = intentID
        self.recipients = recipients
        self.subject = subject
        self.body = body
        self.attachmentURLs = attachmentURLs
        self.correlationToken = correlationToken
        self.confirmedAt = confirmation.confirmedAt
    }
}

/// Proof that a human read the preview and pressed send.
///
/// An opaque token with a private initialiser. See ``ConfirmedSendRequest`` for why it exists.
public struct SendConfirmation: Sendable, Hashable {
    public let confirmedAt: Date

    private init(confirmedAt: Date) {
        self.confirmedAt = confirmedAt
    }

    /// Called by the send sheet, once, after the user has seen the message and agreed to send it.
    public static func granted(previewShownAt: Date) -> SendConfirmation {
        SendConfirmation(confirmedAt: previewShownAt)
    }
}

/// What happened when a provider was asked to send.
public enum ProviderSubmissionResult: Sendable, Hashable {
    case submitted(ProviderMessageRecord)
    case failed(CommunicationFailure)

    /// No provider is configured, or the user has not authorised one.
    case unavailable
}

// MARK: - The protocol

/// An email provider that can verify — and, if the user sets one up, perform — a send.
///
/// ### Why this exists with no implementation behind it
/// Everything else in this module tops out at "the user says they sent it", because that is the
/// strongest thing macOS makes knowable about a handoff. A provider API is the only route to
/// anything better, and designing the seam now is what keeps
/// ``CommunicationState/providerVerifiedSent`` an implementable state rather than a decorative one:
/// the reconciler, the transition policy, the timeline label, and the duplicate-prevention rules are
/// all written against this protocol and all tested against a fake conforming to it.
///
/// **No implementation ships.** Elephruit has no network entitlement — see
/// `docs/06-privacy-and-entitlements.md` — so a Gmail or Microsoft Graph conformance cannot be added
/// without also adding one, in the same commit, under standing rule R3.
///
/// ### The rules any implementation must keep
/// - OAuth, and only OAuth. The app never asks for an email password, and there is no field in it
///   that would accept one.
/// - Tokens live in the Keychain. Never in SwiftData, `UserDefaults`, a log, or an export.
/// - ``submit(_:)`` takes a ``ConfirmedSendRequest``, which cannot be built without a preview.
/// - Reading sent mail is bounded by ``ProviderSentQuery`` and reads nothing else. Not the inbox,
///   not other folders, not conversations the user never connected.
public protocol ProviderMessageService: Sendable {
    /// "Gmail", "Microsoft 365". Shown to the user as the source of a verification.
    var providerName: String { get }

    var authorization: IntegrationAuthorization { get async }

    /// Begins the OAuth flow. Never prompts for a password.
    func requestAccess() async -> IntegrationAuthorization

    /// Sends a message the user has previewed and confirmed.
    func submit(_ request: ConfirmedSendRequest) async -> ProviderSubmissionResult

    /// Sent messages matching a bounded query, for reconciling handoffs the app could not observe.
    func sentMessages(matching query: ProviderSentQuery) async -> [ProviderMessageRecord]
}

/// The default, and what every build currently uses.
///
/// Reports ``IntegrationAuthorization/notRequested`` and returns nothing, so the reconciliation and
/// timeline paths run against a real implementation from the first launch rather than a `nil` branch
/// nobody exercises. A user who never configures a provider gets the same code path as one who
/// cannot.
public struct NoProviderMessageService: ProviderMessageService {
    public init() {}

    public var providerName: String { "No provider" }

    public var authorization: IntegrationAuthorization { .notRequested }

    public func requestAccess() async -> IntegrationAuthorization {
        Diagnostics.integrations.debug("Provider access requested but no message provider is configured")
        return .unavailable
    }

    public func submit(_ request: ConfirmedSendRequest) async -> ProviderSubmissionResult { .unavailable }

    public func sentMessages(matching query: ProviderSentQuery) async -> [ProviderMessageRecord] { [] }
}
