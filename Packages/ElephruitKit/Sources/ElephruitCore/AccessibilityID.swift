/// Accessibility identifiers, in one namespace.
///
/// Views and UI tests reference the same constants, so a renamed element breaks the
/// build rather than a test run. These are identifiers for automation, not labels for
/// VoiceOver — user-facing labels live with the views and are composed by
/// ``ContentItem/accessibilityDescription(using:)``.
public enum AccessibilityID {
    public enum Sidebar {
        public static let root = "sidebar"
        public static let today = "sidebar.today"
        public static let inbox = "sidebar.inbox"
        public static let notes = "sidebar.notes"
        public static let tasks = "sidebar.tasks"
        public static let projects = "sidebar.projects"
        public static let areas = "sidebar.areas"
        public static let tags = "sidebar.tags"
        public static let savedSearches = "sidebar.savedSearches"
        public static let trash = "sidebar.trash"
        public static let syncStatus = "sidebar.syncStatus"

        public static func tag(slug: String) -> String { "sidebar.tag.\(slug)" }
        public static func savedSearch(name: String) -> String { "sidebar.savedSearch.\(name)" }
    }

    public enum ItemList {
        public static let root = "itemList"
        public static let searchField = "itemList.searchField"
        public static let sortMenu = "itemList.sortMenu"
        public static let filterMenu = "itemList.filterMenu"
        public static let emptyState = "itemList.emptyState"
        public static let newItemButton = "itemList.newItem"

        public static func row(id: String) -> String { "itemList.row.\(id)" }
        public static func statusToggle(id: String) -> String { "itemList.row.\(id).statusToggle" }
    }

    public enum Detail {
        public static let root = "detail"
        public static let titleField = "detail.titleField"
        public static let bodyEditor = "detail.bodyEditor"
        public static let emptyState = "detail.emptyState"
        public static let backlinksSection = "detail.backlinks"
        public static let inspectorToggle = "detail.inspectorToggle"
    }

    public enum Inspector {
        public static let root = "inspector"
        public static let kindPicker = "inspector.kind"
        public static let statusPicker = "inspector.status"
        public static let priorityPicker = "inspector.priority"
        public static let dueDateField = "inspector.dueDate"
        public static let startDateField = "inspector.startDate"
        public static let projectPicker = "inspector.project"
        public static let tagField = "inspector.tags"
        public static let favoriteToggle = "inspector.favorite"
        public static let pinToggle = "inspector.pin"
        public static let provenance = "inspector.provenance"
    }

    public enum QuickCapture {
        public static let root = "quickCapture"
        public static let textField = "quickCapture.textField"
        public static let saveButton = "quickCapture.save"
        public static let cancelButton = "quickCapture.cancel"
        public static let interpretation = "quickCapture.interpretation"
    }

    public enum CommandPalette {
        public static let root = "commandPalette"
        public static let field = "commandPalette.field"
        public static let results = "commandPalette.results"

        public static func result(index: Int) -> String { "commandPalette.result.\(index)" }
    }

    public enum Search {
        public static let root = "search"
        public static let field = "search.field"
        public static let results = "search.results"
        public static let saveSearchButton = "search.saveSearch"
        public static let recentSearches = "search.recents"
        public static let tokenHelp = "search.tokenHelp"
        public static let scopePicker = "search.scope"
        public static let unrecognisedNote = "search.unrecognised"

        public static func result(id: String) -> String { "search.result.\(id)" }
    }

    public enum Time {
        public static let root = "time"
        public static let timerBar = "time.timerBar"
        public static let startButton = "time.start"
        public static let stopButton = "time.stop"
        public static let addEntryButton = "time.addEntry"
        public static let windowPicker = "time.window"
        public static let groupingPicker = "time.grouping"
        public static let recoveryBanner = "time.recovery"
        public static let recoveryStop = "time.recovery.stop"
        public static let recoveryKeep = "time.recovery.keep"
        public static let recoveryDiscard = "time.recovery.discard"

        // The entry bar: one row that both starts timers and records time already spent.
        public static let modeToggle = "time.mode"
        public static let descriptionField = "time.description"
        public static let subjectPicker = "time.subject"
        public static let tagPicker = "time.tags"
        public static let billableToggle = "time.billable"
        public static let durationField = "time.duration"
        public static let discardButton = "time.discard"

