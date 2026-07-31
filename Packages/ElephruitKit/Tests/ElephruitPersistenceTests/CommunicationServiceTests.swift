import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// The acceptance scenarios, end to end against a real store.
///
/// The claim this suite has to establish is a negative one: that no sequence of signals produces a
/// timeline entry saying something happened that did not. So most of these tests assert on what is
/// *absent* — no interaction, no second row, no "sent", no stored body — which is the half that a
/// feature demo would never show.
@MainActor
struct CommunicationFixture {
    let store: StoreFixture
    let people: PeopleService
    let communications: CommunicationService
    let defaults: UserDefaults

    /// A scratch defaults suite per fixture, so a test that opts into content retention does not
    /// leave the setting on for the user or for the next test.
    init(dateProvider: FixedDateProvider = .reference) throws {
        self.store = try StoreFixture(dateProvider: dateProvider)
        self.people = PeopleService(items: store.items, dateProvider: dateProvider)

        let suiteName = "communication-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw AppError.storeUnavailable(underlying: "could not open a scratch defaults suite")
        }
        self.defaults = defaults

        self.communications = CommunicationService(
            context: store.context,
            items: store.items,
            people: people,
            dateProvider: dateProvider,
            defaults: defaults
        )
    }

    /// The same store and preferences, seen from a later instant.
    ///
    /// `FixedDateProvider` is frozen by design, so advancing the clock means a second service over
    /// the same context rather than a mutable provider that every other suite would then have to
    /// reason about.
    func advanced(by interval: TimeInterval) -> CommunicationService {
        CommunicationService(
            context: store.context,
            items: store.items,
            people: PeopleService(
                items: store.items,
                dateProvider: FixedDateProvider(now: store.dateProvider.now.addingTimeInterval(interval))
            ),
            dateProvider: FixedDateProvider(now: store.dateProvider.now.addingTimeInterval(interval)),
            defaults: defaults
        )
    }

    @discardableResult
    func makePerson(_ name: String) throws -> Item {
        try store.items.create(ItemDraft(kind: .person, title: name))
    }

    func interactions() throws -> [Item] {
        var query = ItemQuery()
        query.kinds = [.interaction]
        query.scope = .active
        return try store.items.items(matching: query)
    }
}

// MARK: - Launching

@Suite("Communications: launching and handing off")
@MainActor
struct CommunicationLaunchTests {
    @Test("Launching an email records the intended recipient and no interaction")
    func preparingWritesAnIntentAndNothingElse() throws {
        // Acceptance 1 and 2: an intent exists, it knows who it was for, and the timeline is empty.
        let fixture = try CommunicationFixture()
        let maya = try fixture.makePerson("Maya Chen")

        let record = try fixture.communications.prepare(
            channel: .email,
            people: [maya],
            recipients: [CommunicationRecipient(handle: "maya@example.com", personID: maya.id, displayName: "Maya Chen")],
            subject: "Lunch",
            body: "Are you free Thursday?"
        )

        #expect(record.state == .draftPrepared)
        #expect(record.intendedRecipients.first?.handle == "maya@example.com")
        #expect(record.personIDs == [maya.id])
        #expect(record.interactionID == nil)
        #expect(try fixture.interactions().isEmpty, "preparing a message is not having sent one")
    }

    @Test("A composer that opened says so and earns no interaction")
    func composerOpenedIsNotAnInteraction() throws {
        let fixture = try CommunicationFixture()
        let maya = try fixture.makePerson("Maya Chen")
        let record = try fixture.communications.prepare(
            channel: .email,
            people: [maya],
            recipients: [CommunicationRecipient(handle: "maya@example.com")]
        )

        try fixture.communications.record(
            CommunicationLaunchReport(
                intentID: record.id,
                channel: .email,
                mechanism: .sharingService,
                outcome: .composerOpened,
                occurredAt: fixture.store.dateProvider.now
            )
        )

        #expect(record.state == .composerOpened)
        #expect(record.evidence == .systemCallback)
        #expect(try fixture.interactions().isEmpty)
    }

