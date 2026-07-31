import ElephruitCore
import Foundation
import SwiftData

/// A communication the user set out to have, and everything since learned about it.
///
/// ### Why the intent is stored and the interaction is not, at first
/// Writing a timeline entry when the user presses *Email* means writing the sentence "emailed Maya"
/// on the evidence of a composer opening. This record is the alternative: it holds what the user
/// meant to send and what is known about whether it happened, and it becomes an interaction — one
/// interaction — only when something says it should. See
/// ``ElephruitPersistence/CommunicationService``.
///
/// ### Why the history is rows and the state is a column
/// The same argument ``PersonObservationRecord`` makes. The *current* state is one value and belongs
/// in a column; the sequence of reports that produced it is history, and history is rows — which is
/// what lets a row answer "who says this was sent" for every status it ever held, rather than only
/// the last one.
///
/// **CloudKit compliance**, on the same terms as every other entity here: every attribute has a
/// default, no unique constraints, every to-one relationship optional with a declared inverse, and
/// no `.deny` delete rule.
@Model
public final class CommunicationIntentRecord {
    /// Unsettled records are swept on every return to the app, newest first.
    #Index<CommunicationIntentRecord>([\.createdAt], [\.stateRaw])

    public var id: UUID = UUID()

    /// ``ElephruitCore/CommunicationChannel`` raw value.
    ///
    /// A string, like ``Item/kindRaw``, so a channel written by a newer build reads back rather than
    /// collapsing into a catch-all.
    public var channelRaw: String = CommunicationChannel.email.rawValue

    /// ``ElephruitCore/CommunicationState`` raw value.
    public var stateRaw: String = CommunicationState.draftPrepared.rawValue

    /// ``ElephruitCore/CommunicationEvidence`` raw value — who says so, for the state above.
    public var evidenceRaw: String = CommunicationEvidence.inference.rawValue

    /// ``ElephruitCore/CommunicationLaunchMechanism`` raw value.
    public var mechanismRaw: String = CommunicationLaunchMechanism.urlScheme.rawValue

    /// ``ElephruitCore/CommunicationPrivacyPreference`` raw value, as it was **when this was written**.
    ///
    /// Stored per record rather than read from the current setting, so that turning content retention
    /// off later does not make an already-stored body look as though it was never permitted — and so
    /// that turning it on does not retroactively claim a body exists for records that have none.
    public var privacyRaw: String = CommunicationPrivacyPreference.metadataOnly.rawValue

    /// The linked people, as comma-separated identifiers.
    ///
    /// Identifiers rather than relationships: a communication may name several people, an
    /// intent outlives any of them being merged or trashed, and a dangling identifier reads as
    /// "that person is gone" — which is correct, and needs no inverse or delete rule.
    public var personIDsRaw: String = ""

    /// ``ElephruitCore/CommunicationRecipient`` values, JSON-encoded.
    ///
    /// One column rather than a child entity, because recipients are only ever read and written whole
    /// with the intent and are never queried across. `SystemContactLink.identitySignature` makes the
    /// same trade for the same reason.
    public var recipientsRaw: String = ""

    /// The recipients a provider reported, when one did. Kept apart from the intended ones.
    public var finalRecipientsRaw: String = ""

    public var intendedSubject: String?

    /// The drafted body — **`nil` unless the record's own privacy setting permits retaining it**.
    ///
    /// ``ElephruitPersistence/CommunicationService`` is the only writer and refuses to set it under
    /// any other setting; `CommunicationPrivacyTests` asserts the refusal.
    public var intendedBody: String?

    /// A one-way digest of the body, present only when the privacy setting permits one.
    public var contentFingerprint: String?

    /// ``ElephruitCore/CommunicationAttachmentReference`` values, JSON-encoded. Metadata only; the
    /// bytes stay in the attachment store.
    public var attachmentsRaw: String = ""

    public var createdAt: Date = Date()
    public var stateChangedAt: Date = Date()

    // MARK: Source context

    public var sourceItemID: UUID?
    public var sourceItemKindRaw: String?
    public var sourceItemTitle: String?

    // MARK: Provider

    public var providerMessageID: String?
    public var providerThreadID: String?
    public var providerName: String?
    public var submittedAt: Date?

    // MARK: Failure

    public var failureSummary: String?
    public var failureTechnicalDetail: String?
    public var failureWasCanceledByUser: Bool = false

    /// ``ElephruitCore/CallOutcome`` raw value, once the user has said how a call went.
    ///
    /// Separate from the state because it answers a different question. The state says whether the
    /// communication went out — for a call, whether it was placed and reported — and the outcome says
    /// what happened when it did. Collapsing them made a call that reached voicemail read as "Call
    /// sent · confirmed by you" and count toward the last-contact line.
    public var callOutcomeRaw: String?

