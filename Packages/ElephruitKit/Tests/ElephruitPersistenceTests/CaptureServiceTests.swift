import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// **Criterion A1-17** — capture is invocable without any view being constructed.
///
/// That is the whole point of the seam. Quick Capture has to work from an App Intent, from the
/// Services menu, and eventually from a global hotkey, none of which can build a SwiftUI view. If the
/// path from typed text to stored item ran inside the panel, none of those could ever reuse it.
@MainActor
@Suite("Capture service")
struct CaptureServiceTests {
    private func makeService(_ fixture: StoreFixture) -> CaptureService {
        CaptureService(items: fixture.items, context: fixture.context, dateProvider: fixture.dateProvider)
    }

    @Test("A line of text becomes an item, with no view involved")
    func capturesFromTextAlone() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        let item = try #require(try service.capture(text: "Think about the launch plan"))

        #expect(item.kind == .note)
        #expect(item.title == "Think about the launch plan")
        #expect(item.source.kind == .quickCapture)
    }

    @Test("The inline grammar is honoured end to end")
    func grammarIsApplied() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        let item = try #require(try service.capture(text: "- Send the invoice #urgent !tomorrow"))

        #expect(item.kind == .task)
        #expect(item.title == "Send the invoice")
        #expect(item.tagSlugs == ["urgent"])
        #expect(item.dueAt == fixture.dateProvider.startOfDay(daysFromToday: 1))
    }

    @Test("A project hint files the capture")
    func projectHintIsResolved() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Q3 Launch")
        let service = makeService(fixture)

        let item = try #require(try service.capture(text: "- Draft the brief >\"Q3 Launch\""))
        #expect(item.parent?.id == project.id)
    }

    @Test("A prefix finds the project, but nothing guesses wildly")
    func hintsResolveByPrefix() throws {
        let fixture = try StoreFixture()
        _ = try fixture.makeProject(title: "Q3 Launch")
        let service = makeService(fixture)

        #expect(try service.resolveContainer(named: "Q3")?.title == "Q3 Launch")
        #expect(try service.resolveContainer(named: "zzz") == nil)
    }

    @Test("An unresolvable project hint still captures, to the Inbox")
    func unresolvableHintIsNotAnError() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        let item = try #require(try service.capture(text: "- Something >NoSuchProject"))

        #expect(item.parent == nil, "It lands in the Inbox, which is where an unfiled capture belongs")
        #expect(try fixture.items.items(matching: .inbox()).contains { $0.id == item.id })
    }

    @Test("Naming a person creates and links them")
    func peopleAreCreatedAndLinked() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        let item = try #require(try service.capture(text: "Follow up with @Sarah"))

        let people = try fixture.items.items(matching: .kind(.person))
        #expect(people.count == 1)
        #expect(people.first?.title == "Sarah")
        #expect(item.outgoingLinks.contains { $0.kind == .mentions })
    }

    @Test("An existing person is reused rather than duplicated")
    func existingPeopleAreReused() throws {
        let fixture = try StoreFixture()
        let existing = try fixture.items.create(ItemDraft(kind: .person, title: "Sarah Chen"))
        let service = makeService(fixture)

        _ = try service.capture(text: "Chat with @\"sarah chen\"")

        #expect(try fixture.items.items(matching: .kind(.person)).count == 1)
        #expect(existing.incomingLinks.contains { $0.kind == .mentions })
    }

    /// An App Intent's process can exit the moment `perform()` returns.
    ///
    /// `linkPeople` used to `context.insert` the link and leave it to autosave, which is a bet that
    /// the process lives long enough for autosave to fire. In the app it usually does. In an intent
    /// invoked from Spotlight it need not, and the person link — the whole point of typing `@Sarah` —
    /// would be the part that went missing.
    ///
    /// Asserted through a second context over the same container, because the first context's
    /// in-memory graph shows the link whether or not it was ever written.
    @Test("A capture leaves nothing pending, so a process that exits immediately loses nothing")
    func captureCommitsEverythingItWrote() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        let item = try #require(try service.capture(text: "Follow up with @Sarah #urgent"))

        #expect(fixture.context.hasChanges == false, "capture returned with work still uncommitted")

        let fresh = fixture.freshContext()
        let links = try fresh.fetch(FetchDescriptor<ItemLink>())
        #expect(links.contains { $0.kind == .mentions && $0.source?.id == item.id })
    }

    @Test("Linking an existing person also commits")
    func linkingAnExistingPersonCommits() throws {
        let fixture = try StoreFixture()
        _ = try fixture.items.create(ItemDraft(kind: .person, title: "Sarah"))
        let service = makeService(fixture)

        _ = try #require(try service.capture(text: "Chat with @Sarah"))

        #expect(fixture.context.hasChanges == false)
        let fresh = fixture.freshContext()
        #expect(try fresh.fetch(FetchDescriptor<ItemLink>()).contains { $0.kind == .mentions })
    }

    // MARK: - due: and follow:

    /// The distinction the token exists for, asserted through the filters that actually implement
    /// it rather than by reading the field back.
    @Test("follow: hides an item from Today until the day, and never makes it overdue")
    func followDateDefersRatherThanNags() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        let item = try #require(try service.capture(text: "Chase the invoice follow:+3d"))

        let deferUntil = try #require(item.deferUntil)
        #expect(deferUntil == fixture.dateProvider.startOfDay(daysFromToday: 3))
        #expect(item.dueAt == nil, "a date to come back to is not a deadline")

        // Today's filter is where "not yet" is implemented.
        var today = ItemQuery()
        today.notDeferredAfter = fixture.dateProvider.startOfToday
        #expect(try fixture.items.items(matching: today).contains { $0.id == item.id } == false)

        // And on the day, it appears.
        var later = ItemQuery()
        later.notDeferredAfter = fixture.dateProvider.startOfDay(daysFromToday: 3)
        #expect(try fixture.items.items(matching: later).contains { $0.id == item.id })
    }

    @Test("due: sets a deadline, which can become overdue")
    func dueDateIsADeadline() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        let item = try #require(try service.capture(text: "File the return due:-1d"))

        let dueAt = try #require(item.dueAt)
        #expect(fixture.dateProvider.isOverdue(dueAt))
        #expect(item.deferUntil == nil)
    }

    @Test("A due time is kept, not rounded away to the start of the day")
    func dueTimesArePreserved() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        let item = try #require(try service.capture(text: "Review the deck due:tomorrow 3pm"))
        let dueAt = try #require(item.dueAt)

        #expect(fixture.dateProvider.calendar.component(.hour, from: dueAt) == 15)
    }

    @Test("A priority given in the text is applied")
    func priorityIsApplied() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        let item = try #require(try service.capture(text: "Submit the report due:friday !high"))
        #expect(item.priority == .high)
    }

    @Test("Empty input captures nothing rather than an empty item")
    func emptyInputIsIgnored() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        #expect(try service.capture(text: "   \n  ") == nil)
        #expect(try fixture.items.items(matching: .everything()).isEmpty)
    }

    // MARK: - Names with spaces

    /// The bug this addresses, end to end: `>Elephruit App` filed under a project called
    /// "Elephruit" — which resolution's prefix matching made *look* right — and left "App" behind in
    /// the title, where it read as part of the sentence.
    @Test("A project whose name has a space is named in full, and leaves nothing in the title")
    func multiWordProjectsAreNamedInFull() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Elephruit App")
        let service = makeService(fixture)

        let item = try #require(try service.capture(text: "- Ship the beta >Elephruit App"))

        #expect(item.parent?.id == project.id)
        #expect(item.title == "Ship the beta")
    }

    /// The worse half of the same bug. `@Mike Zehrer` took only "Mike", found no person by that
    /// name, and so *created* one — leaving two records for one person and the mention on the wrong
    /// one.
    @Test("A person whose name has a space is linked, not duplicated")
    func multiWordPeopleAreNotDuplicated() throws {
        let fixture = try StoreFixture()
        let existing = try fixture.items.create(ItemDraft(kind: .person, title: "Mike Zehrer"))
        let service = makeService(fixture)

        let item = try #require(try service.capture(text: "Ask @Mike Zehrer about the beta"))

        let people = try fixture.items.items(matching: .kind(.person))
        #expect(people.count == 1, "a second person called “Mike” was created")
        #expect(existing.incomingLinks.contains { $0.kind == .mentions })
        #expect(item.title == "Ask about the beta")
    }

    /// Reading across a space is bounded by what exists, so an unknown name behaves as it always
    /// did rather than swallowing the sentence.
    @Test("An unknown name still claims only its first word")
    func unknownNamesClaimOneWord() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        let item = try #require(try service.capture(text: "- Book it >Everest base camp"))

        #expect(item.parent == nil)
        #expect(item.title == "Book it base camp")
    }

    @Test("A URL becomes a bookmark carrying its link")
    func urlsBecomeBookmarks() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        let item = try #require(try service.capture(text: "https://example.com/article"))

        #expect(item.kind == .bookmark)
        #expect(item.source.url?.absoluteString == "https://example.com/article")
    }
}

