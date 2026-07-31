import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// The eight safety requirements the containment migration has to meet before it is allowed near a
/// real library — **M1 through M8** in `docs/10-phase-a-scope.md`.
///
/// A data migration is the one operation a user cannot undo by hand. These tests are the difference
/// between "it worked on my store" and "it is safe to run on yours".
@MainActor
@Suite("Migration safety", .serialized)
struct MigrationSafetyTests {
    // MARK: - Fixtures (M1)

    /// The shapes a real V1 library actually contains.
    ///
    /// Deliberately awkward: deep hierarchies, several kinds of now-illegal parent, an item with no
    /// parent at all, an empty store, and one whose container cannot receive a filing.
    enum Fixture: String, CaseIterable {
        case empty
        case notesUnderProject
        case notesUnderArea
        case deepHierarchy
        case mixedKinds
        case alreadyValid
        case containerThatCannotHoldFilings
        case large

        /// Builds the fixture using the *pre-restriction* rules, by writing relationships directly
        /// rather than through the repository — which would now refuse them.
        @discardableResult
        func build(in context: ModelContext) throws -> Int {
            switch self {
            case .empty:
                return 0

            case .notesUnderProject:
                let project = Self.make(.project, "Q3 Launch", in: context)
                for index in 1...5 {
                    let note = Self.make(.note, "Note \(index)", in: context)
                    note.parent = project
                }
                try context.save()
                return 6

            case .notesUnderArea:
                let area = Self.make(.area, "Work", in: context)
                for index in 1...3 {
                    let note = Self.make(.note, "Area note \(index)", in: context)
                    note.parent = area
                }
                try context.save()
                return 4

            case .deepHierarchy:
                let area = Self.make(.area, "Work", in: context)
                let project = Self.make(.project, "Launch", in: context)
                project.parent = area
                let task = Self.make(.task, "A task", in: context)
                task.parent = project
                let subtask = Self.make(.task, "A subtask", in: context)
                subtask.parent = task
                let note = Self.make(.note, "A filed note", in: context)
                note.parent = project
                try context.save()
                return 5

            case .mixedKinds:
                let project = Self.make(.project, "Launch", in: context)
                for kind in [ItemKind.note, .bookmark, .idea, .reference, .decision, .meeting] {
                    let item = Self.make(kind, "\(kind.displayName) item", in: context)
                    item.parent = project
                }
                try context.save()
                return 7

            case .alreadyValid:
                let project = Self.make(.project, "Launch", in: context)
                let heading = Self.make(.heading, "Planning", in: context)
                heading.parent = project
                let task = Self.make(.task, "A task", in: context)
                task.parent = heading
                try context.save()
                return 3

            case .containerThatCannotHoldFilings:
                // A note under a daily entry. The daily entry is not a work container, so the
                // association cannot become a filing and must be reported rather than invented.
                let day = Self.make(.dailyEntry, "2026-07-30", in: context)
                let note = Self.make(.note, "Something from that day", in: context)
                note.parent = day
                try context.save()
                return 2

            case .large:
                let project = Self.make(.project, "Big", in: context)
                for index in 1...500 {
                    let note = Self.make(.note, "Note \(index)", in: context)
                    note.parent = project
                }
                try context.save()
                return 501
            }
        }

        private static func make(_ kind: ItemKind, _ title: String, in context: ModelContext) -> Item {
            let item = Item(kind: kind, title: title, body: "Body of \(title)")
            item.refreshSearchText()
            context.insert(item)
            return item
        }
    }

    /// A snapshot of everything the migration must not disturb — used for **M3**.
    struct GraphFingerprint: Equatable {
        var titles: Set<String>
        var bodies: Set<String>
        var tagSlugs: Set<String>
        var createdAt: Set<Date>
        var sortOrders: Set<Double>
        var favourites: Int
        var otherLinkCount: Int

