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

    /// Browser captures, after the app-group inbox hands them to the app.
    public let webClips: WebClipService

    /// Tracked time.
    public let timeEntries: any TimeEntryRepository

    /// The running timer, its heartbeat, and any recovery awaiting an answer.
    public let timer: TimerService

    /// Tracked time written out to a calendar. Off, and outbound only — see ``TimeCalendarMirror``.
    public let timeMirror: TimeCalendarMirror

    /// The platform shell's long-lived companions — the mini timer panel, the quick-log
    /// panel — created on first use and then held for the life of the app.
    ///
    /// A registry rather than named properties, because the types are platform-specific: the
    /// macOS target declares `MiniTimerController` and `QuickLogController` and reaches them
    /// through ``accessory(_:make:)``, and this shared class never has to know either name.
    /// One instance per type, on the same argument the old lazy properties made: collapsing
    /// to a clock is a statement about the *application*, and two windows racing to hide each
    /// other would be two mini timers and no way back.
    @ObservationIgnored
    private var accessories: [ObjectIdentifier: AnyObject] = [:]

    /// The one instance of a platform accessory, created on first use.
    ///
    /// `@ObservationIgnored` storage, on the same terms as the lazy properties this replaces:
    /// the reference never changes, so there is nothing to observe about it — what views watch
    /// is the accessory's own observable state.
    public func accessory<A: AnyObject>(_ type: A.Type, make: () -> A) -> A {
        if let held = accessories[ObjectIdentifier(type)] as? A { return held }
        let made = make()
        accessories[ObjectIdentifier(type)] = made
        return made
    }

    /// One date's worth of everything, assembled from the records that already exist.
    ///
    /// Built lazily and held here rather than per window, on the same terms as ``miniTimer``: two
    /// windows looking at Today are asking the same library the same question, and the per-assembly
    /// caches inside it are worth sharing. `@ObservationIgnored` because the reference never changes
    /// and there is nothing to observe about it — what a page watches is ``changeToken``.
    @ObservationIgnored
    public private(set) lazy var dailyPlan = DailyPlanService(services: self)

    /// What the reader has chosen to see on Today, remembered between launches.
    @ObservationIgnored
    public private(set) lazy var todayPreferences = TodayPreferences(defaults: defaults)

    /// Where this machine's preferences live.
    ///
    /// Held rather than reached for, so a preview or a test can hand over a throwaway suite and not
    /// have a focus-cycle length leak into the real one. Public so the platform shells can hand
    /// the same suite to their accessories — see ``accessory(_:make:)``.
    public let defaults: UserDefaults

    /// The user's calendar: what it holds, which sets are saved, and every write.
    ///
    /// Off until the user turns it on, on the same terms as Contacts.
    public let calendar: CalendarService
    public let calendarSearch: any CalendarSearching
    public let calendarSets: CalendarSetService
    public let eventTemplates: EventTemplateService
    public let eventLinks: EventAnnotationService

    // MARK: The Reminders module

    /// Every way a reminder or project work record can change.
    public let reminderLifecycle: ReminderLifecycleService

    /// The container tree used by the Areas sidebar.
    public let containerSidebar: ContainerSidebarModel

    /// The Reminders module's direct view of first-class items.
    public let reminderStore: ReminderStore

    // MARK: Projects

    /// A project's columns, views and custom fields.
    public let projectWorkspace: ProjectWorkspaceService

    /// Creating and changing work, and writing down that it changed.
    public let workItems: WorkItemService

    /// Everything specific to defects.
    public let bugs: BugService

    /// Turning a template into a real project.
    public let projectTemplates: ProjectTemplateService

    /// A project's own rules.
    public let automations: AutomationEngine

    /// The figures a project is judged by.
    public let projectReports: ProjectReportingService

    /// What the user is told, and how often.
    public let inbox: InboxService

    /// The Projects tree at the top of the sidebar.
    public let projectSidebar: ProjectsSidebarModel

    /// Apple Reminders, off until the user turns it on.
    public let reminders: RemindersService

    /// Keeping linked tasks and system reminders in step, and saying so when it cannot.
    public let reminderSync: ReminderSyncEngine

    /// People, computed from the links that already exist.
    public let people: PeopleService

    /// People and real-world things presented through one reusable workspace.
    public let records: RecordsService

    // MARK: Human record services

    /// People, their facts, their relationships, and their celebrations.
    public let persons: any PersonRepository

    /// One traversal behind the portrait, the timeline, the charts, and the brief.
    public let personWorkspace: PersonWorkspaceService

    /// Duplicate detection and merging.
    public let personIdentity: PersonIdentityService

    /// Searching people by more than their name.
    public let personSearch: PersonSearchService

    /// Groups, and what can be done to all of one at once.
    public let personGroups: PersonGroupService

    /// Reads the command bar. A protocol, so an AI-backed parser is a second conformance rather than
    /// a rewrite — see ``ElephruitCore/PersonCommandParsing``.
    public let commandParser: any PersonCommandParsing

    /// The system address book, read-only and off until the user turns it on.
    public let contacts: ContactsService

    /// Turning the address book into the CRM's starting population.
    public let contactImports: ContactImportService

    /// Keeping linked contact details current, and saying so when it cannot.
    public let contactSync: ContactSyncService

    /// Reads text off a scanned card. Inert until the scan flow is used.
    public let textRecognizer: any TextRecognizing

    /// Named subsets of the user's own details, for handing out.
    ///
    /// In `UserDefaults` rather than the store because they are a preference about *this machine's*
    /// sharing behaviour, carry no relationship data, and must not travel in an archive that somebody
    /// might send to a colleague.
    public var shareProfiles: [ShareProfile] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "people.shareProfiles"),
                  let decoded = try? JSONDecoder().decode([ShareProfile].self, from: data),
                  !decoded.isEmpty
            else { return ShareProfile.defaults() }
            return decoded
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "people.shareProfiles")
        }
    }

    /// People opened recently, newest first. Session-scoped, like the search history and for the
    /// same reason: a list of who you looked at that outlives the session is a privacy liability
    /// nobody asked for.
    public private(set) var recentlyViewedPeople: [UUID] = []

    public func noteViewed(person: Item) {
        guard recentlyViewedPeople.first != person.id else { return }
        recentlyViewedPeople.removeAll { $0 == person.id }
        recentlyViewedPeople.insert(person.id, at: 0)
        if recentlyViewedPeople.count > 12 {
            recentlyViewedPeople.removeLast(recentlyViewedPeople.count - 12)
        }
    }

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

    /// What a sweep of the attachment folder would tidy, if anything.
    ///
    /// A dry run, computed once the store is open. Offered rather than performed: ADR 0003's
    /// integrity pass exists to *report* orphans in both directions, and deciding to move someone's
    /// files is not a decision to make on launch without saying so.
    public private(set) var pendingAttachmentTidy: AttachmentReconciliationReport?

    /// The outcome of the last repair the user applied, shown once and then cleared.
    public var lastContainmentRepair: MigrationReport?

    /// Structural undo — move, delete, retag, status, archive.
    ///
    /// One per `AppServices`. The shell hands it the focused window's `UndoManager` through
    /// ``StructuralUndoCoordinator/adopt(_:)`` — see `RootView` — so `⌘Z` reverses the last
    /// structural change the same way it reverses typing, on the history of the window it was
    /// made in.
    public let undo: StructuralUndoCoordinator

    /// The standalone fallback manager, and the one tests drive directly.
    ///
    /// Registrations land here only until a window adopts its own — in the running app this
    /// carries nothing once the first window is up.
    public let undoManager: UndoManager

    /// Pinned items, tags, and saved searches, computed away from the view.
    public let sidebar: SidebarModel

    /// Bumped once for every item written or removed through ``noteChange(to:)`` and
    /// ``noteRemoval(of:)``.
    ///
    /// ### Why a counter rather than watching the thing on screen
    /// A page assembled from *links* cannot notice a change by watching its own subject. Adding a
    /// task about somebody writes the task and an `ItemLink`; it does not touch the person's row,
    /// so their `updatedAt` never moves and a view watching it concludes nothing happened. The
    /// task was in the Inbox and in the search index immediately, and absent from the person's page
    /// until the view was rebuilt by navigating away and back — which reads as the app having
    /// dropped it.
    ///
    /// Deliberately opaque and deliberately coarse. It says *something in the library changed*,
    /// which is all a page needs in order to re-ask its own question; a change *description* would
    /// invite views to guess whether a given write could possibly affect them, and that guess is
    /// exactly what was wrong here. Reassembling a person's page is one traversal of links already
    /// in memory.
    ///
    /// ``refreshDerivedState()`` does **not** bump it: it is called to recompute badges after a
    /// change already announced, and bumping there would turn one write into two rounds of reloads.
    public private(set) var changeToken = 0

    /// Reported to the sidebar's status line. Truth lives on the monitor; this is the read.
    public var syncStatus: SyncStatus { syncMonitor.status }

    /// Watches the mirroring machinery. Constructed disabled when the store is local-only,
    /// so the status line never claims what the container is not doing.
    public let syncMonitor: SyncMonitor

    /// The most recent recoverable failure, surfaced as an alert and then cleared.
    ///
    /// Errors are held here rather than thrown out of view bodies so that every failure has one
    /// presentation path with the recovery options `AppError` itself defines.
    public var lastError: AppError?

    /// Counts store access while a measurement is running. `nil` outside a test.
    public let fetchAudit: FetchAudit?

    /// Whether developer affordances — sample data, index statistics — are available.
    ///
    /// A launch argument rather than a build configuration, so a release build can be inspected
    /// when needed without shipping a menu item that plants fake data in someone's library.
    public let isDevelopmentMode: Bool

    /// - Parameters:
    ///   - contactsProvider: How to build the address-book adapter. Defaults to the real one, built
    ///     lazily and only once the user turns the integration on. A test passes a
    ///     ``ElephruitIntegrations/FixtureContactsProvider`` here, which is what lets the whole
    ///     import flow be exercised without `CNContactStore` ever being constructed.
    ///   - calendarProvider: How to build the calendar adapter, on the same terms. A test — or a
    ///     reviewer in development mode — passes a
    ///     ``ElephruitIntegrations/FixtureCalendarProvider`` here, which is what lets the whole
    ///     module be exercised without `EKEventStore` ever being constructed or anybody's real
    ///     calendar being written to.
    ///   - remindersProvider: How to build the Reminders adapter, on the same terms. A test passes
    ///     a ``ElephruitIntegrations/FixtureRemindersProvider``, which is what lets the whole sync
    ///     flow be exercised without `EKEventStore` ever being constructed.
    ///   - textRecognizer: On-device image text recognition. Tests can provide a deterministic
    ///     recognizer; the app uses Vision by default.
    ///   - defaults: Where per-device preferences live. A test passes a scratch suite so that
    ///     enabling Contacts in one does not leave the flag set for the user or for the next test.
    ///   - audit: Counts store access, so "this page does not traverse the library once per day it
    ///     draws" can be asserted rather than hoped for. `nil` everywhere but in a test, where it
    ///     costs one optional check per fetch — see ``ElephruitPersistence/FetchAudit``.
    public init(
        stack: PersistenceStack,
        dateProvider: any DateProvider = SystemDateProvider(),
        isDevelopmentMode: Bool = false,
        contactsProvider: (@Sendable () -> any ContactsProviding)? = nil,
        calendarProvider: (@Sendable () -> any CalendarProviding)? = nil,
        remindersProvider: (@Sendable () -> any RemindersProviding)? = nil,
        textRecognizer: (any TextRecognizing)? = nil,
        defaults: UserDefaults = .standard,
        audit: FetchAudit? = nil
    ) {
        self.fetchAudit = audit
        self.stack = stack
        self.dateProvider = dateProvider
        self.isDevelopmentMode = isDevelopmentMode
        self.defaults = defaults
        self.shortcuts = ShortcutRegistry.load(from: .standard)
        self.syncMonitor = SyncMonitor(enabled: stack.isSyncEnabled)

        // The main-actor context. Background work creates its own from the container.
        let context = ModelContext(stack.container)
        context.autosaveEnabled = true
        self.context = context

        let tags = SwiftDataTagRepository(context: context, dateProvider: dateProvider)
        let items = SwiftDataItemRepository(
            context: context, dateProvider: dateProvider, tags: tags, audit: audit
        )

        self.tags = tags
        self.items = items

        // Promote the former Tasks population into Reminders before any service takes a snapshot of
        // the library. Only the discriminator changes, so every relationship stays attached to the
        // same item. A file-backed library is backed up first; if that backup cannot be written the
        // compatibility read paths keep the legacy rows visible and the rewrite is deferred.
        do {
            let pending = try TaskToReminderMigration.plan(in: context)
            if !pending.isEmpty {
                let canApply: Bool
                if let location = stack.location {
                    let stamp = Int(dateProvider.now.timeIntervalSince1970)
                    canApply = PersistenceStack.backupStore(
                        at: location,
                        label: "pre-reminder-consolidation-\(stamp)"
                    ) != nil
                } else {
                    canApply = true
                }

                if canApply {
                    let migrated = try TaskToReminderMigration.apply(in: context)
                    Diagnostics.persistence.info(
                        "Promoted \(migrated, privacy: .public) legacy tasks into reminders"
                    )
                } else {
                    Diagnostics.persistence.error(
                        "Reminder consolidation deferred because its backup could not be written"
                    )
                }
            }
        } catch {
            Diagnostics.persistence.error(
                "Reminder consolidation failed: \(error.localizedDescription, privacy: .public)"
            )
        }

        // Converge any rows written before the day-relevance projection existed. One real pass on
        // the first launch after the column arrived; an empty fetch on every launch after. Failure
        // is logged and swallowed — the sentinel default means an unconverged row is over-fetched,
        // never hidden, so this can never be worth refusing to open the library over.
        do {
            let converged = try DayRelevanceBackfill.apply(in: context)
            if converged > 0 {
                Diagnostics.persistence.info(
                    "Day-relevance backfill converged \(converged, privacy: .public) rows"
                )
            }
        } catch {
            Diagnostics.persistence.error(
                "Day-relevance backfill failed: \(error.localizedDescription, privacy: .public)"
            )
        }
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

        // Derived, and beside the search index for the same reasons. A stack with no location —
        // previews and tests — gets a throwaway file.
        let calendarIndexURL = stack.location?.calendarIndexURL
            ?? URL.temporaryDirectory.appending(path: "ElephruitCalendarIndex-\(UUID().uuidString).sqlite")
        let calendarSearch = FTSCalendarSearchEngine(indexURL: calendarIndexURL)
        self.calendarSearch = calendarSearch

        let calendarSets = CalendarSetService(
            context: context, dateProvider: dateProvider, defaults: defaults
        )
        self.calendarSets = calendarSets
        self.eventTemplates = EventTemplateService(context: context, dateProvider: dateProvider)

        let eventLinks = EventAnnotationService(context: context, items: items, dateProvider: dateProvider)
        self.eventLinks = eventLinks

        let reminderLifecycle = ReminderLifecycleService(items: items, context: context, dateProvider: dateProvider)
        self.reminderLifecycle = reminderLifecycle
        self.containerSidebar = ContainerSidebarModel(items: items)
        let reminderStore = ReminderStore(
            items: items,
            lifecycle: reminderLifecycle,
            dateProvider: dateProvider
        )
        self.reminderStore = reminderStore

        // The old Reminders workspace wrote a separate JSON file. Bring that population into the
        // same graph after the legacy task rows have been promoted, with both stores copied into a
        // single rollback directory first. A failed backup or import leaves the JSON file in place,
        // so the next launch can retry without losing the source.
        if let location = stack.location {
            do {
                let pending = try LegacyReminderArchiveMigration.plan(
                    at: location.legacyRemindersURL
                )
                if pending > 0 {
                    let stamp = Int(dateProvider.now.timeIntervalSince1970)
                    if let backup = PersistenceStack.backupStore(
                        at: location,
                        label: "pre-reminder-json-import-\(stamp)"
                    ) {
                        try FileManager.default.copyItem(
                            at: location.legacyRemindersURL,
                            to: backup.appending(path: "Reminders.json")
                        )
                        let report = try LegacyReminderArchiveMigration.apply(
                            from: location.legacyRemindersURL,
                            using: reminderStore
                        )
                        Diagnostics.persistence.info(
                            "Imported \(report.imported, privacy: .public) standalone reminders"
                        )
                    } else {
                        Diagnostics.persistence.error(
                            "Standalone reminder import deferred because its backup could not be written"
                        )
                    }
                }
            } catch {
                Diagnostics.persistence.error(
                    "Standalone reminder import failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        // Constructed in dependency order, which is also the order they were designed in: furniture,
        // then work, then the things that read work.
        let projectWorkspace = ProjectWorkspaceService(
            items: items,
            context: context,
            dateProvider: dateProvider
        )
        self.projectWorkspace = projectWorkspace
        let workItems = WorkItemService(
            items: items,
            workspace: projectWorkspace,
            context: context,
            dateProvider: dateProvider
        )
        self.workItems = workItems
        let bugs = BugService(
            items: items,
            workItems: workItems,
            context: context,
            dateProvider: dateProvider
        )
        self.bugs = bugs
        let inbox = InboxService(context: context, dateProvider: dateProvider)
        self.inbox = inbox
        self.projectTemplates = ProjectTemplateService(
            items: items,
            workspace: projectWorkspace,
            workItems: workItems,
            context: context
        )
        self.automations = AutomationEngine(
            items: items,
            workspace: projectWorkspace,
            workItems: workItems,
            bugs: bugs,
            inbox: inbox,
            context: context,
            dateProvider: dateProvider
        )
        self.projectReports = ProjectReportingService(
            workspace: projectWorkspace,
            bugs: bugs,
            dateProvider: dateProvider
        )
        self.projectSidebar = ProjectsSidebarModel(
            items: items,
            inbox: inbox,
            dateProvider: dateProvider
        )

        // Built lazily and only when the feature is enabled, on the same terms as the calendar and
        // the address book — so an app that never links a reminder never constructs an
        // `EKEventStore` and never prompts.
        let reminders = RemindersService(
            dateProvider: dateProvider,
            defaults: defaults,
            makeProvider: remindersProvider ?? { EventKitRemindersProvider() }
        )
        self.reminders = reminders
        // Asked for on every pass, never captured: `reminders.provider` is inert until the user
        // links the integration, and this engine is built before they can have. Passing the value
        // here left the engine driving a `NoRemindersProvider` for the whole of the session in
        // which somebody turned Reminders on.
        self.reminderSync = ReminderSyncEngine(
            items: items,
            lifecycle: reminderLifecycle,
            context: context,
            dateProvider: dateProvider,
            provider: { reminders.provider }
        )

        // The provider is built lazily, and only when the feature is enabled — so an app that never
        // turns the calendar on never constructs an `EKEventStore` and never prompts.
        let calendar = CalendarService(
            dateProvider: dateProvider,
            defaults: defaults,
            index: calendarSearch,
            sets: calendarSets,
            annotations: eventLinks,
            makeProvider: calendarProvider ?? { EventKitCalendarProvider() }
        )
        self.calendar = calendar
        self.timeMirror = TimeCalendarMirror(
            entries: timeEntries,
            calendar: calendar,
            dateProvider: dateProvider,
            defaults: defaults
        )
        self.people = PeopleService(items: items, dateProvider: dateProvider)

        let persons = SwiftDataPersonRepository(context: context, items: items, dateProvider: dateProvider)
        self.persons = persons
        let records = RecordsService(
            context: context, items: items, people: persons, dateProvider: dateProvider
        )
        self.records = records
        self.personWorkspace = PersonWorkspaceService(people: persons, items: items, dateProvider: dateProvider)
        self.personIdentity = PersonIdentityService(
            context: context, people: persons, items: items, dateProvider: dateProvider
        )
        let personSearch = PersonSearchService(people: persons, items: items, dateProvider: dateProvider)
        self.personSearch = personSearch
        self.personGroups = PersonGroupService(
            context: context, items: items, people: persons, search: personSearch, dateProvider: dateProvider
        )
        self.commandParser = DeterministicPersonCommandParser()

        // Built lazily and only when the feature is enabled, on the same terms as the calendar — so
        // an app that never turns Contacts on never constructs a `CNContactStore` and never prompts.
        self.contacts = ContactsService(
            dateProvider: dateProvider,
            defaults: defaults,
            makeProvider: contactsProvider ?? { SystemContactsProvider() }
        )
        self.textRecognizer = textRecognizer ?? VisionTextRecognizer()

        let contactImports = ContactImportService(
            context: context,
            people: persons,
            items: items,
            identity: self.personIdentity,
            records: records,
            dateProvider: dateProvider
        )
        self.contactImports = contactImports
        self.contactSync = ContactSyncService(
            context: context, people: persons, imports: contactImports, dateProvider: dateProvider
        )

        let attachments = AttachmentStore(
            context: context,
            location: stack.location,
            dateProvider: dateProvider
        )
        self.attachments = attachments
        self.webClips = WebClipService(items: items, attachments: attachments)

        let undoManager = UndoManager()
        // Off, so one operation is one undo step regardless of run-loop timing. Every coordinator
        // method opens its own group.
        undoManager.groupsByEvent = false
        self.undoManager = undoManager
        self.undo = StructuralUndoCoordinator(items: items, undoManager: undoManager)
        // Resolving a linked person's or project's name for the calendar index. Set after
        // construction because the calendar needs the repository and the repository needs the
        // context, and a closure is the smallest thing that can cross that.
        self.calendar.titleResolver = { [weak items] id in
            guard let items else { return nil }
            return (try? items.item(id: id))?.displayTitle
        }

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

        // The moment another device's changes land is the moment everything derived from
        // the store is stale — same cue, same pass, no polling.
        syncMonitor.onImportCompleted = { [weak self] in
            self?.absorbRemoteChanges()
        }
    }

    /// Recomputes what a remote import made stale: badges, trees, snapshots, the index.
    ///
    /// The counterpart of a local mutation's announce-and-refresh, for mutations announced
    /// by iCloud instead of a view. Derived date keys that arrive stale from another device
    /// converge on each row's next local save — the fetch over-reads until then, which
    /// costs milliseconds and never work (the `dayRelevanceKey` argument, applied to sync).
    public func absorbRemoteChanges() {
        changeToken &+= 1
        // Before the derived pass, because the timer is the one piece of state a view reads
        // straight from this object rather than from a fetch — and the only one where being a
        // few seconds stale is not a cosmetic problem but a clock counting time nobody is
        // working. See ``TimerService/absorbRemoteChange()``.
        timer.absorbRemoteChange()
        refreshDerivedState()
        Task { await warmSearchIndex() }
    }

    /// An isolated in-memory instance, for previews and tests.
    public static func inMemory(
        dateProvider: any DateProvider = FixedDateProvider.reference,
        populated: Bool = true,
        contactsProvider: (@Sendable () -> any ContactsProviding)? = nil,
        // On the same terms as the other two, and for the same reason: a test that exercises
        // anything reading the calendar — a day's plan, most obviously — must be able to hand over a
        // synthetic one rather than reaching `EKEventStore`.
        calendarProvider: (@Sendable () -> any CalendarProviding)? = nil,
        remindersProvider: (@Sendable () -> any RemindersProviding)? = nil,
        defaults: UserDefaults = .standard,
        audit: FetchAudit? = nil
    ) -> AppServices {
        // Previews must never crash a canvas, and an in-memory store failing to open would mean
        // the schema itself is broken — which the persistence tests already cover. A minimal
        // fallback keeps this non-throwing without hiding a real failure.
        guard let stack = try? PersistenceStack.inMemory() else {
            return AppServices(stack: PersistenceStack.previewFallback(), dateProvider: dateProvider)
        }

        let services = AppServices(
            stack: stack,
            dateProvider: dateProvider,
            isDevelopmentMode: true,
            contactsProvider: contactsProvider,
            calendarProvider: calendarProvider,
            remindersProvider: remindersProvider,
            defaults: defaults,
            audit: audit
        )
        if populated {
            services.loadSampleData()
        }
        services.refreshDerivedState()
        return services
    }

    // MARK: - Time tracking

    /// Starts the timer, and connects it to everything that has to hear about a finished entry.
    ///
    /// The wiring lives here rather than in the initialiser because it is a *behaviour* the app
    /// switches on once the window is up, and because a preview or a test that builds services and
    /// never calls this gets a timer that touches no calendar at all.
    public func startTimeTracking() {
        timer.pomodoroPlan = storedPomodoroPlan
        timer.playsPomodoroSound = defaults.object(forKey: "time.pomodoro.sound") as? Bool ?? true

        timer.onEntryFinished = { [weak self] id in
            guard let self else { return }
            // Detached from the write that produced it: a calendar round trip must never sit between
            // pressing Stop and the clock reading zero.
            Task { await self.timeMirror.synchronise(entryID: id) }
        }

        timer.start()
        timeMirror.refreshCount()
    }

    /// The focus-cycle lengths, as settings last left them.
    ///
    /// In `UserDefaults` rather than the store because they are a preference about how *this person*
    /// works, carry nothing anybody else would want, and must not travel in an archive.
    public var storedPomodoroPlan: PomodoroPlan {
        get {
            let standard = PomodoroPlan.standard
            return PomodoroPlan(
                focus: defaults.object(forKey: "time.pomodoro.focus") as? Double ?? standard.focus,
                shortBreak: defaults.object(forKey: "time.pomodoro.shortBreak") as? Double
                    ?? standard.shortBreak,
                longBreak: defaults.object(forKey: "time.pomodoro.longBreak") as? Double
                    ?? standard.longBreak,
                roundsBeforeLongBreak: defaults.object(forKey: "time.pomodoro.rounds") as? Int
                    ?? standard.roundsBeforeLongBreak,
                startsBreaksAutomatically: defaults.object(forKey: "time.pomodoro.autoBreak") as? Bool
                    ?? standard.startsBreaksAutomatically,
                startsNextFocusAutomatically: defaults.object(forKey: "time.pomodoro.autoFocus") as? Bool
                    ?? standard.startsNextFocusAutomatically
            )
        }
        set {
            defaults.set(newValue.focus, forKey: "time.pomodoro.focus")
            defaults.set(newValue.shortBreak, forKey: "time.pomodoro.shortBreak")
            defaults.set(newValue.longBreak, forKey: "time.pomodoro.longBreak")
            defaults.set(newValue.roundsBeforeLongBreak, forKey: "time.pomodoro.rounds")
            defaults.set(newValue.startsBreaksAutomatically, forKey: "time.pomodoro.autoBreak")
            defaults.set(newValue.startsNextFocusAutomatically, forKey: "time.pomodoro.autoFocus")
            // Pushed straight through, so a length changed mid-afternoon applies to the next block
            // rather than to the next launch.
            timer.pomodoroPlan = newValue
        }
    }

    /// Brings the calendar copy of one entry into line, if the mirror is on.
    ///
    /// Called after an edit or a deletion. Costs a `Task` and an immediate return when the mirror is
    /// off, which is the common case.
    public func mirrorTime(entryID: UUID) {
        Task { await timeMirror.synchronise(entryID: entryID) }
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

    /// Soft-deletes a saved search or smart list — the two share the record and the rule.
    ///
    /// A search is only its definition, so deleting one touches none of the items it finds. It is
    /// not moved to the Trash either — the Trash holds content, and a query string among somebody's
    /// deleted notes is filing noise — which is why every caller confirms before calling this.
    public func deleteSavedSearch(id: UUID) {
        perform {
            let descriptor = FetchDescriptor<SavedSearch>(predicate: #Predicate { $0.id == id })
            guard let search = try context.fetch(descriptor).first else { return }
            search.deletedAt = dateProvider.now
            try context.save()
        }
        refreshDerivedState()
    }

    // MARK: - Index

    /// Builds the search index. Called once after the window appears, never blocking launch.
    /// Throws away the index and rebuilds it. The user-visible "Rebuild Search Index" command.
    ///
    /// Lives beside ``warmSearchIndex()`` rather than in the shell that offers the command,
    /// because a contact import needs the same rebuild and both shells offer the command.
    public func invalidateAndWarmIndex() async {
        await search.invalidateIndex()
        await warmSearchIndex()
    }

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
        changeToken &+= 1
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

    /// Captures an already-composed draft, for the doors that collect one rather than a line of text.
    ///
    /// Quick Jot assembles a ``QuickJotDraft`` from chips, menus and whatever is still in its two
    /// fields, and hands the merged result here. Everything else — App Intents, the Services menu,
    /// the hot key from another application — still arrives as text and goes through
    /// ``captureText(_:)``. Both end at the same `CaptureService`.
    ///
    /// ### Why the emptiness check is here and not left to the service
    /// `CaptureService.capture(text:)` refuses an empty capture; `CaptureService.capture(_ draft:)`
    /// does not, because a caller holding a draft has usually already decided there is something in
    /// it. Wiring a composer straight through would therefore turn "press Save on a blank panel" into
    /// a row in the library, which is precisely what the text path spent effort avoiding. Checking it
    /// on the way past keeps the two doors answering the same way.
    @discardableResult
    public func captureDraft(_ draft: CaptureDraft) throws(AppError) -> Item? {
        guard !draft.isEmpty else { return nil }
        let item = try capture.capture(draft)
        noteChange(to: item)
        return item
    }

    /// Saves one durable browser handoff and refreshes every derived view that needs to see it.
    @discardableResult
    public func saveWebClip(_ clip: WebClip) async throws(AppError) -> Item {
        let item = try webClips.save(clip)
        try await indexWebClipImages(in: item)
        noteChange(to: item)
        return item
    }

    /// Runs every image saved by the clipper through Vision and folds the recognized text into the
    /// owning item's normal search projection. OCR stays in attachment metadata: it makes the image
    /// findable without dumping another transcription into the note editor.
    private func indexWebClipImages(in item: Item) async throws(AppError) {
        var changed = false
        for attachment in (item.attachments ?? []) where attachment.typeIdentifier == "public.png"
            || attachment.typeIdentifier == "public.jpeg" {
            guard attachment.extractedText == nil,
                  let url = attachments.resolve(attachment),
                  let data = try? Data(contentsOf: url) else { continue }

            do {
                let lines = try await textRecognizer.recognizeText(in: data)
                let text = lines
                    .sorted(by: Self.isEarlierOCRLine)
                    .map(\.text)
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                attachment.extractedText = text.isEmpty ? nil : text
                changed = changed || !text.isEmpty
            } catch {
                Diagnostics.persistence.error(
                    "Could not OCR web clip image \(attachment.filename, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        if changed {
            try items.update(item) { $0.refreshSearchText() }
        }
    }

    private static func isEarlierOCRLine(_ lhs: RecognizedLine, _ rhs: RecognizedLine) -> Bool {
        let rowTolerance: CGFloat = 0.01
        if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > rowTolerance {
            return lhs.boundingBox.midY > rhs.boundingBox.midY
        }
        return lhs.boundingBox.minX < rhs.boundingBox.minX
    }

    public func noteRemoval(of id: UUID) {
        let engine = search
        Task { await engine.removeFromIndex(id: id) }
        changeToken &+= 1
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

    /// Works out whether the attachment folder and the store still agree.
    ///
    /// Writes nothing. Failure is logged and treated as "nothing to tidy" — a housekeeping pass that
    /// could not run is not a reason to bother the user, and certainly not a reason to fail a launch.
    public func checkForAttachmentTidy() {
        guard let location = stack.location else {
            pendingAttachmentTidy = nil
            return
        }

        let reconciliation = AttachmentReconciliation(
            context: context, location: location, dateProvider: dateProvider
        )
        do {
            let report = try reconciliation.plan()
            pendingAttachmentTidy = report.isEmpty ? nil : report
            if let report = pendingAttachmentTidy {
                Diagnostics.persistence.info("Attachment tidy available: \(report.summary, privacy: .public)")
            }
        } catch {
            Diagnostics.persistence.error(
                "Could not plan attachment tidy: \(error.localizedDescription, privacy: .public)"
            )
            pendingAttachmentTidy = nil
        }
    }

    /// Performs the tidy the user approved.
    @discardableResult
    public func applyAttachmentTidy() -> Bool {
        guard let location = stack.location, let report = pendingAttachmentTidy else { return false }

        let reconciliation = AttachmentReconciliation(
            context: context, location: location, dateProvider: dateProvider
        )
        let succeeded = perform { try reconciliation.apply(report) }
        if succeeded { pendingAttachmentTidy = nil }
        return succeeded
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
        containerSidebar.refresh()
        // Without this the Projects tree is empty until something else changes — which is exactly
        // how "no projects until you create one" happened: everything the sidebar reads is computed
        // on change and never during a render, so the *first* computation has to come from
        // somewhere, and at launch this is the only somewhere there is.
        projectSidebar.refresh()
    }

    // MARK: - Pending edits at suspension

    /// The editors that still owe a write, by the item they owe it about.
    ///
    /// On macOS this registry lives on each window's `NavigationModel`, because the moments
    /// that endanger a pending edit there are navigational. On iOS the dangerous moment is
    /// the scene leaving the foreground — a suspended app can be killed with no further
    /// notice — and the scene is something only the application object sees. So the shared
    /// service graph carries the registry, both shells' editors register here, and each
    /// shell flushes on the hazard its platform actually has.
    @ObservationIgnored private var suspensionFlushes: [UUID: () -> Void] = [:]

    /// Registers work that must not be lost if the process is about to stop being trusted
    /// with it. One editor per item; a second registration replaces the first.
    public func registerSuspensionFlush(_ id: UUID, _ flush: @escaping () -> Void) {
        suspensionFlushes[id] = flush
    }

    public func unregisterSuspensionFlush(_ id: UUID) {
        suspensionFlushes[id] = nil
    }

    /// Runs every registered flush now. Safe to call from a scene-phase change.
    public func flushForSuspension() {
        for flush in suspensionFlushes.values { flush() }
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
        let populated = perform {
            try SampleData.populate(services: self)
        }
        guard populated else { return }

        refreshDerivedState()

        // Sample data is written straight through `ItemService`, which is the point — it exercises
        // the same path a real write takes. What it skips is ``noteChange(to:)``, and with it the
        // index, so the invented notes and reminders were unreachable by search: the
        // index had already been opened, found complete, and had no reason to look again.
        //
        // The effect was that every review of this app searched an empty index and concluded the
        // search field was broken. Rebuilding here costs a second on a library this size and makes
        // the loaded data behave like data.
        Task { [search] in
            await search.invalidateIndex()
            await search.warmIndex()
        }
    }

    /// Loads the sample library, but only into a library that has none.
    ///
    /// The guard is what makes this safe to run from a launch argument. `loadSampleData()` writes
    /// unconditionally, so a flag that called it on every launch would double the library each time
    /// the app opened — and the second launch would look like a duplication bug rather than like the
    /// flag doing exactly what it was told.
    @discardableResult
    public func loadSampleDataIfEmpty() -> Bool {
        guard isDevelopmentMode else {
            Diagnostics.features.error("Sample data requested outside development mode; refused")
            return false
        }

        let existing = (try? items.count(matching: ItemQuery())) ?? 0
        guard existing == 0 else { return false }

        loadSampleData()
        return true
    }

    /// Adds invented people until the library holds at least `count` of them.
    ///
    /// Tops up rather than replacing, and counts what is already there, so it composes with
    /// ``loadSampleDataIfEmpty()`` and is idempotent across relaunches: asking for four hundred twice
    /// gives four hundred, not eight.
    public func seedPeople(upTo count: Int) {
        guard isDevelopmentMode else {
            Diagnostics.features.error("People seeding requested outside development mode; refused")
            return
        }

        var query = ItemQuery()
        query.kinds = [.person]
        let existing = (try? items.count(matching: query)) ?? 0
        guard existing < count else { return }

        let seeded = perform {
            try BulkPeopleSampleData.populate(services: self, count: count - existing)
        }
        guard seeded else { return }

        refreshDerivedState()
        Diagnostics.features.info("Seeded People up to \(count, privacy: .public) records")

        Task { [search] in
            await search.invalidateIndex()
            await search.warmIndex()
        }
    }

    /// Removes what ``seedPeople(upTo:)`` planted, and nothing else.
    ///
    /// The counterpart the seeder always owed: development mode does not redirect the store, so a
    /// seeding flag on a launch without `-ElephruitUseTemporaryStore` writes invented people into
    /// the real library — which happened. Each candidate is matched by running the generator
    /// backwards (see ``BulkPeopleSampleData/isSeeded(_:)``), and removal is permanent rather than
    /// through the Trash: seventeen hundred synthetic rows in the Trash is a second mess, not a
    /// safety net, and the records were never the user's to begin with.
    public func removeSeededPeople() {
        guard isDevelopmentMode else {
            Diagnostics.features.error("Seeded-people removal requested outside development mode; refused")
            return
        }

        var query = ItemQuery()
        query.kinds = [.person]
        guard let people = try? items.items(matching: query) else { return }

        let seeded = people.filter { BulkPeopleSampleData.isSeeded($0) }
        guard !seeded.isEmpty else {
            Diagnostics.features.info("No seeded people found; nothing removed")
            return
        }

        let removed = perform {
            for person in seeded {
                try items.deletePermanently(person)
            }
        }
        guard removed else { return }

        refreshDerivedState()
        Diagnostics.features.info(
            "Removed \(seeded.count, privacy: .public) seeded people; \(people.count - seeded.count, privacy: .public) records untouched"
        )

        Task { [search] in
            await search.invalidateIndex()
            await search.warmIndex()
        }
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
    /// Re-injects services into a sheet, which starts a fresh environment of its own.
    ///
    /// `nil` passes through untouched rather than crashing: a sheet presented before the library is
    /// open has nothing to show, and the views inside already handle an absent store.
    @ViewBuilder
    public func appServicesIfAvailable(_ services: AppServices?) -> some View {
        if let services {
            appServices(services)
        } else {
            self
        }
    }

    public func appServices(_ services: AppServices) -> some View {
        environment(\.services, services)
            .modelContext(services.context)
    }
}
