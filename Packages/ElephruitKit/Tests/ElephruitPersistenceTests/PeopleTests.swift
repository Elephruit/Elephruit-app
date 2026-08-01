import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

@MainActor
private struct PeopleFixture {
    let store: StoreFixture
    let people: PeopleService
    var clock: any DateProvider { store.dateProvider }

    init() throws {
        store = try StoreFixture()
        people = PeopleService(items: store.items, dateProvider: store.dateProvider)
    }

    var now: Date { clock.now }

    func makePerson(_ name: String) throws -> Item {
        try store.items.create(ItemDraft(kind: .person, title: name))
    }

    /// Links `source` at `person`, which is how a mention is recorded everywhere in the app.
    func mention(_ person: Item, from source: Item) throws {
        try store.items.link(source, to: person, kind: .mentions)
    }
}

@Suite("Person context")
@MainActor
struct PersonContextTests {
    @Test("Someone with no history says so rather than looking neglected")
    func emptyHistory() throws {
        let fixture = try PeopleFixture()
        let ana = try fixture.makePerson("Ana Ferreira")

        let context = fixture.people.context(for: ana)

        #expect(context.lastContact == nil)
        #expect(context.mentionCount == 0)
        #expect(context.summary(using: fixture.clock).contains("Nothing recorded yet"))
        #expect(context.daysSinceLastContact(using: fixture.clock) == nil,
                "No contact is not the same as contact infinitely long ago")
    }

    /// The distinction that keeps a follow-up suggestion honest.
    @Test("A task about someone is not the same as having spoken to them")
    func mentionsAreNotContact() throws {
        let fixture = try PeopleFixture()
        let ana = try fixture.makePerson("Ana")

        // Spoke three months ago…
        try fixture.people.recordInteraction(
            with: ana, summary: "Long chat", at: fixture.now.addingTimeInterval(-90 * 86_400)
        )
        // …and wrote a task about her this morning.
        let task = try fixture.store.items.create(ItemDraft(kind: .task, title: "Email Ana"))
        try fixture.mention(ana, from: task)

        let context = fixture.people.context(for: ana)

        // Writing a task about someone is not contact; counting it would make "you last spoke 90
        // days ago" quietly false for anyone whose name appears in your work.
        #expect(context.daysSinceLastContact(using: fixture.clock) == 90)
        #expect(context.lastMention?.title == "Email Ana", "…but it is the most recent mention")
    }

    @Test("Someone mentioned but never spoken to says exactly that")
    func mentionedButNeverSpokenTo() throws {
        let fixture = try PeopleFixture()
        let ana = try fixture.makePerson("Ana")

        let note = try fixture.store.items.create(ItemDraft(kind: .note, title: "Intro from Ben"))
        try fixture.mention(ana, from: note)

        let context = fixture.people.context(for: ana)
        #expect(context.lastContact == nil)
        #expect(context.lastMention != nil)
        #expect(context.summary(using: fixture.clock).contains("not yet spoken"))
    }

    @Test("The last mention is the most recent thing that references them")
    func lastContactIsNewest() throws {
        let fixture = try PeopleFixture()
        let ana = try fixture.makePerson("Ana")

        let older = try fixture.store.items.create(ItemDraft(kind: .note, title: "Old note"))
        try fixture.store.items.update(older) { $0.createdAt = fixture.now.addingTimeInterval(-30 * 86_400) }
        try fixture.mention(ana, from: older)

        let newer = try fixture.store.items.create(ItemDraft(kind: .note, title: "Recent note"))
        try fixture.store.items.update(newer) { $0.createdAt = fixture.now.addingTimeInterval(-2 * 86_400) }
        try fixture.mention(ana, from: newer)

        let context = fixture.people.context(for: ana)
        #expect(context.lastMention?.title == "Recent note")
        #expect(context.mentionCount == 2)
    }

    @Test("A meeting counts at its scheduled time, not when it was written")
    func meetingsUseTheirOwnTime() throws {
        let fixture = try PeopleFixture()
        let ana = try fixture.makePerson("Ana")

        // Written today, about a meeting three weeks ago. It is the meeting that happened then.
        let meeting = try fixture.store.items.create(ItemDraft(kind: .meeting, title: "Kickoff"))
        try fixture.store.items.update(meeting) { $0.startAt = fixture.now.addingTimeInterval(-21 * 86_400) }
        try fixture.mention(ana, from: meeting)

        let context = fixture.people.context(for: ana)
        #expect(context.daysSinceLastContact(using: fixture.clock) == 21,
                "Using the write date would say we spoke today, which is false")
    }

    @Test("A future meeting is what is next, not what was last")
    func futureMeetingsAreNext() throws {
        let fixture = try PeopleFixture()
        let ana = try fixture.makePerson("Ana")

        let past = try fixture.store.items.create(ItemDraft(kind: .meeting, title: "Last week"))
        try fixture.store.items.update(past) { $0.startAt = fixture.now.addingTimeInterval(-7 * 86_400) }
        try fixture.mention(ana, from: past)

        let upcoming = try fixture.store.items.create(ItemDraft(kind: .meeting, title: "Next Tuesday"))
        try fixture.store.items.update(upcoming) { $0.startAt = fixture.now.addingTimeInterval(5 * 86_400) }
        try fixture.mention(ana, from: upcoming)

        let context = fixture.people.context(for: ana)
        #expect(context.lastContact?.title == "Last week")
        #expect(context.nextContact?.title == "Next Tuesday")
    }

    @Test("Open tasks that mention them are counted; finished ones are not")
    func openWork() throws {
        let fixture = try PeopleFixture()
        let ana = try fixture.makePerson("Ana")

        let open = try fixture.store.items.create(ItemDraft(kind: .task, title: "Send the brief"))
        try fixture.mention(ana, from: open)

        let done = try fixture.store.items.create(ItemDraft(kind: .task, title: "Already sent"))
        try fixture.mention(ana, from: done)
        try fixture.store.items.toggleCompletion(done)

        let context = fixture.people.context(for: ana)
        #expect(context.openItemIDs == [open.id])
    }

    @Test("A deleted mention stops counting")
    func deletedMentionsAreIgnored() throws {
        let fixture = try PeopleFixture()
        let ana = try fixture.makePerson("Ana")

        let note = try fixture.store.items.create(ItemDraft(kind: .note, title: "Doomed"))
        try fixture.mention(ana, from: note)
        try fixture.store.items.moveToTrash(note)

        #expect(fixture.people.context(for: ana).mentionCount == 0)
    }

    @Test("The summary reads as a sentence")
    func summaryIsReadable() throws {
        let fixture = try PeopleFixture()
        let ana = try fixture.makePerson("Ana")

        let meeting = try fixture.store.items.create(ItemDraft(kind: .meeting, title: "Kickoff"))
        try fixture.store.items.update(meeting) { $0.startAt = fixture.now.addingTimeInterval(-86_400) }
        try fixture.mention(ana, from: meeting)

        let task = try fixture.store.items.create(ItemDraft(kind: .task, title: "Follow up"))
        try fixture.mention(ana, from: task)

        let summary = fixture.people.context(for: ana).summary(using: fixture.clock)
        #expect(summary.contains("met yesterday"), "The meeting is the contact, not the task")
        #expect(summary.contains("1 open item"))
    }
}

