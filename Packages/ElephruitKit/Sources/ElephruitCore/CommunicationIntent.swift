import Foundation

/// Somebody the message was addressed to, as Elephruit understood it at the time.
///
/// ### Why "intended" is part of the name of everything here
/// Once a composer opens, the user owns it. They may add a recipient, remove one, rewrite the
/// subject, or send it to somebody else entirely, and `NSSharingService` does not report any of that
/// back — its callbacks carry the items the *app* supplied, not the message the user sent. So what
/// is stored is what Elephruit asked for, it is labelled as such wherever it is shown, and the app
/// never presents it as a record of what left the machine.
public struct CommunicationRecipient: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID

    /// The address or number, exactly as it was handed over.
    public var handle: String

    /// The person in the library this handle belongs to, when it came from one.
    public var personID: UUID?

    /// The name to show, when there is one.
    public var displayName: String?

    /// Whether this was a blind copy — the recipient nobody else on the message can see.
    public var isBlindCopy: Bool

    public init(
        id: UUID = UUID(),
        handle: String,
        personID: UUID? = nil,
        displayName: String? = nil,
        isBlindCopy: Bool = false
    ) {
        self.id = id
        self.handle = handle
        self.personID = personID
        self.displayName = displayName
        self.isBlindCopy = isBlindCopy
    }

    /// "Maya Chen · maya@example.com", or just the handle.
    public var displayText: String {
        guard let displayName, !displayName.isEmpty else { return handle }
        return "\(displayName) · \(handle)"
    }

    /// The handle reduced to a form two spellings of the same address share.
    ///
    /// Case and surrounding whitespace for an address; digits only for a number, so that
    /// `+1 (512) 555-0192` and `5125550192` match. Deliberately does **not** strip a country code:
    /// two numbers differing by one are two numbers, and this value is used to decide whether two
    /// records are the same message.
    public var matchKey: String {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") { return trimmed.lowercased() }

        let digits = trimmed.filter(\.isNumber)
        return digits.isEmpty ? trimmed.lowercased() : digits
    }
}

/// A file that went with the message, described rather than duplicated.
///
/// Metadata only. The bytes stay wherever the attachment store already put them; copying them into a
/// communication record would double every attached file on disk and give the module a second copy
/// to keep correct.
public struct CommunicationAttachmentReference: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var fileName: String
    public var byteCount: Int?
    public var typeIdentifier: String?

    /// The library attachment this came from, when it came from one.
    public var attachmentID: UUID?

    public init(
        id: UUID = UUID(),
        fileName: String,
        byteCount: Int? = nil,
        typeIdentifier: String? = nil,
        attachmentID: UUID? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.byteCount = byteCount
        self.typeIdentifier = typeIdentifier
        self.attachmentID = attachmentID
    }
}

/// What the user was looking at when they reached for the composer.
public struct CommunicationSourceContext: Sendable, Hashable, Codable {
    /// The task, note, meeting, or person the communication came out of.
    public var itemID: UUID?

    /// What that item is, so a timeline can say "from a task" without another fetch.
    public var itemKind: ItemKind?

    /// The item's title at the time, for a line that survives the item being renamed or trashed.
    public var itemTitle: String?

    public init(itemID: UUID? = nil, itemKind: ItemKind? = nil, itemTitle: String? = nil) {
        self.itemID = itemID
        self.itemKind = itemKind
        self.itemTitle = itemTitle
    }

    public static let none = CommunicationSourceContext()

    public var isEmpty: Bool { itemID == nil && itemTitle == nil }
}

// MARK: - The intent

