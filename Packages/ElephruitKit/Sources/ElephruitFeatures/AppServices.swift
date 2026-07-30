import ElephruitCore
import ElephruitIntegrations
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

    /// Capture, callable without a view — see ``CaptureService``.
    public let capture: CaptureService

    /// Tracked time.
    public let timeEntries: any TimeEntryRepository

    /// The running timer, its heartbeat, and any recovery awaiting an answer.
    public let timer: TimerService

    /// The user's calendar, read-only and off until they turn it on.
    public let calendar: CalendarService

    /// People, computed from the links that already exist.
    public let people: PeopleService

    /// Files attached to items — copied in, or referenced where they already live.
    public let attachments: AttachmentStore

    /// Keyboard shortcuts — the one place a binding is decided.
    ///
    /// Held here rather than read from `UserDefaults` at each lookup, so rebuilding a menu is not an
    /// I/O operation and so a test can hand in a registry without touching the user's preferences.
    public var shortcuts: ShortcutRegistry {
        didSet { shortcuts.save(to: .standard) }
    }

    /// Whether Home offers follow-up suggestions.
    ///
    /// **Off by default.** An app that starts telling you who you have neglected, unprompted, is a
    /// different and worse product than one that answers when asked.
    public var showsFollowUpSuggestions: Bool {
        get { UserDefaults.standard.bool(forKey: "people.showsFollowUps") }
        set { UserDefaults.standard.set(newValue, forKey: "people.showsFollowUps") }
    }

    /// How long a gap has to be before it is mentioned.
    public var followUpThresholdDays: Int {
        let stored = UserDefaults.standard.integer(forKey: "people.followUpThresholdDays")
        return stored > 0 ? stored : FollowUpPolicy.defaultThresholdDays
    }

    /// What a containment repair would do, if one is needed.
    ///
    /// Computed by a dry run once the store is open. `nil` means there is nothing to convert — the
    /// ordinary case for a library created after the change.
    ///
    /// The repair is *offered*, never performed on launch: it is exactly the kind of consequential,
    /// irreversible-by-hand decision the app does not make on the user's behalf.
    public private(set) var pendingContainmentRepair: MigrationReport?

    /// The outcome of the last repair the user applied, shown once and then cleared.
    public var lastContainmentRepair: MigrationReport?

    /// Structural undo — move, delete, retag, status, archive.
    ///
    /// One per `AppServices`, sharing the window's `UndoManager`, so `⌘Z` reverses the last
    /// structural change the same way it reverses typing. The text editor keeps its own manager, and
    /// which one responds is decided by focus — standard AppKit behaviour.
    public let undo: StructuralUndoCoordinator

    /// The undo manager the shell installs on its window.
    public let undoManager: UndoManager

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
        self.shortcuts = ShortcutRegistry.load(from: .standard)

        // The main-actor context. Background work creates its own from the container.
        let context = ModelContext(stack.container)
        context.autosaveEnabled = true
        self.context = context

        let tags = SwiftDataTagRepository(context: context, dateProvider: dateProvider)
        let items = SwiftDataItemRepository(context: context, dateProvider: dateProvider, tags: tags)

        self.tags = tags
        self.items = items
        // An in-memory stack has no location — previews and tests — so the index gets a throwaway
        // file. It is derived either way; the only thing that changes is where it is thrown away.
        let indexURL = stack.location?.searchIndexURL
            ?? URL.temporaryDirectory.appending(path: "ElephruitIndex-\(UUID().uuidString).sqlite")

        self.search = FTSSearchEngine(
            items: items,
            indexURL: indexURL,
            dateProvider: dateProvider,
            container: stack.container
        )
        // The location, so an export can carry attachment bytes out and an import can bring them
        // back. Without it both still handle every record and simply have no files to move.
        self.exporter = Exporter(
            items: items,
            context: context,
            dateProvider: dateProvider,
            location: stack.location
        )
        self.importer = Importer(
            items: items,
            tags: tags,
            context: context,
            dateProvider: dateProvider,
            location: stack.location
        )
        self.counts = CountsService(container: stack.container, dateProvider: dateProvider)
        self.capture = CaptureService(items: items, context: context, dateProvider: dateProvider)

        let timeEntries = SwiftDataTimeEntryRepository(
            context: context,
            dateProvider: dateProvider,
            tags: tags
        )
        self.timeEntries = timeEntries
        self.timer = TimerService(entries: timeEntries, dateProvider: dateProvider)

        // The provider is built lazily, and only when the feature is enabled — so an app that never
        // turns the calendar on never constructs an `EKEventStore` and never prompts.
        self.calendar = CalendarService(dateProvider: dateProvider) { EventKitCalendarProvider() }
        self.people = PeopleService(items: items, dateProvider: dateProvider)
        self.attachments = AttachmentStore(
            context: context,
            location: stack.location,
            dateProvider: dateProvider
        )

        let undoManager = UndoManager()
        // Off, so one operation is one undo step regardless of run-loop timing. Every coordinator
        // method opens its own group.
        undoManager.groupsByEvent = false
        self.undoManager = undoManager
        self.undo = StructuralUndoCoordinator(items: items, undoManager: undoManager)
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

    /// Captures a line of text **and** keeps derived state current.
    ///
    /// The whole of a capture, from any entry point. ``CaptureService`` writes the item; this adds
    /// the half that makes it findable.
    ///
    /// ### Why this exists rather than two calls at each site
    /// `noteChange` is opt-in, and ``CaptureIntent`` did not opt in — so an item captured from
    /// Spotlight or Shortcuts was written to the store and was then unreachable by search, silently,
    /// for a whole phase. A capture is not finished when the row exists; it is finished when the
    /// index knows. Making that one call rather than two removes the opportunity to do half of it.
    ///
    /// This is a step toward the action layer in ADR 0007, not the whole of it: the same argument
    /// applies to every mutation, and the remaining call sites are converted in that slice.
    @discardableResult
    public func captureText(_ text: String) throws(AppError) -> Item? {
        guard let item = try capture.capture(text: text) else { return nil }
        noteChange(to: item)
        return item
    }

    public func noteRemoval(of id: UUID) {
        let engine = search
        Task { await engine.removeFromIndex(id: id) }
        refreshDerivedState()
    }

    // MARK: - Containment repair

    /// Works out whether any parent relationship needs converting to a filing.
    ///
    /// A dry run: it writes nothing, and its report is what the user is shown before deciding.
    public func checkForContainmentRepair() {
        do {
            let report = try ContainmentRepair.plan(in: context)
            pendingContainmentRepair = report.hasWork || !report.unresolved.isEmpty ? report : nil

            if let pending = pendingContainmentRepair {
                Diagnostics.persistence.info(
                    "Containment repair available: \(pending.conversions.count, privacy: .public) to convert"
                )
            }
        } catch {
            Diagnostics.persistence.error(
                "Could not plan containment repair: \(error.localizedDescription, privacy: .public)"
            )
            pendingContainmentRepair = nil
        }
    }

    /// Applies the repair the user just approved, backing the store up first.
    ///
    /// The backup happens here rather than inside the repair because it is a property of *this*
    /// being irreversible by hand, not of the operation itself — the fixtures exercise the operation
    /// without needing one.
    @discardableResult
    public func applyContainmentRepair() -> Bool {
        if let location = stack.location {
            PersistenceStack.backupStore(at: location, label: "pre-containment-repair")
            PersistenceStack.pruneBackups(at: location, keeping: 3)
        }

        let succeeded = perform {
            lastContainmentRepair = try ContainmentRepair.apply(in: context)
        }

        if succeeded {
            pendingContainmentRepair = nil
            refreshDerivedState()
        }
        return succeeded
    }

    /// Dismisses the offer for this session without changing anything.
    public func deferContainmentRepair() {
        pendingContainmentRepair = nil
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
