import ElephruitCore
import ElephruitFeatures
import ElephruitFeaturesCore
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

/// Claiming a piece of the day for a piece of work, end to end.
///
/// The arithmetic is proved against a fixed clock in `TimeBlockTests`. What is proved here is the
/// *joining*: that the event which reaches the calendar carries the task's title and nothing else
/// about it, that the association between the two is written where only this device can read it,
/// that a refused write says why instead of failing silently, and that the block can be taken back.
///
/// `EKEventStore` is never constructed. The fixture provider is the only calendar these tests can
/// reach, which is what makes "no test writes to the developer's real calendar" true by construction.
@MainActor
@Suite("Blocking time for work")
struct TimeBlockJourneyTests {
    static let clock = SystemDateProvider()

    static func at(_ hour: Int) -> Date {
        let day = clock.startOfToday
        return clock.calendar.date(byAdding: .hour, value: hour, to: day) ?? day
    }

    static func services() async -> AppServices {
        let defaults = UserDefaults(suiteName: "timeblock.tests.\(UUID().uuidString)") ?? .standard
        let services = AppServices.inMemory(
            dateProvider: clock,
            populated: false,
            calendarProvider: { FixtureCalendarProvider(authorization: .authorized) },
            defaults: defaults
        )
        _ = await services.calendar.enable()
        return services
    }

    static func today(_ services: AppServices) async -> (model: TodayModel, actions: TodayActions) {
        let model = TodayModel(services: services)
        await model.reload()
        return (model, TodayActions(services: services, navigation: NavigationModel(), model: model))
    }

    /// An afternoon with nothing in it, named rather than discovered.
    ///
    /// The day's own free time depends on the hour the suite happens to run at — a test asking for
    /// "the first gap" at half past eleven at night is a test that fails on a late evening and
    /// nowhere else. What is being proved here is the write, so the gap is stated.
    static let gap = DayFreeSlot(range: at(14)..<at(16))

    // MARK: - What reaches the calendar

    @Test("A block carries the task's title, and nothing else the task knows")
    func blockCarriesOnlyTheTitle() async throws {
        let services = await Self.services()
        let task = try services.items.create(ItemDraft(kind: .reminder, title: "Draft the brief"))
        try services.items.update(task) { item in
            item.body = "Ask Maya about the Q3 numbers before starting."
            item.estimateMinutes = 45
        }
        try services.reminderLifecycle.commitToToday(task)

        let (model, actions) = await Self.today(services)
        let plan = try #require(model.selectedPlan)
        let proposal = try #require(actions.proposal(blocking: task, in: Self.gap, on: plan))

        #expect(proposal.title == "Draft the brief")
        #expect(proposal.length == 45 * 60, "The estimate is the length, and the gap could hold it")
        #expect(proposal.taskID == task.id)

        guard case .success(let created) = await actions.write(proposal) else {
            Issue.record("Writing a block into an empty afternoon should have succeeded")
            return
        }

        #expect(created.title == "Draft the brief")
        #expect(created.duration == 45 * 60)
        // The private half of the task stays in the library. A calendar event syncs to an account
        // other people may be able to read, and the note about Maya is not for them.
        #expect(created.notes?.isEmpty ?? true)
        #expect(created.locationName?.isEmpty ?? true)
    }

    @Test("A block shows as busy or free exactly as it was asked to")
    func availabilityIsCarriedThrough() async throws {
        let services = await Self.services()
        let (model, actions) = await Self.today(services)
        let plan = try #require(model.selectedPlan)

        var proposal = try #require(actions.proposal(blocking: nil, in: Self.gap, on: plan))
        // Defended time, which is the point for somebody protecting an afternoon from other
        // people's scheduling assistants.
        proposal.availability = .busy
        guard case .success(let defended) = await actions.write(proposal) else {
            Issue.record("Writing a focus block should have succeeded")
            return
        }
        #expect(defended.availability == .busy)

        // And the other answer, which is the point for somebody who blocks time as a note to self
        // and still expects to be invited to things. There is no default that is right for both.
        proposal.availability = .free
        guard case .success(let noted) = await actions.write(proposal) else {
            Issue.record("Writing a second block should have succeeded")
            return
        }
        #expect(noted.availability == .free)
    }

    // MARK: - The link that stays here