/// A communication the user asked for, from before it is launched until whatever is finally known
/// about it.
///
/// ### Why an intent exists before anything is sent
/// The alternative is to write a timeline entry when the button is pressed, and that entry is a
/// claim — "emailed Maya" — made on the strength of a composer opening. An intent is not a claim. It
/// is a note that the user set out to do something, carrying what they meant to send, and it becomes
/// an interaction only when something happens that is worth recording as one.
///
/// It is also the identity that the four later signals — a share callback, a confirmation, a
/// provider record, an imported sent message — all attach to, which is what stops one message
/// becoming five timeline rows. See ``CommunicationReconciler``.
///
/// A value type. The stored shape is `ElephruitModel.CommunicationIntentRecord` and the bridge
/// between them is its `asValue()`, so no rule about states or evidence is written twice.
public struct CommunicationIntent: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID

    public var channel: CommunicationChannel

    /// The people in the library this is addressed to.
    public var personIDs: [UUID]

    /// The handles it was addressed to, as Elephruit supplied them.
    public var intendedRecipients: [CommunicationRecipient]

    /// The subject Elephruit supplied. Email only in practice.
    public var intendedSubject: String?

    /// The body Elephruit supplied — **`nil` unless the user opted into retaining content.**
    public var intendedBody: String?

    /// A one-way digest of the body, when the privacy setting permits one.
    public var contentFingerprint: String?

    public var attachments: [CommunicationAttachmentReference]

    public var createdAt: Date

    /// Where it came from.
    public var source: CommunicationSourceContext

    public var launchMechanism: CommunicationLaunchMechanism

    public var state: CommunicationState

    /// Who says so, for the state currently recorded.
    public var evidence: CommunicationEvidence

    /// When the current state was recorded.
    public var stateChangedAt: Date

    /// The provider's identifier for the message, once one exists.
    public var providerMessageID: String?

    /// The provider's identifier for the conversation.
    public var providerThreadID: String?

    /// Which provider verified it, for "verified by Gmail".
    public var providerName: String?

    /// The recipients the provider reported, which may differ from ``intendedRecipients``.
    ///
    /// Populated only from a provider record. Kept apart from the intended ones rather than replacing
    /// them, because "who I meant to write to" and "who the record says it went to" are two facts and
    /// a disagreement between them is worth seeing.
    public var finalRecipients: [CommunicationRecipient]

    public var submittedAt: Date?

    public var failure: CommunicationFailure?

    public var privacy: CommunicationPrivacyPreference

    /// The token an external system can carry back to identify this intent.
    ///
    /// Written into a correlation header by a Mail extension, when one is installed. Meaningless and
    /// harmless without one — see ``CommunicationCorrelation``.
    public var correlationToken: String

    /// The one interaction this communication became, once it earned one.
    ///
    /// By identifier rather than by relationship, for the reason `PersonObservationRecord.supersedesID`
    /// gives: an identifier pointing at a deleted row reads as "no interaction", which is the correct
    /// behaviour, and it needs no inverse or delete rule.
    public var interactionID: UUID?

    /// When the user was last asked whether they sent it.
    public var lastAskedAt: Date?

    /// When the user waved the question away.
    ///
    /// Set once and never cleared. The app asks about a handoff at most twice — once, and once more
    /// if the user said they were still working on it — and after a dismissal it never asks again.
    public var dismissedAt: Date?

    /// How many times the question has been put.
    public var askCount: Int

    public init(
        id: UUID = UUID(),
        channel: CommunicationChannel,
        personIDs: [UUID] = [],
        intendedRecipients: [CommunicationRecipient] = [],
        intendedSubject: String? = nil,
        intendedBody: String? = nil,
        contentFingerprint: String? = nil,
        attachments: [CommunicationAttachmentReference] = [],
        createdAt: Date = Date(),
        source: CommunicationSourceContext = .none,
        launchMechanism: CommunicationLaunchMechanism = .urlScheme,
        state: CommunicationState = .draftPrepared,
        evidence: CommunicationEvidence = .inference,
        stateChangedAt: Date? = nil,
        providerMessageID: String? = nil,
        providerThreadID: String? = nil,
        providerName: String? = nil,
        finalRecipients: [CommunicationRecipient] = [],
        submittedAt: Date? = nil,
        failure: CommunicationFailure? = nil,
        privacy: CommunicationPrivacyPreference = .metadataOnly,
        correlationToken: String = CommunicationCorrelation.makeToken(),
        interactionID: UUID? = nil,
        lastAskedAt: Date? = nil,
        dismissedAt: Date? = nil,
        askCount: Int = 0
    ) {
        self.id = id
        self.channel = channel
        self.personIDs = personIDs
        self.intendedRecipients = intendedRecipients
        self.intendedSubject = intendedSubject
        self.intendedBody = intendedBody
        self.contentFingerprint = contentFingerprint
        self.attachments = attachments
        self.createdAt = createdAt
        self.source = source
        self.launchMechanism = launchMechanism
        self.state = state
        self.evidence = evidence
        self.stateChangedAt = stateChangedAt ?? createdAt
        self.providerMessageID = providerMessageID
        self.providerThreadID = providerThreadID
        self.providerName = providerName
        self.finalRecipients = finalRecipients
        self.submittedAt = submittedAt
        self.failure = failure
        self.privacy = privacy
        self.correlationToken = correlationToken
        self.interactionID = interactionID
        self.lastAskedAt = lastAskedAt
        self.dismissedAt = dismissedAt
        self.askCount = askCount
    }

    /// The handles this was addressed to, normalised for comparison.
    public var recipientMatchKeys: Set<String> {
        Set(intendedRecipients.map(\.matchKey))
    }

    /// Whether the app should put the "did you send this?" question, given the time now.
    ///
    /// Four conditions, all of which have to hold, and each of which corresponds to a way the
    /// question would otherwise become a nuisance:
    ///
    /// - The state is unsettled. Nothing to ask about a message a provider already verified.
    /// - The mechanism reported nothing. A sharing service already answered; asking again after a
    ///   callback is asking the user to do the framework's job.
    /// - The user has not dismissed it. One wave-away is permanent.
    /// - It has been asked at most once before, and not in the last few minutes.
    public func shouldAskForConfirmation(now: Date, minimumInterval: TimeInterval = 300) -> Bool {
        guard !state.isSettled else { return false }
        guard !launchMechanism.reportsCompletion else { return false }
        guard dismissedAt == nil else { return false }
        guard askCount < 2 else { return false }

        guard let lastAskedAt else { return true }
        return now.timeIntervalSince(lastAskedAt) >= minimumInterval
    }

    /// The sentence the confirmation prompt leads with — "Did you send this message to Maya?".
    public func confirmationQuestion() -> String {
        let names = intendedRecipients.compactMap(\.displayName).filter { !$0.isEmpty }
        let subject: String

        switch channel {
        case .email: subject = "this email"
        case .message: subject = "this message"
        case .phoneCall: subject = "this call"
        case .facetimeVideo, .facetimeAudio: subject = "this FaceTime call"
        }

        let verb = channel == .phoneCall || channel == .facetimeVideo || channel == .facetimeAudio
            ? "Did you make"
            : "Did you send"

        guard let first = names.first else { return "\(verb) \(subject)?" }
        let audience = names.count == 1 ? first : "\(first) and \(names.count - 1) other\(names.count == 2 ? "" : "s")"
        return "\(verb) \(subject) to \(audience)?"
    }
}