    @Test("A completed share is handed off, not delivered")
    func shareCompletionIsHandedOff() throws {
        // Acceptance 3 and 4.
        let fixture = try CommunicationFixture()
        let maya = try fixture.makePerson("Maya Chen")
        let record = try fixture.communications.prepare(
            channel: .email,
            people: [maya],
            recipients: [CommunicationRecipient(handle: "maya@example.com")]
        )

        try fixture.communications.record(
            CommunicationLaunchReport(
                intentID: record.id, channel: .email, mechanism: .sharingService,
                outcome: .shareCompleted, occurredAt: fixture.store.dateProvider.now
            )
        )

        #expect(record.state == .shareCompleted)

        let label = CommunicationStatusLabel.make(for: record.asValue())
        #expect(label.headline == "Email handed off to your mail app")
        #expect(!label.sentence.lowercased().contains("deliver"))
        #expect(try fixture.interactions().isEmpty, "a share callback is not evidence that anything was sent")
    }

    @Test("Cancelling and failing are recorded, and are told apart")
    func cancellationAndFailureAreDistinct() throws {
        // Acceptance 5.
        let fixture = try CommunicationFixture()
        let maya = try fixture.makePerson("Maya Chen")

        let cancelled = try fixture.communications.prepare(
            channel: .email, people: [maya],
            recipients: [CommunicationRecipient(handle: "maya@example.com")]
        )
        try fixture.communications.record(
            CommunicationLaunchReport(
                intentID: cancelled.id, channel: .email, mechanism: .sharingService,
                outcome: .canceled(.userCanceled), occurredAt: fixture.store.dateProvider.now
            )
        )
        #expect(cancelled.state == .canceled)
        #expect(cancelled.failure?.wasCanceledByUser == true)

        let failed = try fixture.communications.prepare(
            channel: .email, people: [maya],
            recipients: [CommunicationRecipient(handle: "maya@example.com")]
        )
        try fixture.communications.record(
            CommunicationLaunchReport(
                intentID: failed.id, channel: .email, mechanism: .sharingService,
                outcome: .failed(.noHandler), occurredAt: fixture.store.dateProvider.now
            )
        )
        #expect(failed.state == .failed)
        #expect(failed.failure?.wasCanceledByUser == false)

        #expect(try fixture.interactions().isEmpty, "neither outcome is a conversation")
    }

    @Test("A message composer is opened without anything reading message history")
    func messagesNeedsNoHistory() throws {
        // Acceptance 10 and 11. The store gains exactly one row and the app reads nothing of the
        // user's conversations to produce it — there is no code path here that could.
        let fixture = try CommunicationFixture()
        let maya = try fixture.makePerson("Maya Chen")

        let record = try fixture.communications.prepare(
            channel: .message, people: [maya],
            recipients: [CommunicationRecipient(handle: "5125550192", displayName: "Maya")]
        )
        try fixture.communications.record(
            CommunicationLaunchReport(
                intentID: record.id, channel: .message, mechanism: .urlScheme,
                outcome: .composerOpened, occurredAt: fixture.store.dateProvider.now
            )
        )

        let label = CommunicationStatusLabel.make(for: record.asValue())
        #expect(label.headline == "Message initiated")
        #expect(label.detail == "final sending status unknown")
        #expect(!record.state.claimsTheMessageLeft)
    }
}

// MARK: - Confirming

@Suite("Communications: what the user says")
@MainActor
struct CommunicationConfirmationTests {
    @Test("A confirmed send creates exactly one interaction")
    func confirmationEarnsAnInteraction() throws {
        // Acceptance 6 and 7.
        let fixture = try CommunicationFixture()
        let maya = try fixture.makePerson("Maya Chen")

        let record = try fixture.communications.prepare(
            channel: .email, people: [maya],
            recipients: [CommunicationRecipient(handle: "maya@example.com", personID: maya.id)],
            subject: "Lunch"
        )
        try fixture.communications.record(
            CommunicationLaunchReport(
                intentID: record.id, channel: .email, mechanism: .urlScheme,
                outcome: .composerOpened, occurredAt: fixture.store.dateProvider.now
            )
        )
        #expect(try fixture.interactions().isEmpty)

        try fixture.communications.confirm(.sent, for: record)

        #expect(record.state == .userConfirmedSent)
        #expect(record.evidence == .userConfirmation)

        let interactions = try fixture.interactions()
        #expect(interactions.count == 1)
        #expect(interactions.first?.title == "Email sent")
        #expect(record.interactionID == interactions.first?.id)

        // And it is on Maya's page rather than floating unattached.
        let refetched = try fixture.store.sameContextItem(id: maya.id)
        #expect(refetched.incomingLinks.contains { $0.source?.kind == .interaction })
    }

