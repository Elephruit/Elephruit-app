import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import Synchronization
import SwiftData

/// A clock that stands still until it is told to move.
///
/// ### Why a frozen clock is not enough for every test
/// `FixedDateProvider` is the right default: it makes "today", overdue arithmetic, and recurrence
/// assertable without depending on the machine. But `ItemRepository.update` stamps `updatedAt` from
/// the injected clock, so under a frozen one **no edit ever changes an item's modification date** —
/// and anything that detects a local edit by comparing that stamp cannot be tested at all. The
/// reminder sync is exactly that: it decides whether to push by asking whether the task has moved
/// since the last reconciliation.
///
/// So this ticks on demand. `advance()` between edits is what a real keyboard does for free.
final class TickingDateProvider: DateProvider, Sendable {
    private let instant: Mutex<Date>
    let calendar: Calendar

    init(start: FixedDateProvider = .reference) {
        self.instant = Mutex(start.now)
        self.calendar = start.calendar
    }

    var now: Date { instant.withLock { $0 } }

    /// Moves the clock forward. A minute by default — long enough to be unambiguous, short enough
    /// not to cross a day boundary in a test that did not ask to.
    func advance(by interval: TimeInterval = 60) {
        instant.withLock { $0 += interval }
    }
}

/// An isolated in-memory store for one test.
///
/// Every test gets its own container, so tests cannot see each other's data and can run in
/// parallel. `@MainActor` because it hands out repositories, which are main-actor isolated
/// for the reason given in ``ItemRepository``.
@MainActor
struct StoreFixture {
    let stack: PersistenceStack
    let context: ModelContext
    let items: SwiftDataItemRepository
    let tags: SwiftDataTagRepository

    /// `any DateProvider` rather than the concrete frozen one, so a test that needs the clock to
    /// move can hand in a ``TickingDateProvider``. Everything the fixtures use — `now`, `calendar`,
    /// `startOfToday`, `startOfDay(daysFromToday:)` — comes from the protocol.
    let dateProvider: any DateProvider

    init(dateProvider: any DateProvider = FixedDateProvider.reference, audit: FetchAudit? = nil) throws {
        self.stack = try PersistenceStack.inMemory()
        self.context = ModelContext(stack.container)
        self.dateProvider = dateProvider
        self.tags = SwiftDataTagRepository(context: context, dateProvider: dateProvider)
        self.items = SwiftDataItemRepository(
            context: context,
            dateProvider: dateProvider,
            tags: tags,
            audit: audit
        )
    }

    /// A second context over the same container, for asserting that data survives a
    /// round trip through the store rather than being read back out of the first
    /// context's in-memory graph.
    func freshContext() -> ModelContext {
        ModelContext(stack.container)
    }

    /// Forces pending changes to the store, then reads the item back through a new context.
    ///
    /// This is the assertion that matters for relationship correctness: an object graph can
    /// look right in the context that built it and still be wrong on disk.
    func refetch(id: UUID) throws -> Item? {
        try context.save()
        var descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try freshContext().fetch(descriptor).first
    }

    /// Looks the item up in the fixture's *own* context.
    ///
    /// Use this whenever the result will be mutated or related to another object. Relating two models
    /// that came from different contexts traps inside SwiftData, so `requireItem(id:)` — which reads
    /// through a fresh context — is for assertions only.
    func sameContextItem(id: UUID) throws -> Item {
        guard let item = try items.item(id: id) else { throw AppError.itemNotFound(id: id) }
        return item
    }

    /// ``StoreFixture/refetch(id:)``, failing the test if the item is absent.
    ///
    /// A throwing helper rather than `try #require(try …)` at every call site: nesting a
    /// throwing expression inside the `#require` macro is awkward to write correctly, and
    /// this reads better besides.
    func requireItem(id: UUID) throws -> Item {
        guard let item = try refetch(id: id) else {
            throw AppError.itemNotFound(id: id)
        }
        return item
    }

    @discardableResult
    func makeNote(title: String, body: String = "", tags tagNames: [String] = []) throws -> Item {
        try items.create(ItemDraft(kind: .note, title: title, body: body, tagSlugs: tagNames))
    }

    @discardableResult
    func makeTask(
        title: String,
        dueAt: Date? = nil,
        parentID: UUID? = nil,
        priority: Priority = .normal
    ) throws -> Item {
        try items.create(
            ItemDraft(kind: .task, title: title, parentID: parentID, dueAt: dueAt, priority: priority)
        )
    }

    @discardableResult
    func makeProject(title: String, parentID: UUID? = nil) throws -> Item {
        try items.create(ItemDraft(kind: .project, title: title, parentID: parentID))
    }

    @discardableResult
    func makeArea(title: String) throws -> Item {
        try items.create(ItemDraft(kind: .area, title: title))
    }
}