        public static let groupingToggle = "time.groupSimilar"
        public static let manualSheet = "time.manualSheet"
        public static let manualAddButton = "time.manualSheet.add"
        public static let editRowButton = "time.editRow"

        // The floating timer, over every screen in the window.
        public static let floatingTimer = "time.floating"
        public static let floatingPause = "time.floating.pause"
        public static let floatingRestart = "time.floating.restart"
        public static let floatingStop = "time.floating.stop"
        public static let floatingCollapse = "time.floating.collapse"

        // The panel that starts a timer from any application.
        public static let quickLog = "time.quickLog"
        public static let quickLogDescription = "time.quickLog.description"
        public static let quickLogDiscard = "time.quickLog.discard"
        public static let quickLogStop = "time.quickLog.stop"
        public static let quickLogDone = "time.quickLog.done"
        public static let quickLogStart = "time.quickLog.start"

        // The app, collapsed to the clock.
        public static let miniTimer = "time.mini"
        public static let miniTimerMenu = "time.mini.menu"
        public static let miniTimerPin = "time.mini.pin"
        public static let miniTimerExpand = "time.mini.expand"
        public static let miniTimerCompact = "time.mini.compact"
        public static let projectPicker = "time.project"
        public static let peoplePicker = "time.people"

        // Focus cycles.
        public static let focusButton = "time.focus"
        public static let focusStrip = "time.focus.strip"
        public static let focusPause = "time.focus.pause"
        public static let focusSkip = "time.focus.skip"
        public static let focusEnd = "time.focus.end"
        public static let focusBanner = "time.focus.banner"

        // Reports.
        public static let reportRoot = "time.report"
        public static let reportPeriodPicker = "time.report.period"
        public static let reportRoundingPicker = "time.report.rounding"
        public static let reportExportButton = "time.report.export"
        public static let reportChart = "time.report.chart"

        public static func reportRow(key: String) -> String { "time.report.row.\(key)" }

        // Idle.
        public static let idleBanner = "time.idle"
        public static let idleDiscard = "time.idle.discard"
        public static let idleDiscardAndContinue = "time.idle.discardAndContinue"
        public static let idleKeep = "time.idle.keep"
        public static let idleSeparate = "time.idle.separate"

        public static func entryRow(id: String) -> String { "time.entry.\(id)" }
        public static func groupRow(id: String) -> String { "time.group.\(id)" }
        public static func daySection(key: String) -> String { "time.day.\(key)" }
        public static func itemToggle(id: String) -> String { "time.toggle.\(id)" }
    }

    public enum Attachments {
        public static let section = "attachments"
        public static let addButton = "attachments.add"

        public static func row(id: String) -> String { "attachments.row.\(id)" }
    }

    public enum People {
        public static let relationshipSummary = "people.summary"
        public static let recordInteraction = "people.recordInteraction"
        public static let interactionSheet = "people.interactionSheet"

        // The workspace.
        public static let workspace = "people.workspace"
        public static let header = "people.header"
        public static let quickActions = "people.quickActions"
        public static let contactDetails = "people.contactDetails"
        public static let editContactDetails = "people.editContactDetails"
        public static let contactEditor = "people.contactEditor"
        public static let contactWriteBackSheet = "people.contactWriteBackSheet"
        public static let timeline = "people.timeline"
        public static let contextSidebar = "people.contextSidebar"
        public static let list = "people.list"
        public static let sortMenu = "people.sortMenu"

        // Facts.
        public static let addFact = "people.addFact"
        public static let addFactSheet = "people.addFactSheet"
        public static let correctFactSheet = "people.correctFactSheet"
        public static let staleFacts = "people.staleFacts"

        // Relationships.
        public static let charts = "people.charts"
        public static let chartSheet = "people.chartSheet"
        public static let addRelationshipSheet = "people.addRelationshipSheet"

        // Actions.
        public static let contactConfirmation = "people.contactConfirmation"
        public static let meetingBrief = "people.meetingBrief"
        public static let groupActionPreview = "people.groupActionPreview"

        // Adding somebody by hand.
        public static let newPersonSheet = "people.newPersonSheet"

        // The command bar.
        public static let commandBar = "people.commandBar"
        public static let commandField = "people.commandField"
        public static let commandPreview = "people.commandPreview"

        // Other destinations.
        public static let celebrations = "people.celebrations"
        public static let myCard = "people.myCard"
        public static let cardScan = "people.cardScan"
        public static let contactsSettings = "people.contactsSettings"
        public static let duplicates = "people.duplicates"