    @Test("Saying it was not sent records that, and writes no interaction")
    func notSentIsAlsoAnAnswer() throws {
        let fixture = try CommunicationFixture()
        let maya = try fixture.makePerson("Maya Chen")
        let record = try fixture.communications.prepare(
            channel: .email, people: [maya],
            recipients: [CommunicationRecipient(handle: "maya@example.com")]
        )

        try fixture.communications.confirm(.notSent, for: record)

        #expect(record.state == .canceled)
        #expect(try fixture.interactions().isEmpty)
    }

    @Test("Deferring and dismissing state nothing about whether it was sent")
    func neitherDeferralNorDismissalIsAClaim() throws {
        let fixture = try CommunicationFixture()
        let record = try fixture.communications.prepare(
            channel: .message, recipients: [CommunicationRecipient(handle: "5125550192")]
        )
        try fixture.communications.record(
            CommunicationLaunchReport(
                intentID: record.id, channel: .message, mechanism: .urlScheme,
                outcome: .composerOpened, occurredAt: fixture.store.dateProvider.now
            )
        )

        try fixture.communications.confirm(.stillWorkingOnIt, for: record)
        #expect(record.state == .composerOpened, "a deferral is not a status")

        try fixture.communications.confirm(.dismissed, for: record)
        #expect(record.state == .composerOpened, "a dismissal is not a status either")
        #expect(record.dismissedAt != nil)
        #expect(try fixture.interactions().isEmpty)
    }

    @Test("A dismissal stops the question for good")
    func dismissalIsPermanent() throws {
        // Acceptance 6's other half: the prompt must not become a nuisance.
        let fixture = try CommunicationFixture()
        let record = try fixture.communications.prepare(
            channel: .message, recipients: [CommunicationRecipient(handle: "5125550192")]
        )
        try fixture.communications.record(
            CommunicationLaunchReport(
                intentID: record.id, channel: .message, mechanism: .urlScheme,
                outcome: .composerOpened, occurredAt: fixture.store.dateProvider.now
            )
        )

        #expect(try fixture.communications.pendingConfirmations().count == 1)

        try fixture.communications.confirm(.dismissed, for: record)

        let muchLater = fixture.advanced(by: 86_400 * 365)
        #expect(try muchLater.pendingConfirmations().isEmpty)
    }

    @Test("A handoff is asked about at most twice")
    func askingIsBounded() throws {
        let fixture = try CommunicationFixture()
        let record = try fixture.communications.prepare(
            channel: .message, recipients: [CommunicationRecipient(handle: "5125550192")]
        )
        try fixture.communications.record(
            CommunicationLaunchReport(
                intentID: record.id, channel: .message, mechanism: .urlScheme,
                outcome: .composerOpened, occurredAt: fixture.store.dateProvider.now
            )
        )

        try fixture.communications.markAsked(record)
        try fixture.communications.markAsked(record)

        let later = fixture.advanced(by: 86_400)
        #expect(try later.pendingConfirmations().isEmpty, "two asks is the whole budget")
    }

    @Test("A share callback is never asked about — the framework already answered")
    func sharingServiceLaunchesAreNotQuestioned() throws {
        let fixture = try CommunicationFixture()
        let record = try fixture.communications.prepare(
            channel: .email, recipients: [CommunicationRecipient(handle: "maya@example.com")]
        )
        #expect(record.mechanism == .sharingService)

        try fixture.communications.record(
            CommunicationLaunchReport(
                intentID: record.id, channel: .email, mechanism: .sharingService,
                outcome: .shareCompleted, occurredAt: fixture.store.dateProvider.now
            )
        )

        #expect(try fixture.communications.pendingConfirmations().isEmpty)
    }
}

// MARK: - Providers and duplicates