@Suite("Interactions and daily entries")
@MainActor
struct InteractionTests {
    @Test("Recording a conversation makes it the last contact")
    func recordingUpdatesContact() throws {
        let fixture = try PeopleFixture()
        let ana = try fixture.makePerson("Ana")

        #expect(fixture.people.context(for: ana).lastContact == nil)

        try fixture.people.recordInteraction(with: ana, summary: "Caught up about the launch")

        let context = fixture.people.context(for: ana)
        #expect(context.lastContact?.title == "Caught up about the launch")
        #expect(context.lastContact?.kind == .interaction)
        #expect(context.daysSinceLastContact(using: fixture.clock) == 0)
    }

    @Test("A conversation can be recorded after the fact")
    func backdatedInteraction() throws {
        let fixture = try PeopleFixture()
        let ana = try fixture.makePerson("Ana")

        try fixture.people.recordInteraction(
            with: ana,
            summary: "Phone call",
            at: fixture.now.addingTimeInterval(-3 * 86_400)
        )

        #expect(fixture.people.context(for: ana).daysSinceLastContact(using: fixture.clock) == 3)
    }

    @Test("Logging an interaction turns every next step into a task")
    func interactionBundleCreatesTasks() throws {
        let fixture = try PeopleFixture()
        let ana = try fixture.makePerson("Ana")

        let created = try fixture.people.recordInteractionBundle(
            with: ana,
            summary: "Project catch-up",
            kind: .phone,
            discussion: "Talked about the launch",
            followUps: ["Book Tuesday"],
            commitments: ["Send Ana the deck"]
        )

        #expect(created.count == 3)
        let interaction = try #require(created.first { $0.kind == .interaction })
        #expect(interaction.body == "Talked about the launch")
        #expect(interaction.tagSlugs.contains("interaction/phone"))

        let tasks = created.filter { $0.kind == .task }
        #expect(tasks.count == 2)
        #expect(tasks.allSatisfy { $0.status == .open })
        #expect(tasks.allSatisfy { !$0.tagSlugs.contains("promise") })
        #expect(fixture.people.context(for: ana).openItemIDs.count == 2)
    }