/// The two hot paths fixed in A1.8.
@MainActor
@Suite("Hot paths")
struct HotPathTests {
    @Test("Resolving a wiki link is a lookup, not a scan of the library")
    func titleResolutionIsIndexed() throws {
        let audit = FetchAudit()
        let fixture = try StoreFixture(audit: audit)

        for index in 1...50 {
            _ = try fixture.makeNote(title: "Note \(index)")
        }
        _ = try fixture.makeNote(title: "Target Note")

        let source = try fixture.makeNote(title: "Source")

        // Writing a link used to fetch every active item and fold each title in Swift. Now it is one
        // bounded lookup, so the cost does not grow with the library.
        let (_, tally) = try audit.measure {
            try fixture.items.update(source) { $0.body = "See [[Target Note]]." }
        }

        #expect(tally.itemFetches <= 3, "Observed \(tally.description)")

        let link = try #require(try fixture.requireItem(id: source.id).outgoingLinks.first)
        #expect(link.target?.title == "Target Note")
    }

    @Test("The title key is kept current, so resolution cannot silently miss")
    func titleKeyFollowsRenames() throws {
        let fixture = try StoreFixture()
        let target = try fixture.makeNote(title: "Original Name")

        #expect(try fixture.requireItem(id: target.id).titleMatchKey == "original name")

        try fixture.items.update(target) { $0.title = "Renamed Café" }
        #expect(try fixture.requireItem(id: target.id).titleMatchKey == "renamed cafe")
    }