@Suite("Communications: reconciliation and duplicates")
@MainActor
struct CommunicationReconciliationServiceTests {
    @Test("A provider verifying a message upgrades the interaction it already has")
    func providerUpgradesTheSameInteraction() throws {
        // Acceptance 8 and 9, which are the same test: five signals, one row.
        let fixture = try CommunicationFixture()
        let maya = try fixture.makePerson("Maya Chen")

        let record = try fixture.communications.prepare(
            channel: .email, people: [maya],
            recipients: [CommunicationRecipient(handle: "maya@example.com", personID: maya.id)],
            subject: "Lunch"
        )

        // 1 — intent. 2 — the share callback.
        try fixture.communications.record(
            CommunicationLaunchReport(
                intentID: record.id, channel: .email, mechanism: .sharingService,
                outcome: .shareCompleted, occurredAt: fixture.store.dateProvider.now
            )
        )
        // 3 — the user confirms.
        try fixture.communications.confirm(.sent, for: record)
        let interactionID = record.interactionID
        #expect(interactionID != nil)

        // 4 — the provider verifies, matched by recipient, subject, and time.
        let later = fixture.advanced(by: 120)
        let matched = try later.record(
            signal: CommunicationSignal(
                channel: .email,
                state: .providerVerifiedSent,
                evidence: .providerAPI,
                occurredAt: fixture.store.dateProvider.now.addingTimeInterval(90),
                providerMessageID: "gmail-1",
                providerName: "Gmail",
                recipients: [CommunicationRecipient(handle: "maya@example.com")],
                subject: "Lunch"
            )
        )
        #expect(matched?.id == record.id)

        // 5 — the same message again, from a sent-mail import.
        try later.record(
            signal: CommunicationSignal(
                channel: .email,
                state: .providerVerifiedSent,
                evidence: .importedRecord,
                occurredAt: fixture.store.dateProvider.now.addingTimeInterval(95),
                providerMessageID: "gmail-1",
                providerName: "Gmail",
                recipients: [CommunicationRecipient(handle: "maya@example.com")],
                subject: "Lunch"
            )
        )

        #expect(record.state == .providerVerifiedSent)
        #expect(record.providerMessageID == "gmail-1")
        #expect(record.providerName == "Gmail")

        let interactions = try fixture.interactions()
        #expect(interactions.count == 1, "five signals about one message produced \(interactions.count) rows")
        #expect(record.interactionID == interactionID, "the interaction was upgraded, not replaced")
        #expect(interactions.first?.title == "Email submitted")

        // Every signal is kept, including the one that changed nothing.
        #expect(record.events.count == 5)
        #expect(record.events.count(where: \.didApply) == 4)
    }

    @Test("A provider record matching nothing adopts nothing")
    func unmatchedProviderRecordsAreLeftAlone() throws {
        // An email the user sent from Mail without Elephruit's involvement. Quietly adopting it
        // would put messages in the timeline the user never connected to anybody.
        let fixture = try CommunicationFixture()
        _ = try fixture.makePerson("Maya Chen")

        let matched = try fixture.communications.record(
            signal: CommunicationSignal(
                channel: .email,
                state: .providerVerifiedSent,
                evidence: .providerAPI,
                occurredAt: fixture.store.dateProvider.now,
                providerMessageID: "gmail-99",
                recipients: [CommunicationRecipient(handle: "stranger@example.com")],
                subject: "Unrelated"
            )
        )

        #expect(matched == nil)
        #expect(try fixture.interactions().isEmpty)
        #expect(try fixture.communications.allRecords().isEmpty)
    }

    @Test("Two candidate messages means neither is updated")
    func ambiguityUpdatesNothing() throws {
        let fixture = try CommunicationFixture()
        let maya = try fixture.makePerson("Maya Chen")

        let first = try fixture.communications.prepare(
            channel: .email, people: [maya],
            recipients: [CommunicationRecipient(handle: "maya@example.com")], subject: "Lunch"
        )
        let second = try fixture.communications.prepare(
            channel: .email, people: [maya],
            recipients: [CommunicationRecipient(handle: "maya@example.com")], subject: "Lunch"
        )

        let matched = try fixture.communications.record(
            signal: CommunicationSignal(
                channel: .email, state: .providerVerifiedSent, evidence: .providerAPI,
                occurredAt: fixture.store.dateProvider.now.addingTimeInterval(60),
                providerMessageID: "gmail-1",
                recipients: [CommunicationRecipient(handle: "maya@example.com")],
                subject: "Lunch"
            )
        )

        #expect(matched == nil)
        #expect(first.state == .draftPrepared)
        #expect(second.state == .draftPrepared)
        #expect(try fixture.interactions().isEmpty)
    }