    @Test("One conversation appears in every attendee's history")
    func groupInteractionLinksEveryAttendee() throws {
        let fixture = try PeopleFixture()
        let ana = try fixture.makePerson("Ana")
        let maya = try fixture.makePerson("Maya")

        let created = try fixture.people.recordInteractionBundle(
            with: [ana, maya, ana],
            summary: "Conference call",
            kind: .video,
            followUps: ["Share the recording"]
        )

        #expect(created.filter { $0.kind == .interaction }.count == 1)
        #expect(fixture.people.context(for: ana).lastContact?.title == "Conference call")
        #expect(fixture.people.context(for: maya).lastContact?.title == "Conference call")
        #expect(fixture.people.context(for: ana).openItemIDs.count == 1)
        #expect(fixture.people.context(for: maya).openItemIDs.count == 1)
    }

    @Test("There is at most one daily entry per day")
    func oneEntryPerDay() throws {
        let fixture = try PeopleFixture()

        let first = try fixture.people.dailyEntry(for: fixture.now, creatingIfNeeded: true)
        let second = try fixture.people.dailyEntry(for: fixture.now, creatingIfNeeded: true)

        #expect(first?.id == second?.id, "Asking twice must not produce two entries for one day")
    }

    @Test("A daily entry is never created without being asked for")
    func dailyEntryIsNotAutomatic() throws {
        let fixture = try PeopleFixture()

        #expect(try fixture.people.dailyEntry(for: fixture.now, creatingIfNeeded: false) == nil)

        var query = ItemQuery()
        query.kinds = [.dailyEntry]
        #expect(try fixture.store.items.items(matching: query).isEmpty,
                "An app that makes a note every morning fills a library with empty days")
    }

    @Test("Different days get different entries")
    func entriesAreScopedToTheirDay() throws {
        let fixture = try PeopleFixture()

        let today = try fixture.people.dailyEntry(for: fixture.now, creatingIfNeeded: true)
        let yesterday = try fixture.people.dailyEntry(
            for: fixture.now.addingTimeInterval(-86_400),
            creatingIfNeeded: true
        )

        #expect(today?.id != yesterday?.id)
        #expect(today?.dayKey != yesterday?.dayKey)
    }
}

@Suite("Follow-up suggestions")
@MainActor
struct FollowUpTests {
    @Test("Someone recently spoken to is not suggested")
    func recentContactIsNotSuggested() throws {
        let fixture = try PeopleFixture()
        let ana = try fixture.makePerson("Ana")
        try fixture.people.recordInteraction(with: ana, summary: "Chat")

        #expect(try fixture.people.followUpSuggestions(thresholdDays: 42).isEmpty)
    }

