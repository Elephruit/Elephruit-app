import ElephruitCore
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import Foundation

/// Development-only launch routing for the iPad shell, so every arrangement can be reviewed and
/// photographed on a machine nobody is tapping.
///
/// The same tooling philosophy as the Mac's `DesignReviewLaunch`, which closed the "calendar was
/// never photographed working" gap: a review that cannot *reach* a screen repeatably reports the
/// previous build's bugs. Everything here is inert without `-ElephruitDevelopmentMode`, exactly
/// like the store and fixture switches beside it.
///
///     -ElephruitPadRoot today | inbox | search | reminders | records | calendar | time |
///                       archive | trash | settings | notes | ideas | reference | daily |
///                       bookmarks | areas | overdue | flagged | firstProject
///     -ElephruitPadSelectFirst        // open the list's first record in the reading pane
@MainActor
enum PadReviewLaunch {
    /// The root named by the arguments, if any.
    static func requestedRoot(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        services: AppServices?
    ) -> PadRoot? {
        guard arguments.contains("-ElephruitDevelopmentMode"),
            let index = arguments.firstIndex(of: "-ElephruitPadRoot"),
            index + 1 < arguments.count
        else { return nil }

        let token = arguments[index + 1].lowercased()

        switch token {
        case "today": return .today
        case "inbox": return .inbox
        case "search": return .search
        case "reminders": return .reminders
        case "records": return .records(.all)
        case "people": return .records(.people)
        case "calendar": return .calendar
        case "time": return .time
        case "archive": return .archive
        case "trash": return .trash
        case "settings": return .settings
        case "notes": return .kindList(.note)
        case "ideas": return .kindList(.idea)
        case "reference": return .kindList(.reference)
        case "daily": return .kindList(.dailyEntry)
        case "bookmarks": return .kindList(.bookmark)
        case "areas": return .kindList(.area)
        case "firstproject":
            guard let first = services?.projectSidebar.rows.first(where: { !$0.isArea })
            else { return nil }
            return .project(first.id)
        default:
            // Anything left is a built-in smart list by its own identifier, so adding a list to
            // `BuiltInSmartList.all` makes it reviewable without editing this table.
            guard BuiltInSmartList.list(id: token) != nil else { return nil }
            return .builtInSmartList(token)
        }
    }

    /// The screen a *phone* review should open on.
    ///
    /// ### Why the phone had none until now
    /// This file was written for the iPad shell, and the phone was left with whatever the previous
    /// session happened to leave open — so a headless review of a phone screen photographed the last
    /// build's navigation, or the wrong screen entirely, and the only way to reach anything was to
    /// tap. Which is the same gap the Mac's `DesignReviewLaunch` was written to close, one shell
    /// later.
    ///
    /// The vocabulary is deliberately the same. A phone stack is a push rather than a three-column
    /// selection, so the pair that selects a record on the iPad resolves here to the one route to
    /// push onto it.
    ///
    ///     -ElephruitPadRoot people -ElephruitPadSelectFirst
    ///     -ElephruitPadRoot people -ElephruitSelectPerson Maya
    static func requestedPhoneRoute(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        services: AppServices?
    ) -> MobileRoute? {
        guard arguments.contains("-ElephruitDevelopmentMode") else { return nil }

        // A named person wins over "the first one", because a review that silently photographs
        // whoever sorts first is a review of the alphabet.
        if let index = arguments.firstIndex(of: "-ElephruitSelectPerson"),
           index + 1 < arguments.count,
           let services {
            let wanted = arguments[index + 1].lowercased()
            let people = (try? services.persons.allPeople(includingPlaceholders: true)) ?? []
            guard let match = people.first(where: { $0.title.lowercased().hasPrefix(wanted) }) else {
                Diagnostics.shell.error("No person matching \(wanted, privacy: .public)")
                return nil
            }
            return .person(match.id)
        }

        guard let root = requestedRoot(arguments: arguments, services: services) else { return nil }
        return requestedDetail(for: root, arguments: arguments, services: services)
    }

    /// The project view a review launch asked for.
    ///
    /// A project's five presentations are five screens, and a review that can only ever photograph
    /// the board is a review of one fifth of the workspace.
    ///
    ///     -ElephruitPadProjectView overview | board | list | table | bugs
    static var requestedProjectView: PadProjectPresentation? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ElephruitDevelopmentMode"),
            let index = arguments.firstIndex(of: "-ElephruitPadProjectView"),
            index + 1 < arguments.count
        else { return nil }
        return PadProjectPresentation(rawValue: arguments[index + 1].lowercased())
    }

    /// The calendar view a review launch asked for.
    ///
    ///     -ElephruitPadCalendarView agenda | week | day
    static var requestedCalendarView: PadCalendarView? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ElephruitDevelopmentMode"),
            let index = arguments.firstIndex(of: "-ElephruitPadCalendarView"),
            index + 1 < arguments.count
        else { return nil }
        return PadCalendarView(rawValue: arguments[index + 1].lowercased())
    }

    /// The record the reading pane should open on, when the arguments asked for one.
    static func requestedDetail(
        for root: PadRoot,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        services: AppServices?
    ) -> MobileRoute? {
        guard arguments.contains("-ElephruitDevelopmentMode"),
            arguments.contains("-ElephruitPadSelectFirst"),
            let services
        else { return nil }

        switch root {
        case .kindList(let kind):
            let items = (try? services.items.items(matching: .kind(kind, sort: .updatedNewestFirst))) ?? []
            return items.first.map { .item($0.id) }
        case .records:
            let people = (try? services.persons.allPeople(includingPlaceholders: false)) ?? []
            return people.first.map { .person($0.id) }
        case .inbox:
            let items = (try? services.items.items(matching: .inbox())) ?? []
            return items.first.map { .item($0.id) }
        case .archive:
            let items = (try? services.items.items(matching: .archive())) ?? []
            return items.first.map { .item($0.id) }
        case .trash:
            let items = (try? services.items.items(matching: .trash())) ?? []
            return items.first.map { .item($0.id) }
        default:
            return nil
        }
    }
}