    @Test("A late share callback cannot demote a confirmed send")
    func lateWeakSignalsAreRecordedAndIgnored() throws {
        let fixture = try CommunicationFixture()
        let maya = try fixture.makePerson("Maya Chen")
        let record = try fixture.communications.prepare(
            channel: .email, people: [maya],
            recipients: [CommunicationRecipient(handle: "maya@example.com")]
        )

        try fixture.communications.confirm(.sent, for: record)
        #expect(record.state == .userConfirmedSent)

        try fixture.communications.record(
            CommunicationLaunchReport(
                intentID: record.id, channel: .email, mechanism: .sharingService,
                outcome: .shareCompleted, occurredAt: fixture.store.dateProvider.now
            )
        )

        #expect(record.state == .userConfirmedSent, "the row must not fall back to “handed off”")

        // The ignored signal is still on the record, with a reason attached — which is how the
        // sequence is explained afterwards rather than silently discarded.
        let ignored = record.events.filter { !$0.didApply }
        #expect(ignored.count == 1)
        #expect(ignored.first?.outcomeNote != nil)
        #expect(ignored.first?.state == .shareCompleted)
    }
}

// MARK: - Calls

@Suite("Communications: calls")
@MainActor
struct CommunicationCallTests {
    @Test("A call outcome is logged by hand, and voicemail is not contact")
    func callOutcomesAreManual() throws {
        // Acceptance 12.
        let fixture = try CommunicationFixture()
        let maya = try fixture.makePerson("Maya Chen")

        let record = try fixture.communications.prepare(
            channel: .phoneCall, people: [maya],
            recipients: [CommunicationRecipient(handle: "5125550192", personID: maya.id)]
        )
        #expect(record.mechanism == .urlScheme, "no sharing service places a call")

        let interaction = try fixture.communications.logCall(.connected, for: record, duration: 25 * 60, notes: "Austin move")

        #expect(interaction?.title == "Call — connected (25 min)")
        #expect(interaction?.body == "Austin move")
        #expect(try fixture.interactions().count == 1)

        // And the voicemail case, on a second call.
        let second = try fixture.communications.prepare(
            channel: .phoneCall, people: [maya],
            recipients: [CommunicationRecipient(handle: "5125550192", personID: maya.id)]
        )
        try fixture.communications.logCall(.leftVoicemail, for: second)

        #expect(!CallOutcome.leftVoicemail.countsAsContact)
        #expect(try fixture.interactions().count == 2)
    }

    @Test("A canceled call writes no interaction")
    func canceledCallsAreNotConversations() throws {
        let fixture = try CommunicationFixture()
        let maya = try fixture.makePerson("Maya Chen")
        let record = try fixture.communications.prepare(
            channel: .phoneCall, people: [maya],
            recipients: [CommunicationRecipient(handle: "5125550192")]
        )

        let interaction = try fixture.communications.logCall(.canceled, for: record)

        #expect(interaction == nil)
        #expect(record.state == .canceled)
        #expect(try fixture.interactions().isEmpty)
    }
}

// MARK: - Privacy

@Suite("Communications: what is kept")
@MainActor
struct CommunicationPrivacyTests {
    @Test("The default keeps metadata and no message body")
    func metadataOnlyIsTheDefault() throws {
        // Acceptance 13.
        let fixture = try CommunicationFixture()
        #expect(fixture.communications.privacyPreference == .metadataOnly)

        let record = try fixture.communications.prepare(
            channel: .email,
            recipients: [CommunicationRecipient(handle: "maya@example.com")],
            subject: "Lunch",
            body: "The oncologist called back and the news is good."
        )

        #expect(record.intendedBody == nil)
        #expect(record.contentFingerprint == nil)

        // And it is genuinely not on disk, rather than merely not returned by an accessor.
        let stored = try fixture.store.freshContext().fetch(FetchDescriptor<CommunicationIntentRecord>())
        #expect(stored.count == 1)
        #expect(stored.first?.intendedBody == nil)

        // The metadata that answers the question the module exists for is all there.
        #expect(record.intendedSubject == "Lunch")
        #expect(record.intendedRecipients.first?.handle == "maya@example.com")
        #expect(record.channel == .email)
    }

