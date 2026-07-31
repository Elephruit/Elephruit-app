import ElephruitCore
// `@testable` for the two seams a view uses and nothing else does: the contact-action bridge, and
// `receive`, which is fed synchronously here so the assertions do not depend on task scheduling.
@testable import ElephruitFeatures
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

/// The whole layer wired together, with a launcher that opens nothing.
///
/// The fixture passes an ``ElephruitIntegrations/InertCommunicationLauncher``, which records what it
/// *would* have opened and opens nothing — so every path from a button press to a timeline row is
/// exercised without a compose window appearing on the machine running the tests. That is not a
/// convenience: an untestable launch path is one that only ever gets tried by hand, on a good day,
/// with the happy case.
@Suite("Communication coordinator")
@MainActor
struct CommunicationCoordinatorTests {
    func makeServices() -> (AppServices, InertCommunicationLauncher, UserDefaults) {
        let launcher = InertCommunicationLauncher()
        // A scratch defaults suite, so a test that changes the retention setting does not leave it
        // changed for the user or for the next test.
        let defaults = UserDefaults(suiteName: "communication-coordinator-\(UUID().uuidString)") ?? .standard

        let services = AppServices.inMemory(
            dateProvider: FixedDateProvider.reference,
            populated: false,
            defaults: defaults,
            communicationLauncher: launcher
        )
        return (services, launcher, defaults)
    }

    func makePerson(_ name: String, in services: AppServices) throws -> Item {
        try services.items.create(ItemDraft(kind: .person, title: name))
    }

    func interactions(in services: AppServices) throws -> [Item] {
        var query = ItemQuery()
        query.kinds = [.interaction]
        query.scope = .active
        return try services.items.items(matching: query)
    }

    // MARK: - Launching

    @Test("Starting a communication writes an intent and launches once")
    func startingWritesAnIntent() throws {
        let (services, launcher, _) = makeServices()
        let maya = try makePerson("Maya Chen", in: services)

        let intent = services.communicationConfirmations.start(
            channel: .email,
            people: [maya],
            recipients: [CommunicationRecipient(handle: "maya@example.com", personID: maya.id, displayName: "Maya Chen")],
            subject: "Lunch"
        )

        #expect(intent != nil)
        #expect(launcher.launched.count == 1)
        #expect(launcher.launched.first?.id == intent?.id, "the launcher is told which intent it is acting on")
        #expect(launcher.launched.first?.subject == "Lunch")

        // The inert launcher reports `unavailable`, which changes nothing about the record — the
        // honest outcome when nothing was opened.
        #expect(intent?.state == .draftPrepared)
        #expect(try interactions(in: services).isEmpty)
    }

    @Test("A body reaches the composer without being stored")
    func bodiesArePassedThroughButNotKept() throws {
        // The two decisions are separate: handing text to another application is what the user asked
        // for, and keeping a copy of it is not.
        let (services, launcher, _) = makeServices()
        let maya = try makePerson("Maya Chen", in: services)

        let intent = services.communicationConfirmations.start(
            channel: .email,
            people: [maya],
            recipients: [CommunicationRecipient(handle: "maya@example.com")],
            subject: "Results",
            body: "The biopsy came back clear."
        )

        #expect(launcher.launched.first?.body == "The biopsy came back clear.")
        #expect(intent?.intendedBody == nil)

        let stored = try services.communications.record(id: intent?.id ?? UUID())
        #expect(stored?.intendedBody == nil)
    }

    @Test("A contact action from a person's page routes through the layer")
    func contactActionsAreTracked() throws {
        let (services, launcher, _) = makeServices()
        let maya = try makePerson("Maya Chen", in: services)

        let intent = services.communicationConfirmations.start(
            contactChannel: .call,
            person: maya,
            destination: ContactDestination(label: "mobile", value: "512-555-0192", source: .phone)
        )

        #expect(intent?.channel == .phoneCall)
        #expect(launcher.launched.count == 1)
        #expect(intent?.personIDs == [maya.id])
    }

    @Test("Opening a map is not a communication")
    func nonCommunicationChannelsAreRefused() throws {
        let (services, launcher, _) = makeServices()
        let maya = try makePerson("Maya Chen", in: services)

        let intent = services.communicationConfirmations.start(
            contactChannel: .maps,
            person: maya,
            destination: ContactDestination(label: "home", value: "Austin, TX", source: .address)
        )

        #expect(intent == nil)
        #expect(launcher.launched.isEmpty, "nobody is on the other end of a map")
        #expect(try services.communications.allRecords().isEmpty)
    }

    // MARK: - Reports