    @Test("A long gap is suggested, most overdue first")
    func longGapsSurface() throws {
        let fixture = try PeopleFixture()

        let ana = try fixture.makePerson("Ana")
        try fixture.people.recordInteraction(
            with: ana, summary: "Old chat", at: fixture.now.addingTimeInterval(-60 * 86_400)
        )

        let ben = try fixture.makePerson("Ben")
        try fixture.people.recordInteraction(
            with: ben, summary: "Older chat", at: fixture.now.addingTimeInterval(-120 * 86_400)
        )

        let suggestions = try fixture.people.followUpSuggestions(thresholdDays: 42)

        #expect(suggestions.map(\.displayName) == ["Ben", "Ana"], "Longest gap first")
        #expect(suggestions.first?.daysSinceContact == 120)
    }

    @Test("Someone never spoken to is never suggested")
    func noHistoryIsNotOverdue() throws {
        let fixture = try PeopleFixture()
        _ = try fixture.makePerson("A name typed once")

        #expect(try fixture.people.followUpSuggestions(thresholdDays: 42).isEmpty,
                "Treating an empty record as overdue by forever would list everyone ever named")
    }

    /// The standing rule, asserted rather than assumed.
    @Test("A suggestion never creates, schedules, or changes anything")
    func suggestionsNeverAct() throws {
        let fixture = try PeopleFixture()
        let ana = try fixture.makePerson("Ana")
        try fixture.people.recordInteraction(
            with: ana, summary: "Old chat", at: fixture.now.addingTimeInterval(-90 * 86_400)
        )

        let before = try fixture.store.items.items(matching: .everything()).count

        let suggestions = try fixture.people.followUpSuggestions(thresholdDays: 42)
        #expect(!suggestions.isEmpty)

        let after = try fixture.store.items.items(matching: .everything()).count
        #expect(after == before, "Asking for suggestions must not write anything at all")

        // And nothing was scheduled against the person either.
        let context = fixture.people.context(for: ana)
        #expect(context.openItemIDs.isEmpty, "No task was invented on the user's behalf")
        #expect(context.nextContact == nil, "Nothing was scheduled")
    }

    @Test("The threshold is honoured exactly")
    func thresholdBoundary() throws {
        let fixture = try PeopleFixture()
        let ana = try fixture.makePerson("Ana")
        try fixture.people.recordInteraction(
            with: ana, summary: "Chat", at: fixture.now.addingTimeInterval(-42 * 86_400)
        )

        #expect(try fixture.people.followUpSuggestions(thresholdDays: 42).count == 1, "…on the day")
        #expect(try fixture.people.followUpSuggestions(thresholdDays: 43).isEmpty, "…and not before")
    }
}

@Suite("Relative dates read as English")
struct ContactMomentTests {
    private let clock = FixedDateProvider.reference

    private func moment(daysAgo: Int) -> ContactMoment {
        ContactMoment(
            id: UUID(),
            kind: .interaction,
            title: "Chat",
            date: clock.startOfToday.addingTimeInterval(TimeInterval(-daysAgo * 86_400))
        )
    }

    @Test("Each distance gets the phrasing that reads best")
    func phrasing() {
        #expect(moment(daysAgo: 0).relativeDescription(using: clock) == "today")
        #expect(moment(daysAgo: 1).relativeDescription(using: clock) == "yesterday")
        #expect(moment(daysAgo: 3).relativeDescription(using: clock) == "3 days ago")
        #expect(moment(daysAgo: 9).relativeDescription(using: clock) == "last week")
        #expect(moment(daysAgo: 21).relativeDescription(using: clock) == "3 weeks ago")
        #expect(moment(daysAgo: 90).relativeDescription(using: clock) == "3 months ago")
        #expect(moment(daysAgo: -1).relativeDescription(using: clock) == "tomorrow")
    }

    @Test("What kind of contact it was is said plainly")
    func kindDescriptions() {
        #expect(ContactMoment(id: UUID(), kind: .meeting, title: "", date: Date()).kindDescription == "met")
        #expect(ContactMoment(id: UUID(), kind: .interaction, title: "", date: Date()).kindDescription == "spoke")
        #expect(ContactMoment(id: UUID(), kind: .note, title: "", date: Date()).kindDescription == "mentioned")
    }
}