    @Test("The block remembers what it was for, on this device only")
    func theLinkIsWrittenLocally() async throws {
        let services = await Self.services()
        let task = try services.items.create(ItemDraft(kind: .reminder, title: "Rewrite the deck"))
        try services.reminderLifecycle.commitToToday(task)

        let (model, actions) = await Self.today(services)
        let plan = try #require(model.selectedPlan)
        let proposal = try #require(actions.proposal(blocking: task, in: Self.gap, on: plan))

        guard case .success(let created) = await actions.write(proposal) else {
            Issue.record("Writing a block should have succeeded")
            return
        }

        let meeting = try #require(try services.eventLinks.meetingItem(for: created))
        let linked = (meeting.outgoingLinks ?? []).compactMap(\.target?.id)
        #expect(linked.contains(task.id), """
            Without this the block is an event named after a task with no relationship to it, and \
            every surface that could show one beside the other has nothing to go on.
            """)
        // The association lives on the annotation. Nothing about it was handed to the provider.
        #expect(created.notes?.contains(task.id.uuidString) != true)
    }

    // MARK: - When it cannot be written

    @Test("A refused write says why, and leaves nothing behind")
    func aRefusedWriteExplainsItself() async throws {
        let services = await Self.services()
        let (model, actions) = await Self.today(services)
        let plan = try #require(model.selectedPlan)

        var proposal = try #require(actions.proposal(blocking: nil, in: Self.gap, on: plan))
        // A subscribed feed is read-only whatever its flag says — the state a person hits by having
        // one selected when they press the button.
        proposal.calendarIdentifier = "fixture.holidays"

        let before = services.calendar.events.count
        guard case .failure(let failure) = await actions.write(proposal) else {
            Issue.record("Writing to a subscribed calendar must not succeed")
            return
        }

        #expect(failure.message.contains("UK Holidays"), "A refusal names what refused")
        #expect(!failure.isWorthRetrying, "Pressing it again will never work, and the interface must know")
        #expect(services.calendar.events.count == before)
    }

    @Test("A day with no calendar to write to proposes nothing at all")
    func noWritableCalendarMeansNoProposal() async throws {
        let defaults = UserDefaults(suiteName: "timeblock.tests.\(UUID().uuidString)") ?? .standard
        let services = AppServices.inMemory(
            dateProvider: Self.clock,
            populated: false,
            calendarProvider: { FixtureCalendarProvider(authorization: .denied) },
            defaults: defaults
        )
        let (model, actions) = await Self.today(services)
        let plan = try #require(model.selectedPlan)

        // Nil rather than a proposal that cannot be written: a state the interface explains up
        // front, rather than a failure reported after somebody has filled in a form.
        #expect(actions.proposal(blocking: nil, in: Self.gap, on: plan) == nil)
    }

    // MARK: - Taking it back

    @Test("A block just written can be taken back")
    func undoRemovesTheBlock() async throws {
        let services = await Self.services()
        let (model, actions) = await Self.today(services)
        let plan = try #require(model.selectedPlan)
        let proposal = try #require(actions.proposal(blocking: nil, in: Self.gap, on: plan))

        guard case .success(let created) = await actions.write(proposal) else {
            Issue.record("Writing a focus block should have succeeded")
            return
        }
        #expect(services.calendar.events.contains { $0.identity == created.identity })

        guard case .success = await actions.removeBlock(created) else {
            Issue.record("Removing a block written a moment ago should have succeeded")
            return
        }
        #expect(!services.calendar.events.contains { $0.identity == created.identity }, """
            The fastest way to make somebody distrust a button that writes to their calendar is for \
            the first thing it writes to be wrong and hard to remove.
            """)
    }

    // MARK: - What is offered

    @Test("Work that already has a time of its own is not offered a second one")
    func pinnedWorkIsNotOffered() async throws {
        let services = await Self.services()

        let loose = try services.items.create(ItemDraft(kind: .reminder, title: "Think about pricing"))
        try services.reminderLifecycle.commitToToday(loose)

        let pinned = try services.items.create(ItemDraft(kind: .reminder, title: "Call the bank"))
        try services.reminderLifecycle.commitToToday(pinned)
        try services.reminderLifecycle.setReminder(Self.at(11), timed: true, on: pinned)

        let (model, actions) = await Self.today(services)
        let plan = try #require(model.selectedPlan)
        let offered = actions.work(for: Self.gap, in: plan).map(\.title)

        #expect(offered.contains("Think about pricing"))
        #expect(!offered.contains("Call the bank"), """
            Half past eleven is already where that task lives. Offering to give it a second place in \
            the day is offering to double-book somebody against themselves.
            """)
    }
}