    // MARK: Identity and reconciliation

    /// The token a Mail extension would stamp on the outgoing message. A bare UUID naming this
    /// record and nothing else — see ``ElephruitCore/CommunicationCorrelation``.
    public var correlationToken: String = CommunicationCorrelation.makeToken()

    /// The one interaction this became, by identifier. Never more than one.
    public var interactionID: UUID?

    // MARK: The confirmation question

    public var lastAskedAt: Date?

    /// Set the first time the user waves the question away, and never cleared.
    public var dismissedAt: Date?

    public var askCount: Int = 0

    // MARK: Relationships

    /// Every report received about this communication, in the order they arrived.
    @Relationship(deleteRule: .cascade, inverse: \CommunicationEventRecord.intent)
    public var events: [CommunicationEventRecord] = []

    public init(
        id: UUID = UUID(),
        channel: CommunicationChannel = .email,
        state: CommunicationState = .draftPrepared,
        evidence: CommunicationEvidence = .inference,
        mechanism: CommunicationLaunchMechanism = .urlScheme,
        privacy: CommunicationPrivacyPreference = .metadataOnly,
        createdAt: Date = Date(),
        correlationToken: String = CommunicationCorrelation.makeToken()
    ) {
        self.id = id
        self.channelRaw = channel.rawValue
        self.stateRaw = state.rawValue
        self.evidenceRaw = evidence.rawValue
        self.mechanismRaw = mechanism.rawValue
        self.privacyRaw = privacy.rawValue
        self.createdAt = createdAt
        self.stateChangedAt = createdAt
        self.correlationToken = correlationToken
    }
}

extension CommunicationIntentRecord {
    public var channel: CommunicationChannel {
        get { CommunicationChannel(rawValue: channelRaw) ?? .email }
        set { channelRaw = newValue.rawValue }
    }

    /// The current state.
    ///
    /// An unreadable raw value reads as ``ElephruitCore/CommunicationState/unknown`` rather than as
    /// anything more confident. A state written by a build this one has never heard of must not be
    /// guessed *upward* into a claim that the message was sent.
    public var state: CommunicationState {
        get { CommunicationState(rawValue: stateRaw) ?? .unknown }
        set { stateRaw = newValue.rawValue }
    }

    public var evidence: CommunicationEvidence {
        get { CommunicationEvidence(rawValue: evidenceRaw) ?? .inference }
        set { evidenceRaw = newValue.rawValue }
    }

    public var mechanism: CommunicationLaunchMechanism {
        get { CommunicationLaunchMechanism(rawValue: mechanismRaw) ?? .urlScheme }
        set { mechanismRaw = newValue.rawValue }
    }

    /// The privacy setting under which this record was written.
    ///
    /// Falls back to ``ElephruitCore/CommunicationPrivacyPreference/metadataOnly`` — the strictest —
    /// when the raw value is unreadable, so an unknown setting never reads as permission to keep more.
    public var privacy: CommunicationPrivacyPreference {
        get { CommunicationPrivacyPreference(rawValue: privacyRaw) ?? .metadataOnly }
        set { privacyRaw = newValue.rawValue }
    }

    public var personIDs: [UUID] {
        get { personIDsRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) } }
        set { personIDsRaw = newValue.map(\.uuidString).joined(separator: ",") }
    }

    public var intendedRecipients: [CommunicationRecipient] {
        get { CommunicationJSON.decode([CommunicationRecipient].self, from: recipientsRaw) ?? [] }
        set { recipientsRaw = CommunicationJSON.encode(newValue) }
    }

    public var finalRecipients: [CommunicationRecipient] {
        get { CommunicationJSON.decode([CommunicationRecipient].self, from: finalRecipientsRaw) ?? [] }
        set { finalRecipientsRaw = CommunicationJSON.encode(newValue) }
    }

    public var attachments: [CommunicationAttachmentReference] {
        get { CommunicationJSON.decode([CommunicationAttachmentReference].self, from: attachmentsRaw) ?? [] }
        set { attachmentsRaw = CommunicationJSON.encode(newValue) }
    }

    public var failure: CommunicationFailure? {
        get {
            guard let failureSummary else { return nil }
            return CommunicationFailure(
                summary: failureSummary,
                technicalDetail: failureTechnicalDetail,
                wasCanceledByUser: failureWasCanceledByUser
            )
        }
        set {
            failureSummary = newValue?.summary
            failureTechnicalDetail = newValue?.technicalDetail
            failureWasCanceledByUser = newValue?.wasCanceledByUser ?? false
        }
    }

    public var callOutcome: CallOutcome? {
        get { callOutcomeRaw.flatMap(CallOutcome.init(rawValue:)) }
        set { callOutcomeRaw = newValue?.rawValue }
    }

    public var source: CommunicationSourceContext {
        get {
            CommunicationSourceContext(
                itemID: sourceItemID,
                itemKind: sourceItemKindRaw.flatMap(ItemKind.init(rawValue:)),
                itemTitle: sourceItemTitle
            )
        }
        set {
            sourceItemID = newValue.itemID
            sourceItemKindRaw = newValue.itemKind?.rawValue
            sourceItemTitle = newValue.itemTitle
        }
    }

    /// The `Sendable` value every rule is written against.
    public func asValue() -> CommunicationIntent {
        CommunicationIntent(
            id: id,
            channel: channel,
            personIDs: personIDs,
            intendedRecipients: intendedRecipients,
            intendedSubject: intendedSubject,
            intendedBody: intendedBody,
            contentFingerprint: contentFingerprint,
            attachments: attachments,
            createdAt: createdAt,
            source: source,
            launchMechanism: mechanism,
            state: state,
            evidence: evidence,
            stateChangedAt: stateChangedAt,
            providerMessageID: providerMessageID,
            providerThreadID: providerThreadID,
            providerName: providerName,
            finalRecipients: finalRecipients,
            submittedAt: submittedAt,
            failure: failure,
            callOutcome: callOutcome,
            privacy: privacy,
            correlationToken: correlationToken,
            interactionID: interactionID,
            lastAskedAt: lastAskedAt,
            dismissedAt: dismissedAt,
            askCount: askCount
        )
    }

    /// Every report received, oldest first.
    public var orderedEvents: [CommunicationEventRecord] {
        events.sorted { $0.recordedAt < $1.recordedAt }
    }
}

