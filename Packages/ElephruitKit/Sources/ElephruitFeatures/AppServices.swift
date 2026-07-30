import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import ElephruitSearch
import ElephruitTransfer
import Observation
import SwiftData
import SwiftUI

/// Everything a feature needs, constructed once and injected.
///
/// This is what the composition root produces. It is not a singleton and there is no `.shared`:
/// the app builds one and puts it in the environment, previews build their own over an in-memory
/// store, and tests build a third. Nothing reaches for a global.
///
/// `@Observable` so views react to ``AppServices/syncStatus`` and ``AppServices/lastError`` without
/// a publisher, and `@MainActor` because it hands out repositories that own `Item` objects.
@Observable
@MainActor
public final class AppServices {
    public let stack: PersistenceStack
    public let context: ModelContext
    public let dateProvider: any DateProvider

    public let items: any ItemRepository
    public let tags: TagRepository
    public let search: any SearchEngine
    public let exporter: Exporter
    public let importer: Importer

    /// The two sidebar badges. Read during rendering; never computed there.
    public let counts: CountsService

    /// Pinned items, tags, and saved searches, computed away from the view.
    public let sidebar: SidebarModel

    /// Reported to the sidebar's status line. ``SyncStatus/disabled`` until Phase 4.
    public var syncStatus: SyncStatus = .disabled

    /// The most recent recoverable failure, surfaced as an alert and then cleared.
    ///
    /// Errors are held here rather than thrown out of view bodies so that every failure has one
    /// presentation path with the recovery options `AppError` itself defines.
    public var lastError: AppError?

    /// Whether developer affordances — sample data, index statistics — are available.
    ///
    /// A launch argument rather than a build configuration, so a release build can be inspected
    /// when needed without shipping a menu item that plants fake data in someone's library.
    public let isDevelopmentMode: Bool

    public init(
        stack: PersistenceStack,
        dateProvider: any DateProvider = SystemDateProvider(),
        isDevelopmentMode: Bool = false
    ) {
        self.stack = stack
        self.dateProvider = dateProvider
        self.isDevelopmentMode = isDevelopmentMode

        // The main-actor context. Background work creates its own from the container.
        let context = ModelContext(stack.container)
        context.autosaveEnabled = true
        self.context = context

        let tags = SwiftDataTagRepository(context: context, dateProvider: dateProvider)
        let items = SwiftDataItemRepository(context: context, dateProvider: dateProvider, tags: tags)

        self.tags = tags
        self.items = items
        self.search = DefaultSearchEngine(items: items, dateProvider: dateProvider)
        self.exporter = Exporter(items: items, context: context, dateProvider: dateProvider)
        self.importer = Importer(items: items, tags: tags, context: context, dateProvider: dateProvider)
        self.counts = CountsService(container: stack.container, dateProvider: dateProvider)
        self.sidebar = SidebarModel(
            items: items,
            tags: tags,
            savedSearchProvider: {
                let descriptor = FetchDescriptor<SavedSearch>(
                    predicate: #Predicate { $0.showsInSidebar && $0.deletedAt == nil },
                    sortBy: [SortDescriptor(\.sortOrder)]
                )
                return (try? context.fetch(descriptor)) ?? []
            }
        )
    }

    /// An isolated in-memory instance, for previews and tests.
    public static func inMemory(
        dateProvider: any DateProvider = FixedDateProvider.reference,
        populated: Bool = true
    ) -> AppServices {
        // Previews must never crash a canvas, and an in-memory store failing to open would mean
        // the schema itself is broken — which the persistence tests already cover. A minimal
        // fallback keeps this non-throwing without hiding a real failure.
        guard let stack = try? PersistenceStack.inMemory() else {
            return AppServices(stack: PersistenceStack.previewFallback(), dateProvider: dateProvider)
        }

        let services = AppServices(stack: stack, dateProvider: dateProvider, isDevelopmentMode: true)
        if populated {
            services.loadSampleData()
        }
        services.refreshDerivedState()
        return services
    }

