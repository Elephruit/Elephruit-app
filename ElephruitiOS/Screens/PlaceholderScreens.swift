import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import SwiftUI

/// The screens the shell promises, before each one is built.
///
/// Every placeholder is honest about being one: the shell, the tabs, the routes, the
/// restoration, and the deep links are real from this commit on, and each screen replaces
/// its placeholder in its own reviewed pass — one module at a time, photographed. A
/// placeholder that pretended to be a screen would make the review pass unable to say
/// what changed.
private struct PlaceholderScreen: View {
    let title: String
    let symbolName: String

    var body: some View {
        EmptyStateView(
            symbolName: symbolName,
            headline: title,
            message: "This screen arrives in its own reviewed pass."
        )
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TodayScreen: View {
    var body: some View { PlaceholderScreen(title: "Today", symbolName: "sun.horizon") }
}

struct RemindersScreen: View {
    var body: some View { PlaceholderScreen(title: "Reminders", symbolName: "checkmark.circle") }
}

struct RecordsScreen: View {
    var body: some View { PlaceholderScreen(title: "Records", symbolName: "person.2") }
}

struct SearchScreen: View {
    var body: some View { PlaceholderScreen(title: "Search", symbolName: "magnifyingglass") }
}

/// The one placeholder with real content: Library is the shell's own directory, so its
/// rows exist from the start — each pushes the real route, landing on that route's
/// placeholder until the screen behind it is built.
struct LibraryScreen: View {
    var body: some View {
        List {
            Section {
                NavigationLink(value: MobileRoute.inbox) {
                    Label("Inbox", systemImage: "tray")
                }
                NavigationLink(value: MobileRoute.kindList(.note)) {
                    Label("Notes", systemImage: "note.text")
                }
                NavigationLink(value: MobileRoute.calendar) {
                    Label("Calendar", systemImage: "calendar")
                }
                NavigationLink(value: MobileRoute.time) {
                    Label("Time", systemImage: "clock")
                }
                NavigationLink(value: MobileRoute.kindList(.bookmark)) {
                    Label("Bookmarks", systemImage: "bookmark")
                }
            }
            Section {
                NavigationLink(value: MobileRoute.archive) {
                    Label("Archive", systemImage: "archivebox")
                }
                NavigationLink(value: MobileRoute.trash) {
                    Label("Trash", systemImage: "trash")
                }
            }
            Section {
                NavigationLink(value: MobileRoute.settings) {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .navigationTitle("Library")
    }
}

// MARK: - Routed screens

struct ItemScreen: View {
    let itemID: UUID
    var body: some View { PlaceholderScreen(title: "Item", symbolName: "doc") }
}

struct ProjectScreen: View {
    let projectID: UUID
    var body: some View { PlaceholderScreen(title: "Project", symbolName: "folder") }
}

struct PersonScreen: View {
    let personID: UUID
    var body: some View { PlaceholderScreen(title: "Record", symbolName: "person") }
}

struct ReminderListScreen: View {
    enum Source: Hashable {
        case smartList(UUID)
        case builtIn(String)
    }

    let source: Source
    var body: some View { PlaceholderScreen(title: "List", symbolName: "list.bullet") }
}

struct RecordsListScreen: View {
    let scope: RecordsScope
    var body: some View { PlaceholderScreen(title: "Records", symbolName: "person.2") }
}

struct ItemListScreen: View {
    enum Source: Hashable {
        case tag(String)
        case kind(ItemKind)
        case archive
    }

    let source: Source

    var body: some View {
        PlaceholderScreen(title: title, symbolName: symbolName)
    }

    private var title: String {
        switch source {
        case .tag(let slug): "#\(slug)"
        case .kind(let kind): kind.pluralDisplayName
        case .archive: "Archive"
        }
    }

    private var symbolName: String {
        switch source {
        case .tag: "number"
        case .kind: "square.grid.2x2"
        case .archive: "archivebox"
        }
    }
}

struct InboxScreen: View {
    var body: some View { PlaceholderScreen(title: "Inbox", symbolName: "tray") }
}

struct TrashScreen: View {
    var body: some View { PlaceholderScreen(title: "Trash", symbolName: "trash") }
}

struct EventScreen: View {
    let identityKey: String
    var body: some View { PlaceholderScreen(title: "Event", symbolName: "calendar") }
}

struct CalendarScreen: View {
    var body: some View { PlaceholderScreen(title: "Calendar", symbolName: "calendar") }
}

struct TimeScreen: View {
    var body: some View { PlaceholderScreen(title: "Time", symbolName: "clock") }
}

struct SettingsScreen: View {
    var body: some View { PlaceholderScreen(title: "Settings", symbolName: "gearshape") }
}

// MARK: - Shell furniture stubs

/// The quick-capture sheet. The real draft-preserving composer with grammar chips is the
/// Capture pass; the sheet exists now so the button's promise is never a dead tap.
struct CaptureSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EmptyStateView(
                symbolName: "plus.circle",
                headline: "Capture",
                message: "The capture composer arrives in its own reviewed pass."
            )
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The running timer above the tab bar. The full control set is the Time pass.
struct TimerAccessoryView: View {
    @Environment(\.services) private var services

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "record.circle")
                .foregroundStyle(Theme.Colors.recording)
            Text(timerLabel)
                .font(Theme.Text.rowSubtitle)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .accessibilityIdentifier("mobile.timer.accessory")
    }

    /// The most specific name the running timer has: its subject, its description, or "Timer".
    private var timerLabel: String {
        guard let running = services?.timer.running else { return "Timer" }
        if let itemTitle = running.itemTitle, !itemTitle.isEmpty { return itemTitle }
        if !running.entryDescription.isEmpty { return running.entryDescription }
        return "Timer"
    }
}