// MARK: - Events

/// One report about a communication, kept whether or not it changed anything.
///
/// ### Why the ignored ones are kept too
/// A signal that did not move the record is the interesting one. It is how a late cancellation
/// callback arriving after a confirmed send is explained, and how a merge that should not have
/// happened is found afterwards. Discarding them would leave the record saying only what it
/// currently believes, with no way to ask why.
@Model
public final class CommunicationEventRecord {
    public var id: UUID = UUID()

    /// ``ElephruitCore/CommunicationState`` the signal asserted.
    public var stateRaw: String = CommunicationState.unknown.rawValue

    /// ``ElephruitCore/CommunicationEvidence`` raw value.
    public var evidenceRaw: String = CommunicationEvidence.inference.rawValue

    /// When the reported thing happened, as the source described it.
    public var occurredAt: Date = Date()

    /// When Elephruit received it. Distinct from ``occurredAt`` because an imported sent-message
    /// record describes something that happened before the app heard about it.
    public var recordedAt: Date = Date()

    /// Whether the record moved as a result.
    public var didApply: Bool = false

    /// ``ElephruitCore/CommunicationTransitionResult`` in words, when it did not apply.
    public var outcomeNote: String?

    /// ``ElephruitCore/CommunicationMatchBasis`` raw value, when this signal had to be matched.
    public var matchBasisRaw: String?

    public var intent: CommunicationIntentRecord?

    public init(
        id: UUID = UUID(),
        state: CommunicationState = .unknown,
        evidence: CommunicationEvidence = .inference,
        occurredAt: Date = Date(),
        recordedAt: Date = Date(),
        didApply: Bool = false,
        outcomeNote: String? = nil,
        matchBasis: CommunicationMatchBasis? = nil,
        intent: CommunicationIntentRecord? = nil
    ) {
        self.id = id
        self.stateRaw = state.rawValue
        self.evidenceRaw = evidence.rawValue
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt
        self.didApply = didApply
        self.outcomeNote = outcomeNote
        self.matchBasisRaw = matchBasis?.rawValue
        self.intent = intent
    }
}

extension CommunicationEventRecord {
    public var state: CommunicationState {
        get { CommunicationState(rawValue: stateRaw) ?? .unknown }
        set { stateRaw = newValue.rawValue }
    }

    public var evidence: CommunicationEvidence {
        get { CommunicationEvidence(rawValue: evidenceRaw) ?? .inference }
        set { evidenceRaw = newValue.rawValue }
    }

    public var matchBasis: CommunicationMatchBasis? {
        get { matchBasisRaw.flatMap(CommunicationMatchBasis.init(rawValue:)) }
        set { matchBasisRaw = newValue?.rawValue }
    }
}

// MARK: - Encoding

/// JSON in a string column, for the two value arrays a communication carries.
///
/// Non-throwing in both directions on purpose. A column that will not decode is a column with
/// nothing usable in it, and the honest reading of that is "no recipients recorded" rather than a
/// failure thrown out of a property getter that a view is in the middle of rendering.
enum CommunicationJSON {
    static func encode<Value: Encodable>(_ value: Value) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else {
            Diagnostics.persistence.error("A communication value could not be encoded; storing nothing")
            return ""
        }
        return text
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from text: String) -> Value? {
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
