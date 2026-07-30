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
        public static let manualEntrySheet = "time.manualEntry"
        public static let windowPicker = "time.window"
        public static let groupingPicker = "time.grouping"
        public static let recoveryBanner = "time.recovery"
        public static let recoveryStop = "time.recovery.stop"
        public static let recoveryKeep = "time.recovery.keep"
        public static let recoveryDiscard = "time.recovery.discard"

        public static func entryRow(id: String) -> String { "time.entry.\(id)" }
        public static func itemToggle(id: String) -> String { "time.toggle.\(id)" }
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
        public static let rebuildIndexButton = "settings.rebuildIndex"
    }
}