// MARK: - Transitions

/// What happened to a signal offered to a record.
public enum CommunicationTransitionResult: Sendable, Hashable {
    /// The record moved.
    case applied

    /// The same state from the same kind of source. Recorded as a signal, changes nothing.
    case duplicate

    /// A smaller claim than the record already holds.
    case weakerClaim

    /// A claim this source is not authoritative enough to make against what is already recorded.
    case weakerEvidence

    /// ``CommunicationState/unknown`` is a resting state, never a signal.
    case notASignal

    public var didApply: Bool { self == .applied }
}

/// Whether one signal may overwrite what is already recorded.
///
/// ### The single rule this enforces
/// A communication record only ever gains certainty. Four independent things can report on one
/// message — a framework callback, the user, a provider, an imported record — and they arrive in no
/// guaranteed order. Without a rule, a late-arriving weak signal overwrites a strong one and the
/// timeline says "composer opened" about a message Gmail confirmed an hour ago.
///
/// So a claim may be raised by anything, and lowered only by a source with more authority than the
/// one that made it. That is what makes acceptance scenario 8 — a provider upgrading a record the
/// user already confirmed — work without also letting the reverse happen.
public enum CommunicationTransitionPolicy {
    public static func resolve(
        current: CommunicationState,
        currentEvidence: CommunicationEvidence,
        incoming: CommunicationState,
        incomingEvidence: CommunicationEvidence
    ) -> CommunicationTransitionResult {
        guard incoming != .unknown else { return .notASignal }

        if incoming == current {
            return incomingEvidence.authority > currentEvidence.authority ? .applied : .duplicate
        }

        switch incoming {
        case .failed, .canceled:
            // Taking back a claim that the message left needs a *better* source than the one that
            // made it. Otherwise a stale cancellation callback would undo a confirmed send.
            if current.claimsTheMessageLeft {
                return incomingEvidence.authority > currentEvidence.authority ? .applied : .weakerEvidence
            }
            return incomingEvidence.authority >= currentEvidence.authority ? .applied : .weakerEvidence

        default:
            guard incoming.claimStrength > current.claimStrength else {
                // A stronger source may still correct an equal-or-weaker claim — a provider saying
                // "submitted" about a record the app had only inferred is worth taking.
                if incomingEvidence.authority > currentEvidence.authority, !current.claimsTheMessageLeft {
                    return .applied
                }
                return .weakerClaim
            }
            return .applied
        }
    }
}

// MARK: - Presentation

/// A timeline row's status line, in two parts so that the evidence is never the headline.
public struct CommunicationStatusLabel: Sendable, Hashable {
    /// "Email handed off to your mail app".
    public var headline: String

