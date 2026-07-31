import CryptoKit
import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// The lifecycle of a communication, from before it is launched to whatever is finally known.
///
/// ### What this service is for
/// One message can be reported on by five different things — the intent itself, a share callback, a
/// user's answer, a provider record, an imported sent message — and the naive handling of that is
/// five timeline rows about one email. This is the single place all five arrive, and it maintains
/// exactly one ``ElephruitModel/CommunicationIntentRecord`` and at most one interaction `Item` per
/// message.
///
/// ### What it will not do
/// It will not write an interaction because a composer opened. An interaction is a claim that
/// something happened between two people, and until somebody or something says the message went, the
/// only true statement available is that the user set out to send one — which is what the intent
/// record holds. See ``promoteToInteractionIfEarned(_:)`` for the exact condition.
@MainActor
public final class CommunicationService {
    private let context: ModelContext
    private let items: any ItemRepository
    private let people: PeopleService
    private let dateProvider: any DateProvider

    /// Where the user's retention choice lives.
    ///
    /// In `UserDefaults` rather than the store, on the same terms as ``AppServices/shareProfiles``:
    /// it is a preference about *this machine's* behaviour, it carries no relationship data, and it
    /// must not travel inside an archive somebody might send to a colleague.
    private let defaults: UserDefaults

    static let privacyDefaultsKey = "communication.privacyPreference"

    public init(
        context: ModelContext,
        items: any ItemRepository,
        people: PeopleService,
        dateProvider: any DateProvider,
        defaults: UserDefaults = .standard
    ) {
        self.context = context
        self.items = items
        self.people = people
        self.dateProvider = dateProvider
        self.defaults = defaults
    }

    // MARK: - The privacy setting

    /// How much of a message this library keeps.
    ///
    /// Defaults to ``ElephruitCore/CommunicationPrivacyPreference/metadataOnly``, and an unreadable
    /// stored value reads as the same — an unknown setting is never permission to keep more.
    public var privacyPreference: CommunicationPrivacyPreference {
        get {
            guard let raw = defaults.string(forKey: Self.privacyDefaultsKey),
                  let stored = CommunicationPrivacyPreference(rawValue: raw)
            else { return .metadataOnly }
            return stored
        }
        set { defaults.set(newValue.rawValue, forKey: Self.privacyDefaultsKey) }
    }

    // MARK: - Preparing

    /// Records what the user means to send, before anything external is opened.
    ///
    /// Writes an intent and **no interaction**. The returned record is what the launcher is then
    /// asked to act on, and what every later signal is reconciled against.
    ///
    /// The body is passed in whether or not it will be kept: the composer needs it either way, and
    /// whether a copy stays behind is decided here, once, by ``privacyPreference``.
    @discardableResult
    public func prepare(
        channel: CommunicationChannel,
        people linkedPeople: [Item] = [],
        recipients: [CommunicationRecipient],
        subject: String? = nil,
        body: String? = nil,
        attachments: [CommunicationAttachmentReference] = [],
        source: CommunicationSourceContext = .none
    ) throws(AppError) -> CommunicationIntentRecord {
        let privacy = privacyPreference
        let now = dateProvider.now

        let record = CommunicationIntentRecord(
            channel: channel,
            state: .draftPrepared,
            evidence: .inference,
            mechanism: channel.hasSharingService ? .sharingService : .urlScheme,
            privacy: privacy,
            createdAt: now
        )

        record.personIDs = linkedPeople.map(\.id)
        record.intendedRecipients = recipients
        record.intendedSubject = subject?.isEmpty == true ? nil : subject
        record.attachments = attachments
        record.source = source

        // The two content decisions, made once and never revisited for this record.
        record.intendedBody = privacy.storesBody ? body : nil
        record.contentFingerprint = privacy.storesFingerprint
            ? CommunicationFingerprint.make(subject: subject, body: body)
            : nil

        context.insert(record)
        try save(because: "preparing a communication")

        Diagnostics.persistence.info(
            """
            Communication intent prepared: \(channel.rawValue, privacy: .public) \
            to \(recipients.count, privacy: .public) recipient(s)
            """
        )
        return record
    }