    @Test("A share callback reaches the record")
    func launcherReportsAreApplied() throws {
        let (services, launcher, _) = makeServices()
        let maya = try makePerson("Maya Chen", in: services)

        guard let intent = services.communicationConfirmations.start(
            channel: .email,
            people: [maya],
            recipients: [CommunicationRecipient(handle: "maya@example.com")]
        ) else {
            Issue.record("the intent was not created")
            return
        }

        // Delivered synchronously rather than through the stream, so the assertion does not depend
        // on task scheduling. `beginObserving` feeds the same method.
        services.communicationConfirmations.receive(
            CommunicationLaunchReport(
                intentID: intent.id,
                channel: .email,
                mechanism: .sharingService,
                outcome: .shareCompleted,
                occurredAt: services.dateProvider.now
            )
        )
        _ = launcher

        let stored = try services.communications.record(id: intent.id)
        #expect(stored?.state == .shareCompleted)
        #expect(try interactions(in: services).isEmpty, "handed off is not sent")
    }

    @Test("A report for a message this app never launched changes nothing")
    func unknownReportsAreIgnored() throws {
        let (services, _, _) = makeServices()

        services.communicationConfirmations.receive(
            CommunicationLaunchReport(
                intentID: UUID(),
                channel: .email,
                mechanism: .sharingService,
                outcome: .shareCompleted,
                occurredAt: services.dateProvider.now
            )
        )

        #expect(try services.communications.allRecords().isEmpty)
        #expect(services.lastError == nil, "a lost callback is not something to blame the user for")
    }

    // MARK: - Asking

    @Test("A handoff nobody can report on becomes a question, once")
    func questionsAreRaisedAndSpent() throws {
        let (services, _, _) = makeServices()
        let maya = try makePerson("Maya Chen", in: services)

        guard let intent = services.communicationConfirmations.start(
            channel: .message,
            people: [maya],
            recipients: [CommunicationRecipient(handle: "5125550192", personID: maya.id, displayName: "Maya")]
        ) else {
            Issue.record("the intent was not created")
            return
        }

        services.communicationConfirmations.receive(
            CommunicationLaunchReport(
                intentID: intent.id, channel: .message, mechanism: .urlScheme,
                outcome: .composerOpened, occurredAt: services.dateProvider.now
            )
        )

        services.communicationConfirmations.refreshPendingQuestion()
        let question = services.communicationConfirmations.pendingQuestion
        #expect(question?.id == intent.id)
        #expect(question?.confirmationQuestion() == "Did you send this message to Maya?")

        // Coming back to the app again within the rate limit does not re-raise it.
        services.communicationConfirmations.refreshPendingQuestion()
        #expect(services.communicationConfirmations.pendingQuestion == nil)
    }

    @Test("Answering “sent” creates one interaction on the person's page")
    func confirmingCreatesTheInteraction() throws {
        let (services, _, _) = makeServices()
        let maya = try makePerson("Maya Chen", in: services)

        guard let intent = services.communicationConfirmations.start(
            channel: .message,
            people: [maya],
            recipients: [CommunicationRecipient(handle: "5125550192", personID: maya.id, displayName: "Maya")]
        ) else {
            Issue.record("the intent was not created")
            return
        }
        services.communicationConfirmations.receive(
            CommunicationLaunchReport(
                intentID: intent.id, channel: .message, mechanism: .urlScheme,
                outcome: .composerOpened, occurredAt: services.dateProvider.now
            )
        )

        services.communicationConfirmations.refreshPendingQuestion()
        services.communicationConfirmations.answer(.sent)

        #expect(services.communicationConfirmations.pendingQuestion == nil)

        let rows = try interactions(in: services)
        #expect(rows.count == 1)
        #expect(rows.first?.title == "Message sent")

        // And the timeline says who says so, rather than presenting it as observed.
        let timeline = try services.personWorkspace.timeline(for: maya)
        let entry = try #require(timeline.first { $0.kind == .interaction })
        #expect(entry.statusLabel?.headline == "Message sent")
        #expect(entry.statusLabel?.detail == "confirmed by you")
        #expect(entry.isContact)
    }

    @Test("A handed-off message on the timeline does not count as having been in touch")
    func handedOffRowsAreNotContact() throws {
        // The line that makes the last-contact figure worth trusting: it is never wrong in the
        // direction of claiming contact that did not happen.
        let (services, _, _) = makeServices()
        let maya = try makePerson("Maya Chen", in: services)

        guard let intent = services.communicationConfirmations.start(
            channel: .email,
            people: [maya],
            recipients: [CommunicationRecipient(handle: "maya@example.com", personID: maya.id)]
        ) else {
            Issue.record("the intent was not created")
            return
        }

        services.communicationConfirmations.receive(
            CommunicationLaunchReport(
                intentID: intent.id, channel: .email, mechanism: .sharingService,
                outcome: .shareCompleted, occurredAt: services.dateProvider.now
            )
        )

        // Nothing on the timeline at all yet, because no interaction was earned.
        let timeline = try services.personWorkspace.timeline(for: maya)
        #expect(!timeline.contains { $0.kind == .interaction })

        let context = services.people.context(for: maya)
        #expect(context.lastContact == nil, "a share callback must not move the last-contact line")
    }