    @Test("A digest without the text is its own setting")
    func fingerprintsCanBeKeptWithoutContent() throws {
        let fixture = try CommunicationFixture()
        fixture.communications.privacyPreference = .fingerprintForMatching

        let record = try fixture.communications.prepare(
            channel: .email,
            recipients: [CommunicationRecipient(handle: "maya@example.com")],
            subject: "Lunch",
            body: "Are you free Thursday?"
        )

        #expect(record.intendedBody == nil)
        #expect(record.contentFingerprint != nil)
        #expect(record.contentFingerprint?.count == 64, "SHA-256, hex")
    }

    @Test("Retaining content is opt-in and applies from then on")
    func retainedContentIsHonoured() throws {
        let fixture = try CommunicationFixture()
        fixture.communications.privacyPreference = .retainContent

        let kept = try fixture.communications.prepare(
            channel: .email,
            recipients: [CommunicationRecipient(handle: "maya@example.com")],
            subject: "Lunch", body: "Are you free Thursday?"
        )
        #expect(kept.intendedBody == "Are you free Thursday?")
        #expect(kept.privacy == .retainContent)

        // Turning it off again does not reach back, and does not pretend the old record was written
        // under the new setting either — the record carries the one it was written under.
        fixture.communications.privacyPreference = .metadataOnly
        let later = try fixture.communications.prepare(
            channel: .email,
            recipients: [CommunicationRecipient(handle: "maya@example.com")],
            subject: "Dinner", body: "Or Friday?"
        )
        #expect(later.intendedBody == nil)
        #expect(later.privacy == .metadataOnly)
        #expect(kept.intendedBody == "Are you free Thursday?")
    }

    @Test("An unreadable privacy value reads as the strictest setting")
    func unknownSettingsNeverGrantMore() throws {
        let fixture = try CommunicationFixture()
        fixture.defaults.set("something-a-newer-build-wrote", forKey: "communication.privacyPreference")
        #expect(fixture.communications.privacyPreference == .metadataOnly)

        let record = try fixture.communications.prepare(
            channel: .email, recipients: [CommunicationRecipient(handle: "maya@example.com")], body: "Private"
        )
        record.privacyRaw = "something-a-newer-build-wrote"
        #expect(record.privacy == .metadataOnly)
    }

    @Test("Every status keeps the evidence behind it")
    func provenanceSurvivesForEveryStatus() throws {
        // Acceptance 14. The record's current state has an evidence kind, and the whole sequence of
        // reports that produced it is still there to be read.
        let fixture = try CommunicationFixture()
        let maya = try fixture.makePerson("Maya Chen")
        let record = try fixture.communications.prepare(
            channel: .email, people: [maya],
            recipients: [CommunicationRecipient(handle: "maya@example.com")]
        )

        try fixture.communications.record(
            CommunicationLaunchReport(
                intentID: record.id, channel: .email, mechanism: .sharingService,
                outcome: .composerOpened, occurredAt: fixture.store.dateProvider.now
            )
        )
        try fixture.communications.confirm(.sent, for: record)

        let events = record.orderedEvents
        #expect(events.count == 3, "the intent, the callback, and the answer")
        #expect(events.map(\.state) == [.draftPrepared, .composerOpened, .userConfirmedSent])
        #expect(events.map(\.evidence) == [.inference, .systemCallback, .userConfirmation])
        #expect(events.allSatisfy { $0.matchBasis == .intentIdentifier })
        #expect(record.evidence == .userConfirmation)

        for event in events {
            #expect(event.occurredAt <= event.recordedAt || event.didApply)
        }
    }

    @Test("An unreadable state reads as unknown rather than as sent")
    func unknownStatesNeverReadUpward() throws {
        let fixture = try CommunicationFixture()
        let record = try fixture.communications.prepare(
            channel: .email, recipients: [CommunicationRecipient(handle: "maya@example.com")]
        )

        record.stateRaw = "somethingANewerBuildInvented"
        #expect(record.state == .unknown)
        #expect(!record.state.countsAsReachingOut)
    }
}