    // MARK: - Receiving signals

    /// Applies what a launcher reported.
    ///
    /// The report already carries the intent identifier, so this needs no matching at all — which is
    /// the reason ``ElephruitCore/CommunicationLaunchReport`` carries it.
    @discardableResult
    public func record(_ report: CommunicationLaunchReport) throws(AppError) -> CommunicationIntentRecord? {
        try record(signal: report.signal)
    }

    /// Applies one signal to whichever record it belongs to, and to no other.
    ///
    /// Returns the record it landed on, or `nil` when the signal matched nothing — which is a
    /// legitimate outcome and never a reason to invent a record to hang it on. An unmatched provider
    /// record means the user sent an email Elephruit had nothing to do with, and quietly adopting it
    /// would put messages in the timeline the user never connected to anybody.
    @discardableResult
    public func record(signal: CommunicationSignal) throws(AppError) -> CommunicationIntentRecord? {
        let candidates = try openRecords(for: signal)
        let outcome = CommunicationReconciler.match(signal: signal, against: candidates.map { $0.asValue() })

        guard let match = outcome.match else {
            if case .ambiguous(let ids) = outcome {
                // Two records fit equally well, so neither is updated. Logged by count rather than by
                // identity, because the interesting question afterwards is whether it recurs.
                Diagnostics.persistence.info(
                    "A communication signal matched \(ids.count, privacy: .public) records; none updated"
                )
            }
            return nil
        }

        guard let record = candidates.first(where: { $0.id == match.intentID }) else { return nil }
        try apply(signal, to: record, basis: match.basis)
        return record
    }

    /// Applies a signal to a record already in hand, keeping the event log either way.
    func apply(
        _ signal: CommunicationSignal,
        to record: CommunicationIntentRecord,
        basis: CommunicationMatchBasis
    ) throws(AppError) {
        let result = CommunicationTransitionPolicy.resolve(
            current: record.state,
            currentEvidence: record.evidence,
            incoming: signal.state,
            incomingEvidence: signal.evidence
        )

        let event = CommunicationEventRecord(
            state: signal.state,
            evidence: signal.evidence,
            occurredAt: signal.occurredAt,
            recordedAt: dateProvider.now,
            didApply: result.didApply,
            outcomeNote: Self.note(for: result),
            matchBasis: basis,
            intent: record
        )
        context.insert(event)

        if result.didApply {
            record.state = signal.state
            record.evidence = signal.evidence
            record.stateChangedAt = dateProvider.now

            if let failure = signal.failure { record.failure = failure }
            if let messageID = signal.providerMessageID { record.providerMessageID = messageID }
            if let threadID = signal.providerThreadID { record.providerThreadID = threadID }
            if let providerName = signal.providerName { record.providerName = providerName }
            if signal.state.claimsTheMessageLeft { record.submittedAt = signal.occurredAt }

            // What the provider says actually went out, kept beside — never over — what Elephruit
            // meant to send. A disagreement between the two is a fact worth being able to see.
            if !signal.recipients.isEmpty, signal.evidence.authority >= CommunicationEvidence.providerAPI.authority {
                record.finalRecipients = signal.recipients
            }

            try promoteToInteractionIfEarned(record)
        }

        try save(because: "recording a communication signal")
    }

    private static func note(for result: CommunicationTransitionResult) -> String? {
        switch result {
        case .applied: nil
        case .duplicate: "The same status from an equally authoritative source."
        case .weakerClaim: "A smaller claim than the record already holds."
        case .weakerEvidence: "Not authoritative enough to take back what was already recorded."
        case .notASignal: "An unknown status carries no information."
        }
    }

    // MARK: - The user answering

    /// What the user said when asked whether they sent it.
    public enum Confirmation: Sendable, Hashable {
        case sent
        case notSent
        case stillWorkingOnIt
        case dismissed
    }