    @Test("Snapshots stream in batches instead of materialising the library")
    func snapshotsStreamInBatches() async throws {
        let fixture = try StoreFixture()
        for index in 1...25 {
            _ = try fixture.makeNote(title: "Note \(index)")
        }

        let worker = SnapshotWorker(modelContainer: fixture.stack.container)
        #expect(try await worker.itemCount() == 25)

        // Batched, so peak memory is bounded by the batch rather than by the library.
        let collector = BatchCollector()
        try await worker.streamSnapshots(batchSize: 10) { batch, _, _ in
            await collector.record(batch)
        }

        #expect(await collector.batchSizes == [10, 10, 5])
    }

    @Test("Paging is stably ordered, so no row is skipped or repeated")
    func pagingIsStable() async throws {
        let fixture = try StoreFixture()
        for index in 1...30 {
            _ = try fixture.makeNote(title: "Note \(index)")
        }

        let worker = SnapshotWorker(modelContainer: fixture.stack.container)

        // An unordered paged fetch is free to repeat a row and miss another, which would leave the
        // index quietly wrong.
        let collector = BatchCollector()
        try await worker.streamSnapshots(batchSize: 7) { batch, _, _ in
            await collector.record(batch)
        }

        let seen = await collector.identifiers
        #expect(seen.count == 30)
        #expect(Set(seen).count == 30, "No row seen twice")
    }
}

/// Accumulates what a streaming callback saw.
///
/// An actor rather than a lock behind `@unchecked Sendable`: the codebase forbids that annotation,
/// and a test is not a licence to do the thing the rule exists to prevent.
private actor BatchCollector {
    private(set) var batchSizes: [Int] = []
    private(set) var identifiers: [UUID] = []

    func record(_ batch: [ItemSnapshot]) {
        batchSizes.append(batch.count)
        identifiers.append(contentsOf: batch.map(\.id))
    }
}