        // Bringing the address book in.
        public static let contactOnboarding = "people.contactOnboarding"
        public static let contactExplanation = "people.contactExplanation"
        public static let contactAccessRefused = "people.contactAccessRefused"
        public static let contactReview = "people.contactReview"
        public static let contactDuplicate = "people.contactDuplicate"
        public static let contactImportFinished = "people.contactImportFinished"
        public static let linkedContactSection = "people.linkedContact"
    }

    /// The day, whole. Replaces the identifiers Home and Upcoming used between them.
    public enum Today {
        public static let root = "today"
        public static let briefing = "today.briefing"
        public static let figures = "today.briefing.figures"
        public static let nextCommitment = "today.briefing.next"

        public static let needsAttention = "today.needsAttention"
        public static let schedule = "today.schedule"
        public static let tasks = "today.tasks"
        public static let people = "today.people"
        public static let completed = "today.completed"

        public static let startDailyNote = "today.startDailyNote"
        public static let dailyNote = "today.dailyNote"
        public static let quickAdd = "today.quickAdd"

        public static let previousDay = "today.previousDay"
        public static let nextDay = "today.nextDay"
        public static let returnToToday = "today.returnToToday"
        public static let datePicker = "today.datePicker"
        public static let showPreviousDays = "today.showPreviousDays"
        public static let loadMoreDays = "today.loadMoreDays"
        public static let filters = "today.filters"

        public static func day(_ key: String) -> String { "today.day.\(key)" }
        public static func person(_ key: String) -> String { "today.person.\(key)" }
        public static func event(_ id: String) -> String { "today.event.\(id)" }
    }

    public enum Calendar {
        public static let statusBanner = "calendar.status"
        public static let enableToggle = "calendar.enable"

        // The workspace.
        public static let workspace = "calendar.workspace"
        public static let viewSwitcher = "calendar.viewSwitcher"
        public static let todayButton = "calendar.today"
        public static let previousButton = "calendar.previous"
        public static let nextButton = "calendar.next"
        public static let setSwitcher = "calendar.setSwitcher"
        public static let dayPopover = "calendar.dayPopover"
        public static let offlineBanner = "calendar.offline"

        // Creating and editing.
        public static let quickEntry = "calendar.quickEntry"
        public static let quickEntryField = "calendar.quickEntry.field"
        public static let quickEntryTokens = "calendar.quickEntry.tokens"
        public static let editor = "calendar.editor"
        public static let editorTitle = "calendar.editor.title"
        public static let editorCalendar = "calendar.editor.calendar"
        public static let recurrenceEditor = "calendar.recurrenceEditor"
        public static let scopeSheet = "calendar.scopeSheet"
        public static let inspector = "calendar.inspector"

        // Sets and templates.
        public static let setEditor = "calendar.setEditor"
        public static let templateMenu = "calendar.templateMenu"
        public static let templateEditor = "calendar.templateEditor"

        // Searching and preparing.
        public static let search = "calendar.search"
        public static let searchField = "calendar.search.field"
        public static let meetingPrep = "calendar.meetingPrep"

        public static func eventRow(id: String) -> String { "calendar.event.\(id)" }
        public static func setRow(id: String) -> String { "calendar.set.\(id)" }
    }

    public enum Trash {
        public static let restoreButton = "trash.restore"
        public static let deletePermanentlyButton = "trash.deletePermanently"
        public static let emptyTrashButton = "trash.emptyTrash"
    }

    public enum Transfer {
        public static let exportButton = "transfer.export"
        public static let importButton = "transfer.import"
        public static let formatPicker = "transfer.format"
        public static let progress = "transfer.progress"
        public static let summary = "transfer.summary"
    }

    public enum Failure {
        public static let root = "failureState"
        public static let message = "failureState.message"

        public static func recoveryButton(_ option: RecoveryOption) -> String {
            "failureState.recovery.\(option)"
        }
    }

    public enum Settings {
        public static let root = "settings"
        public static let generalTab = "settings.general"
        public static let editorTab = "settings.editor"
        public static let advancedTab = "settings.advanced"
        public static let timeTab = "settings.time"
        public static let calendarTab = "settings.calendar"
        public static let shortcutsTab = "settings.shortcuts"
        public static let privacyTab = "settings.privacy"
        public static let rebuildIndexButton = "settings.rebuildIndex"
    }
}