    /// "recipient intended: maya@example.com". Absent when there is nothing to qualify.
    public var detail: String?

    public var symbolName: String

    /// Whether the row should read as needing attention rather than as routine.
    public var needsAttention: Bool

    public init(headline: String, detail: String? = nil, symbolName: String, needsAttention: Bool = false) {
        self.headline = headline
        self.detail = detail
        self.symbolName = symbolName
        self.needsAttention = needsAttention
    }

    /// "Email handed off to your mail app · recipient intended: maya@example.com".
    public var sentence: String {
        guard let detail, !detail.isEmpty else { return headline }
        return "\(headline) · \(detail)"
    }
}

extension CommunicationStatusLabel {
    /// The label for a communication, built from what is actually known about it.
    ///
    /// Every string this can produce is a statement the app can defend. There is no branch that
    /// returns "Sent" for a composer that merely opened, and none that returns "Delivered" at all
    /// except from ``CommunicationState/delivered``, which nothing in this build can reach.
    public static func make(for intent: CommunicationIntent) -> CommunicationStatusLabel {
        let channel = intent.channel

        switch intent.state {
        case .draftPrepared:
            return CommunicationStatusLabel(
                headline: "\(channel.noun) draft prepared",
                detail: "not opened yet",
                symbolName: "square.and.pencil"
            )

        case .composerOpened:
            return CommunicationStatusLabel(
                headline: channel.hasSharingService
                    ? "\(channel.noun) composer opened"
                    : "\(channel.noun) initiated",
                detail: intent.launchMechanism.reportsCompletion ? "nothing sent yet" : "final sending status unknown",
                symbolName: channel.symbolName
            )

        case .shareCompleted:
            return CommunicationStatusLabel(
                headline: "\(channel.noun) handed off to \(channel.handoffNoun)",
                detail: intendedRecipientDetail(intent),
                symbolName: "arrow.up.forward.app"
            )

        case .submitted:
            return CommunicationStatusLabel(
                headline: "\(channel.noun) submitted",
                detail: evidenceNote(intent),
                symbolName: "paperplane"
            )

        case .userConfirmedSent:
            return CommunicationStatusLabel(
                headline: "\(channel.noun) sent",
                detail: "confirmed by you",
                symbolName: "checkmark.circle"
            )

        case .providerVerifiedSent:
            return CommunicationStatusLabel(
                headline: "\(channel.noun) submitted",
                detail: "verified by \(intent.providerName ?? "your provider")",
                symbolName: "checkmark.seal"
            )

        case .delivered:
            return CommunicationStatusLabel(
                headline: "\(channel.noun) delivered",
                detail: "reported by \(intent.providerName ?? "your provider")",
                symbolName: "checkmark.seal.fill"
            )

        case .failed:
            return CommunicationStatusLabel(
                headline: "\(channel.noun) not sent",
                detail: intent.failure?.summary,
                symbolName: "exclamationmark.triangle",
                needsAttention: true
            )

        case .canceled:
            return CommunicationStatusLabel(
                headline: "\(channel.noun) canceled",
                detail: intent.failure?.summary ?? "nothing was sent",
                symbolName: "xmark.circle"
            )

        case .unknown:
            return CommunicationStatusLabel(
                headline: "\(channel.noun) initiated",
                detail: "final sending status unknown",
                symbolName: "questionmark.circle"
            )
        }
    }

    /// "Call logged · connected · confirmed manually".
    public static func make(for outcome: CallOutcome, channel: CommunicationChannel) -> CommunicationStatusLabel {
        CommunicationStatusLabel(
            headline: "\(channel.noun) logged",
            detail: "\(outcome.displayName.lowercased()) · confirmed manually",
            symbolName: outcome.symbolName
        )
    }

    private static func intendedRecipientDetail(_ intent: CommunicationIntent) -> String? {
        let handles = intent.intendedRecipients.map(\.handle).filter { !$0.isEmpty }
        guard let first = handles.first else { return nil }

        return handles.count == 1
            ? "recipient intended: \(first)"
            : "recipients intended: \(first) and \(handles.count - 1) more"
    }

    private static func evidenceNote(_ intent: CommunicationIntent) -> String {
        switch intent.evidence {
        case .userConfirmation: "confirmed by you"
        case .providerAPI: "verified by \(intent.providerName ?? "your provider")"
        case .importedRecord: "matched to a sent message"
        case .systemCallback: "reported by \(intent.channel.handoffNoun)"
        case .inference: "final sending status unknown"
        }
    }
}
