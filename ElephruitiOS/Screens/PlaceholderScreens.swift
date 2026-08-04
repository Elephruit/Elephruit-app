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

struct RemindersScreen: View {
    var body: some View { PlaceholderScreen(title: "Reminders", symbolName: "checkmark.circle") }
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