    @Test("Dismissing stops the question and records nothing about the message")
    func dismissalIsHonoured() throws {
        let (services, _, _) = makeServices()
        let maya = try makePerson("Maya Chen", in: services)

        guard let intent = services.communicationConfirmations.start(
            channel: .message,
            people: [maya],
            recipients: [CommunicationRecipient(handle: "5125550192")]
        ) else {
            Issue.record("the intent was not created")
            return
        }
        services.communicationConfirmations.receive(
            CommunicationLaunchReport(
                intentID: intent.id, channel: .message, mechanism: .urlScheme,
                outcome: .composerOpened, occurredAt: services.dateProvider.now
            )
        )

        services.communicationConfirmations.refreshPendingQuestion()
        services.communicationConfirmations.answer(.dismissed)

        let stored = try services.communications.record(id: intent.id)
        #expect(stored?.dismissedAt != nil)
        #expect(stored?.state == .composerOpened, "a dismissal says nothing about whether it was sent")
        #expect(try interactions(in: services).isEmpty)

        services.communicationConfirmations.refreshPendingQuestion()
        #expect(services.communicationConfirmations.pendingQuestion == nil)
    }

    // MARK: - Calls

    @Test("A call offers to be logged, and logs only what it is told")
    func callsAreOfferedAndLoggedManually() throws {
        let (services, _, _) = makeServices()
        let maya = try makePerson("Maya Chen", in: services)

        guard let intent = services.communicationConfirmations.start(
            channel: .phoneCall,
            people: [maya],
            recipients: [CommunicationRecipient(handle: "5125550192", personID: maya.id, displayName: "Maya")]
        ) else {
            Issue.record("the intent was not created")
            return
        }

        // The inert launcher opens nothing, so the offer is raised by feeding the report a real
        // launcher would have returned.
        services.communicationConfirmations.receive(
            CommunicationLaunchReport(
                intentID: intent.id, channel: .phoneCall, mechanism: .urlScheme,
                outcome: .composerOpened, occurredAt: services.dateProvider.now
            )
        )
        services.communicationConfirmations.refreshPendingQuestion()

        // Logging goes through the same record, whichever prompt raised it.
        guard let record = try services.communications.record(id: intent.id) else {
            Issue.record("the record vanished")
            return
        }
        try services.communications.logCall(.leftVoicemail, for: record, notes: "About the move")

        let rows = try interactions(in: services)
        #expect(rows.count == 1)
        #expect(rows.first?.title == "Call — left voicemail")

        // Recorded, and still not contact. Reaching somebody's voicemail is reaching their voicemail.
        let timeline = try services.personWorkspace.timeline(for: maya)
        let entry = try #require(timeline.first { $0.kind == .interaction })
        #expect(entry.statusLabel?.headline == "Call logged")
        #expect(entry.statusLabel?.detail == "left voicemail · confirmed manually")
        #expect(!entry.isContact, "a call that reached voicemail is not a conversation")
    }

    @Test("A connected call is contact, and says who says so")
    func aConnectedCallIsContact() throws {
        let (services, _, _) = makeServices()
        let maya = try makePerson("Maya Chen", in: services)

        guard let intent = services.communicationConfirmations.start(
            channel: .phoneCall,
            people: [maya],
            recipients: [CommunicationRecipient(handle: "5125550192", personID: maya.id, displayName: "Maya")]
        ), let record = try services.communications.record(id: intent.id) else {
            Issue.record("the intent was not created")
            return
        }

        try services.communications.logCall(.connected, for: record, duration: 12 * 60)

        let entry = try #require(
            services.personWorkspace.timeline(for: maya).first { $0.kind == .interaction }
        )
        #expect(entry.title == "Call — connected (12 min)")
        #expect(entry.statusLabel?.sentence == "Call logged · connected · confirmed manually")
        #expect(entry.isContact)
    }

    // MARK: - Working without any of it

    @Test("The app works with no launcher, no provider, and no extension")
    func everythingIsOptional() throws {
        // Acceptance 16. The inert launcher *is* the unconfigured case, `NoProviderMessageService` is
        // what every build ships, and no Mail extension exists — so this is the ordinary path rather
        // than a degraded one.
        let (services, _, _) = makeServices()
        let maya = try makePerson("Maya Chen", in: services)

        #expect(services.messageProvider.providerName == "No provider")

        let intent = services.communicationConfirmations.start(
            channel: .email,
            people: [maya],
            recipients: [CommunicationRecipient(handle: "maya@example.com", personID: maya.id)]
        )
        #expect(intent != nil, "a communication is still recorded when nothing can be launched")

        // And the person's page still assembles.
        let timeline = try services.personWorkspace.timeline(for: maya)
        #expect(timeline.isEmpty)
        #expect(services.lastError == nil)
    }
}