    /// Records the user's answer, which is the strongest evidence this app usually has.
    ///
    /// `stillWorkingOnIt` and `dismissed` change no state at all: neither is a statement about
    /// whether the message went, and recording one as though it were would be the same mistake as
    /// recording a composer opening as a send. They only affect whether the question is asked again.
    @discardableResult
    public func confirm(
        _ answer: Confirmation,
        for record: CommunicationIntentRecord
    ) throws(AppError) -> CommunicationIntentRecord {
        let now = dateProvider.now

        switch answer {
        case .sent:
            try apply(
                CommunicationSignal(
                    channel: record.channel,
                    state: .userConfirmedSent,
                    evidence: .userConfirmation,
                    occurredAt: now,
                    intentID: record.id
                ),
                to: record,
                basis: .intentIdentifier
            )

        case .notSent:
            try apply(
                CommunicationSignal(
                    channel: record.channel,
                    state: .canceled,
                    evidence: .userConfirmation,
                    occurredAt: now,
                    intentID: record.id,
                    failure: CommunicationFailure(summary: "You said this was not sent.", wasCanceledByUser: true)
                ),
                to: record,
                basis: .intentIdentifier
            )

        case .stillWorkingOnIt:
            // Leaves the state where it is and permits exactly one more ask. The count was already
            // incremented when the question was put; nothing further is needed here.
            record.lastAskedAt = now
            try save(because: "deferring a communication confirmation")

        case .dismissed:
            record.dismissedAt = now
            try save(because: "dismissing a communication confirmation")
        }

        return record
    }

    /// Notes that the question has been put, so it is not put again immediately.
    public func markAsked(_ record: CommunicationIntentRecord) throws(AppError) {
        record.lastAskedAt = dateProvider.now
        record.askCount += 1
        try save(because: "asking for a communication confirmation")
    }