        init(_ items: [Item]) {
            titles = Set(items.map(\.title))
            bodies = Set(items.map(\.body))
            tagSlugs = Set(items.flatMap(\.tagSlugs))
            createdAt = Set(items.map(\.createdAt))
            sortOrders = Set(items.map(\.sortOrder))
            favourites = items.count { $0.isFavorite }
            // Every link that is not the migration's own output.
            otherLinkCount = items.flatMap(\.outgoingLinks).count { $0.kind != .filedUnder }
        }
    }

    private func fetchAll(_ context: ModelContext) throws -> [Item] {
        try context.fetch(FetchDescriptor<Item>(sortBy: [SortDescriptor(\.title)]))
    }

    // MARK: - M1, M2: every fixture converts, and to the right thing

    @Test("Every fixture migrates, and every conversion lands on the right container", arguments: Fixture.allCases)
    func everyFixtureConverts(fixture: Fixture) throws {
        let stack = try PersistenceStack.inMemory()
        let context = ModelContext(stack.container)
        try fixture.build(in: context)

        // What the parents were, before.
        let before = try fetchAll(context)
        let expectedFilings = Dictionary(
            uniqueKeysWithValues: before.compactMap { item -> (UUID, UUID)? in
                guard let parent = item.parent,
                      !parent.kind.canContain(item.kind),
                      parent.kind.isWorkBreakdownContainer
                else { return nil }
                return (item.id, parent.id)
            }
        )

        let report = try ContainmentRepair.apply(in: context)
        #expect(report.conversions.count == expectedFilings.count)

        // M2: each converted parent became a filing to the *same* container.
        for (itemID, containerID) in expectedFilings {
            let item = try #require(try fetchAll(context).first { $0.id == itemID })
            #expect(item.parent == nil, "The illegal parent should be gone")
            #expect(
                item.filedUnderContainers().map(\.id) == [containerID],
                "“\(item.title)” should be filed under the container it used to sit in"
            )
        }
    }

    // MARK: - M3: nothing is lost

    @Test("Nothing but the intended change occurs", arguments: Fixture.allCases)
    func nothingElseChanges(fixture: Fixture) throws {
        let stack = try PersistenceStack.inMemory()
        let context = ModelContext(stack.container)
        try fixture.build(in: context)

        let before = GraphFingerprint(try fetchAll(context))
        let countBefore = try fetchAll(context).count

        try ContainmentRepair.apply(in: context)

        let after = GraphFingerprint(try fetchAll(context))

        #expect(try fetchAll(context).count == countBefore, "No item was created or destroyed")
        #expect(after.titles == before.titles)
        #expect(after.bodies == before.bodies, "Body text is untouched")
        #expect(after.tagSlugs == before.tagSlugs, "Tags are untouched")
        #expect(after.createdAt == before.createdAt, "Timestamps are untouched")
        #expect(after.sortOrders == before.sortOrders, "Ordering is untouched")
        #expect(after.favourites == before.favourites, "Flags are untouched")
        #expect(after.otherLinkCount == before.otherLinkCount, "Existing links are untouched")
    }

    @Test("Legal containment is left exactly as it was")
    func legalContainmentSurvives() throws {
        let stack = try PersistenceStack.inMemory()
        let context = ModelContext(stack.container)
        try Fixture.alreadyValid.build(in: context)

        let report = try ContainmentRepair.apply(in: context)

        #expect(report.conversions.isEmpty)
        #expect(report.alreadyValid == 3)

        let items = try fetchAll(context)
        let heading = try #require(items.first { $0.kind == .heading })
        let task = try #require(items.first { $0.kind == .task })

        #expect(heading.parent?.kind == .project)
        #expect(task.parent?.id == heading.id)
    }

    // MARK: - M6: the report

    @Test("A report names what was converted and what could not be", arguments: Fixture.allCases)
    func reportIsComplete(fixture: Fixture) throws {
        let stack = try PersistenceStack.inMemory()
        let context = ModelContext(stack.container)
        let expectedCount = try fixture.build(in: context)

        let report = try ContainmentRepair.apply(in: context)

        #expect(report.itemsExamined == expectedCount)
        #expect(report.conversions.count + report.unresolved.count + report.alreadyValid == expectedCount)
        #expect(!report.summary.isEmpty)

        for conversion in report.conversions {
            #expect(!conversion.itemTitle.isEmpty)
            #expect(!conversion.containerTitle.isEmpty)
        }
    }

    @Test("An association that cannot become a filing is reported, not invented")
    func unresolvableAssociationsAreReported() throws {
        let stack = try PersistenceStack.inMemory()
        let context = ModelContext(stack.container)
        try Fixture.containerThatCannotHoldFilings.build(in: context)

        let report = try ContainmentRepair.apply(in: context)

        #expect(report.conversions.isEmpty)
        #expect(report.unresolved.count == 1)
        #expect(report.unresolved.first?.reason.contains("daily entry") == true)

        // The item survives and is editable — an illegal parent would have failed validation forever.
        let note = try #require(try fetchAll(context).first { $0.kind == .note })
        #expect(note.parent == nil)
        #expect(ItemValidator.isValid(note))
    }

    // MARK: - M8: dry run

    @Test("A dry run writes nothing", arguments: Fixture.allCases)
    func dryRunWritesNothing(fixture: Fixture) throws {
        let stack = try PersistenceStack.inMemory()
        let context = ModelContext(stack.container)
        try fixture.build(in: context)

        let before = GraphFingerprint(try fetchAll(context))
        let parentsBefore = try fetchAll(context).compactMap { $0.parent?.id }

        let plan = try ContainmentRepair.plan(in: context)
        #expect(plan.isDryRun)

        let after = GraphFingerprint(try fetchAll(context))
        let parentsAfter = try fetchAll(context).compactMap { $0.parent?.id }

        #expect(after == before)
        #expect(parentsAfter == parentsBefore, "Every parent is still where it was")
        #expect(try fetchAll(context).allSatisfy { $0.filedUnderContainers().isEmpty })
    }

    @Test("A dry run predicts exactly what the real run does", arguments: Fixture.allCases)
    func dryRunMatchesReality(fixture: Fixture) throws {
        let stack = try PersistenceStack.inMemory()
        let context = ModelContext(stack.container)
        try fixture.build(in: context)

        let predicted = try ContainmentRepair.plan(in: context)
        let actual = try ContainmentRepair.apply(in: context)

        #expect(predicted.conversions.count == actual.conversions.count)
        #expect(predicted.unresolved.count == actual.unresolved.count)
        #expect(Set(predicted.conversions.map(\.itemID)) == Set(actual.conversions.map(\.itemID)))
    }

    // MARK: - A2-6: idempotence

    @Test("Running it twice changes nothing the second time", arguments: Fixture.allCases)
    func migrationIsIdempotent(fixture: Fixture) throws {
        let stack = try PersistenceStack.inMemory()
        let context = ModelContext(stack.container)
        try fixture.build(in: context)

        let first = try ContainmentRepair.apply(in: context)
        let fingerprintAfterFirst = GraphFingerprint(try fetchAll(context))
        let filingsAfterFirst = try fetchAll(context).flatMap { $0.filedUnderContainers().map(\.id) }

        let second = try ContainmentRepair.apply(in: context)

        #expect(second.conversions.isEmpty, "The second run has nothing to do")
        #expect(GraphFingerprint(try fetchAll(context)) == fingerprintAfterFirst)

        let filingsAfterSecond = try fetchAll(context).flatMap { $0.filedUnderContainers().map(\.id) }
        #expect(filingsAfterSecond.count == filingsAfterFirst.count, "No duplicate filings")
        #expect(first.conversions.count >= second.conversions.count)
    }
}
