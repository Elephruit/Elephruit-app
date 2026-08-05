import ElephruitCore
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// Turns one `MobileRoute` into its screen.
///
/// The single dispatch table for every arrival — push, search result, wiki link, deep
/// link, intent. One table is what makes "back navigation, tab switching, deep links,
/// state restoration, and search-result navigation must agree" true by construction
/// rather than by review.
struct MobileRouteView: View {
    @Environment(\.services) private var services

    let route: MobileRoute

    var body: some View {
        switch route {
        case .item(let id):
            ItemScreen(itemID: id)
        case .project(let id):
            ProjectScreen(projectID: id)
        case .person(let id):
            PersonScreen(personID: id)
        case .smartList(let id):
            ReminderListScreen(source: .smartList(id))
        case .builtInSmartList(let id):
            ReminderListScreen(source: .builtIn(id))
        case .records(let scope):
            RecordsListScreen(scope: scope)
        case .groups:
            GroupsScreen()
        case .tag(let slug):
            ItemListScreen(source: .tag(slug))
        case .kindList(let kind):
            ItemListScreen(source: .kind(kind))
        case .inbox:
            InboxScreen()
        case .archive:
            ItemListScreen(source: .archive)
        case .trash:
            TrashScreen()
        case .event(let key):
            EventScreen(identityKey: key)
        case .calendar:
            CalendarScreen()
        case .time:
            TimeScreen()
        case .settings:
            SettingsScreen()
        }
    }
}