    /// The handoffs still worth asking about, oldest first.
    ///
    /// Oldest first because a question about something from twenty minutes ago is harder to answer
    /// than one about something from two, so the one at risk of becoming unanswerable is asked first.
    public func pendingConfirmations(limit: Int = 5) throws(AppError) -> [CommunicationIntentRecord] {
        let now = dateProvider.now
        return try allRecords()
            .filter { $0.asValue().shouldAskForConfirmation(now: now) }
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Calls

    /// Records how a call actually went, entirely on the user's word.
    ///
    /// Nothing about a call is observable to this app — not that it connected, not how long it
    /// lasted — so every value here arrives by being told, and the timeline says "confirmed
    /// manually" because that is the only thing it could honestly say.
    ///
    /// A call that did not connect still updates the record and still refuses to become contact:
    /// ``ElephruitCore/CallOutcome/countsAsContact`` is the same rule the People module already
    /// applies to a call that reached voicemail.
    @discardableResult
    public func logCall(
        _ outcome: CallOutcome,
        for record: CommunicationIntentRecord,
        duration: TimeInterval? = nil,
        notes: String = ""
    ) throws(AppError) -> Item? {
        let now = dateProvider.now

        try apply(
            CommunicationSignal(
                channel: record.channel,
                state: outcome == .canceled ? .canceled : .userConfirmedSent,
                evidence: .userConfirmation,
                occurredAt: now,
                intentID: record.id,
                failure: outcome == .canceled
                    ? CommunicationFailure(summary: "You canceled this call.", wasCanceledByUser: true)
                    : nil
            ),
            to: record,
            basis: .intentIdentifier
        )

        guard outcome != .canceled else { return nil }

        let interaction = try promoteToInteraction(record, provenance: .logged)

        try items.update(interaction) { subject in
            subject.title = Self.callTitle(outcome: outcome, channel: record.channel, duration: duration)
            if !notes.isEmpty { subject.body = notes }
        }
        try save(because: "logging a call outcome")
        return interaction
    }

    static func callTitle(outcome: CallOutcome, channel: CommunicationChannel, duration: TimeInterval?) -> String {
        var title = "\(channel.noun) — \(outcome.displayName.lowercased())"
        if let duration, duration > 0 {
            let minutes = max(1, Int((duration / 60).rounded()))
            title += " (\(minutes) min)"
        }
        return title
    }

    // MARK: - Interactions

    /// Writes the one interaction this communication earns, if it has earned one.
    ///
    /// ### The condition
    /// ``ElephruitCore/CommunicationState/countsAsReachingOut`` — the user said they sent it, or a
    /// provider verified it, or a provider reported delivery. A composer that opened has not earned
    /// one, a share that completed has not earned one, and a message that failed or was canceled
    /// never will.
    ///
    /// ### Why this cannot produce a second row
    /// The record holds ``ElephruitModel/CommunicationIntentRecord/interactionID``, and this returns
    /// the existing interaction whenever one is set. Five signals about one message therefore update
    /// one interaction rather than creating five — acceptance scenario 9, enforced here rather than
    /// hoped for at the call sites.
    @discardableResult
    func promoteToInteractionIfEarned(_ record: CommunicationIntentRecord) throws(AppError) -> Item? {
        guard record.state.countsAsReachingOut else {
            // A record that already has an interaction and has since been taken back keeps it, with
            // the interaction's own title rewritten to say what happened. Deleting somebody's
            // timeline row underneath them is not this module's decision to make — standing rule R4.
            if let interaction = try existingInteraction(for: record), record.state == .failed {
                try items.update(interaction) { $0.title = Self.interactionTitle(for: record) }
                try save(because: "correcting a failed communication")
            }
            return nil
        }

        return try promoteToInteraction(record, provenance: .logged)
    }

    /// The interaction for this record, creating it once if it does not exist.
    @discardableResult
    func promoteToInteraction(
        _ record: CommunicationIntentRecord,
        provenance: InteractionProvenance
    ) throws(AppError) -> Item {
        if let existing = try existingInteraction(for: record) {
            try items.update(existing) { subject in
                subject.title = Self.interactionTitle(for: record)
                subject.sourceIdentifier = provenance.rawValue
            }
            try save(because: "updating a communication's interaction")
            return existing
        }

        var linked: [Item] = []
        for personID in record.personIDs {
            if let person = try items.item(id: personID), person.deletedAt == nil { linked.append(person) }
        }
        let anchor = linked.first

        let interaction: Item
        if let anchor {
            interaction = try people.recordInteraction(
                with: anchor,
                summary: Self.interactionTitle(for: record),
                at: record.submittedAt ?? record.stateChangedAt
            )
            // Everybody else on the message, so a group email appears on each of their pages.
            for other in linked.dropFirst() {
                try items.link(interaction, to: other, kind: .mentions)
            }
        } else {
            // A communication to a handle that belongs to nobody in the library is still a
            // communication. It gets an interaction with no person attached rather than being
            // dropped, and rather than a person being invented to hold it.
            var draft = ItemDraft(kind: .interaction, title: Self.interactionTitle(for: record))
            draft.startAt = record.submittedAt ?? record.stateChangedAt
            interaction = try items.create(draft)
        }

        try items.update(interaction) { subject in
            subject.sourceIdentifier = provenance.rawValue
            subject.sourceURLString = Self.sourceURL(for: record)?.absoluteString
        }

        // Link it back to whatever the user was looking at when they started.
        if let sourceID = record.source.itemID, let origin = try items.item(id: sourceID) {
            try items.link(interaction, to: origin, kind: .related)
        }

        record.interactionID = interaction.id
        try save(because: "creating a communication's interaction")
        return interaction
    }

    private func existingInteraction(for record: CommunicationIntentRecord) throws(AppError) -> Item? {
        guard let id = record.interactionID else { return nil }
        guard let item = try items.item(id: id), item.deletedAt == nil else { return nil }
        return item
    }

    /// The interaction's title — the status label's headline, which is already the honest sentence.
    static func interactionTitle(for record: CommunicationIntentRecord) -> String {
        CommunicationStatusLabel.make(for: record.asValue()).headline
    }

    /// The scheme URL an interaction carries, so ``PersonWorkspaceService/channel(of:)`` keeps
    /// working for rows written by this module.
    static func sourceURL(for record: CommunicationIntentRecord) -> URL? {
        guard let first = record.intendedRecipients.first?.handle else { return nil }
        return ContactActionURL.url(for: record.channel.contactChannel, destination: first)
    }

    // MARK: - Reading

    /// The record for an interaction, when the interaction came from one.
    public func record(forInteractionID id: UUID) throws(AppError) -> CommunicationIntentRecord? {
        var descriptor = FetchDescriptor<CommunicationIntentRecord>(
            predicate: #Predicate { $0.interactionID == id }
        )
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    /// The status of every interaction in a set, in one fetch.
    ///
    /// One query for a whole timeline rather than one per row — the shape ``PersonWorkspaceService``
    /// needs so that showing evidence on a person's page does not turn a page load into five hundred
    /// fetches.
    public func statuses(forInteractionIDs ids: [UUID]) throws(AppError) -> [UUID: CommunicationIntent] {
        guard !ids.isEmpty else { return [:] }
        let wanted = Set(ids)

        let descriptor = FetchDescriptor<CommunicationIntentRecord>(
            predicate: #Predicate { $0.interactionID != nil }
        )

        var result: [UUID: CommunicationIntent] = [:]
        for record in try fetch(descriptor) {
            guard let interactionID = record.interactionID, wanted.contains(interactionID) else { continue }
            result[interactionID] = record.asValue()
        }
        return result
    }

    public func record(id: UUID) throws(AppError) -> CommunicationIntentRecord? {
        var descriptor = FetchDescriptor<CommunicationIntentRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    /// Every record, newest first.
    public func allRecords() throws(AppError) -> [CommunicationIntentRecord] {
        try fetch(
            FetchDescriptor<CommunicationIntentRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )
    }

    /// The records a signal could plausibly belong to.
    ///
    /// Narrowed by channel and by time before the reconciler sees them, so that a sent-mail import
    /// covering a week does not compare every message against every intent the library has ever held.
    private func openRecords(for signal: CommunicationSignal) throws(AppError) -> [CommunicationIntentRecord] {
        // An identified signal needs no window at all: the caller knows which record it belongs to,
        // and a confirmation answered an hour later is still about that message.
        if let intentID = signal.intentID {
            return try record(id: intentID).map { [$0] } ?? []
        }

        let channelRaw = signal.channel.rawValue
        let lower = signal.occurredAt.addingTimeInterval(-CommunicationReconciler.defaultWindow)
        let upper = signal.occurredAt.addingTimeInterval(CommunicationReconciler.defaultWindow)

        let descriptor = FetchDescriptor<CommunicationIntentRecord>(
            predicate: #Predicate {
                $0.channelRaw == channelRaw && $0.createdAt >= lower && $0.createdAt <= upper
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try fetch(descriptor)
    }

    // MARK: - Store plumbing

    private func fetch<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>
    ) throws(AppError) -> [Model] {
        do {
            return try context.fetch(descriptor)
        } catch {
            throw AppError.storeUnavailable(underlying: error.localizedDescription)
        }
    }

    private func save(because reason: String) throws(AppError) {
        do {
            try context.save()
        } catch {
            throw AppError.writeFailed(path: reason, reason: error.localizedDescription)
        }
    }
}

// MARK: - Fingerprints

/// A one-way digest of what a message said, for telling two similar messages apart.
///
/// ### Why this is opt-in and why it is not a substitute for content
/// Reconciliation needs to know whether the provider's record of *an* email to Maya is the record of
/// *this* email to Maya. Recipient, subject, and time usually settle it; two messages sent minutes
/// apart with the same subject do not, and a digest does.
///
/// A digest is not the message, but it is not nothing either: a short body can be checked against a
/// guess, because anybody holding the digest can hash a candidate and compare. That is why this runs
/// only under ``ElephruitCore/CommunicationPrivacyPreference/fingerprintForMatching`` or stronger,
/// and why the setting says so in the interface before it is turned on.
///
/// SHA-256 over normalised text. CryptoKit rather than a hand-rolled hash because a weak digest
/// collides, and a collision here means two different messages being treated as one — the exact
/// failure ``ElephruitCore/CommunicationReconciler`` is built to avoid.
public enum CommunicationFingerprint {
    public static func make(subject: String?, body: String?) -> String? {
        let parts = [subject, body]
            .compactMap { $0 }
            .map { TextNormalizer.foldedForMatching($0) }
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else { return nil }

        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