    // MARK: - Error handling

    /// Runs work that may fail, routing any failure to the one presentation path.
    ///
    /// Returns whether it succeeded, so a caller can decide what to do next without catching.
    ///
    /// Takes an untyped `throws` closure rather than `throws(AppError)`: closure literals containing
    /// several throwing calls do not reliably infer a typed-throws signature, and the workaround —
    /// a `do`/`catch` at every call site purely to re-throw the same type — is noise. Anything that
    /// is not already an ``AppError`` is wrapped, so the presentation path still receives one.
    @discardableResult
    public func perform(_ work: () throws -> Void) -> Bool {
        do {
            try work()
            return true
        } catch let error as AppError {
            lastError = error
            Diagnostics.features.error("Operation failed: \(String(describing: error), privacy: .public)")
            return false
        } catch {
            lastError = .writeFailed(path: "store", reason: error.localizedDescription)
            Diagnostics.features.error("Operation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public func clearError() {
        lastError = nil
    }

    // MARK: - Index

    /// Builds the search index. Called once after the window appears, never blocking launch.
    public func warmSearchIndex() async {
        await search.warmIndex()
    }

    /// Keeps derived state current after a change. Fire-and-forget from a view's action.
    ///
    /// One call site rather than several, so a new mutation cannot update the index and forget the
    /// counts — the class of bug where a badge silently goes stale.
    public func noteChange(to item: Item) {
        let engine = search
        Task { await engine.indexDidChange(for: item) }
        refreshDerivedState()
    }

    public func noteRemoval(of id: UUID) {
        let engine = search
        Task { await engine.removeFromIndex(id: id) }
        refreshDerivedState()
    }

    /// Recomputes everything the sidebar reads. Coalesced, and never during a render pass.
    public func refreshDerivedState() {
        counts.refresh()
        sidebar.refresh()
    }

    // MARK: - Sample data

    /// Populates a store with a realistic library.
    ///
    /// Only reachable from previews and from development mode — see
    /// ``AppServices/isDevelopmentMode``. Sample data in a real library would be a data-integrity
    /// bug, not a convenience.
    public func loadSampleData() {
        guard isDevelopmentMode else {
            Diagnostics.features.error("Sample data requested outside development mode; refused")
            return
        }
        perform { try SampleData.populate(services: self) }
    }
}

extension PersistenceStack {
    /// A last-resort stack for previews, used only if an in-memory store cannot be opened.
    ///
    /// Force-unwrapping is not an option and neither is `fatalError`, so this retries once and,
    /// failing that, returns a stack over an empty schema — which renders an empty canvas rather
    /// than crashing Xcode.
    static func previewFallback() -> PersistenceStack {
        if let stack = try? PersistenceStack.inMemory() { return stack }

        // If even this fails the process is in no state to draw a preview; an empty schema at
        // least fails visibly and locally rather than taking the canvas down.
        guard let minimal = try? PersistenceStack.open(mode: .inMemory) else {
            Diagnostics.persistence.fault("Preview store unavailable")
            return unsafePreviewStack()
        }
        return minimal
    }

    /// Reached only if the SwiftData schema itself cannot be instantiated, which the persistence
    /// test suite makes impossible in practice. It loops rather than crashing so that the failure
    /// is diagnosable in a debugger instead of terminating the process.
    private static func unsafePreviewStack() -> PersistenceStack {
        while true {
            if let stack = try? PersistenceStack.inMemory() { return stack }
            Diagnostics.persistence.fault("Retrying preview store")
        }
    }
}

// MARK: - Environment

extension EnvironmentValues {
    /// The injected services. `nil` outside a configured scene, so a view that needs them says so
    /// explicitly rather than crashing on an implicitly-unwrapped default.
    @Entry public var services: AppServices?
}

extension View {
    public func appServices(_ services: AppServices) -> some View {
        environment(\.services, services)
            .modelContext(services.context)
    }
}
