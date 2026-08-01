import AppKit
import ElephruitCore
import ElephruitPersistence
import Foundation

/// Launch arguments that put the app in a known state for a design review.
///
/// ### Why this exists
/// Reviewing this app on screen has, until now, meant a person sitting at an unlocked Mac clicking
/// through it. That has cost the project real coverage: the calendar module went unreviewed for a
/// whole milestone, and **dark mode has never been looked at at all**, because checking it means
/// changing a system-wide setting that affects every other application the reviewer has open. The
/// README says as much, twice, and has said it across several sessions.
///
/// Neither gap is a design problem. Both are a *reachability* problem, and reachability is
/// something the app can fix for itself.
///
/// With these arguments a reviewer — or a script, on a machine whose screen is locked — can open
/// the app directly onto any module, in either appearance, at any window size, and photograph it.
/// No clicking, no system settings touched, no dependence on where the last session happened to
/// leave the window.
///
/// ### Why launch arguments rather than a debug menu
/// The same reason ``AppEnvironment`` already uses one for development mode: a menu item is part of
/// the shipped interface and has to be designed, explained, and kept out of a release build. An
/// argument is inert unless somebody passes it, and every one of these is additionally gated on
/// `-ElephruitDevelopmentMode`, so a release build cannot be talked into any of it.
public enum DesignReviewLaunch {
    /// Whether the developer affordances are available at all.
    ///
    /// Read from the process rather than passed in, so this can be consulted from a view without
    /// threading a flag through every layer between here and the window. It matches the test
    /// ``AppEnvironment`` makes, deliberately: two different answers to "is this a development
    /// build" is exactly the kind of divergence that lets a debug affordance reach a release.
    static var isDevelopmentMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-ElephruitDevelopmentMode")
            || UserDefaults.standard.bool(forKey: "ElephruitDevelopmentMode")
    }

    /// The value following `name` in `arguments`, if there is one.
    ///
    /// Hand-parsed rather than read through `UserDefaults`, because `UserDefaults` only picks up
    /// `-key value` pairs it considers well-formed and silently writes them into the application's
    /// preferences — which would mean a review run permanently changing the state of the library it
    /// was reviewing.
    ///
    /// Takes the list rather than reading the process, so every rule below is a pure function of its
    /// input and can be asserted in a test instead of demonstrated by launching something.
    static func value(for name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
            return nil
        }
        let candidate = arguments[index + 1]
        // A following argument that is itself a flag means the value was omitted.
        return candidate.hasPrefix("-") ? nil : candidate
    }

    /// Where the window should open, overriding whatever the scene was last left showing.
    ///
    /// Accepts either a module (`people`, `calendar`, `tasks`, …) or one of the four destinations
    /// that belong to no module (`home`, `today`, `upcoming`, `inbox`) — the same vocabulary the
    /// sidebar uses, so the argument reads as the name of the thing the reviewer wants to see.
    public static var start: Start? {
        guard isDevelopmentMode else { return nil }
        return start(in: ProcessInfo.processInfo.arguments)
    }

    static func start(in arguments: [String]) -> Start? {
        guard let raw = value(for: "-ElephruitStartModule", in: arguments)?.lowercased() else {
            return nil
        }

        switch raw {
        case "home": return .destination(.home)
        case "today": return .destination(.today)
        case "upcoming": return .destination(.upcoming)
        case "inbox": return .destination(.inbox)
        default:
            guard let module = AppModule(rawValue: raw) else {
                Diagnostics.shell.error("Unknown -ElephruitStartModule \(raw, privacy: .public)")
                return nil
            }
            return .module(module)
        }
    }

    public enum Start: Sendable, Equatable {
        case module(AppModule)
        case destination(SidebarSelection)
    }

    /// The appearance to force, ignoring the system's.
    ///
    /// This is the argument that makes a dark-mode review possible at all on a shared machine: it
    /// changes *this process only*, so the reviewer's other windows, and the rest of their evening,
    /// stay as they were.
    public static var appearance: NSAppearance? {
        guard isDevelopmentMode,
              let name = appearanceName(in: ProcessInfo.processInfo.arguments)
        else { return nil }
        return NSAppearance(named: name)
    }

    static func appearanceName(in arguments: [String]) -> NSAppearance.Name? {
        guard let raw = value(for: "-ElephruitAppearance", in: arguments)?.lowercased() else {
            return nil
        }

        switch raw {
        case "dark": return .darkAqua
        case "light": return .aqua
        default:
            Diagnostics.shell.error("Unknown -ElephruitAppearance \(raw, privacy: .public)")
            return nil
        }
    }

    /// The size to force the main window to, as `WIDTHxHEIGHT` in points.
    ///
    /// Responsive behaviour is a stated requirement of this interface and the hardest thing to
    /// check by hand, because it means dragging a window to a series of widths and remembering what
    /// each one looked like. Naming the width makes a narrow-window review a repeatable thing
    /// rather than an approximate one.
    public static var windowSize: CGSize? {
        guard isDevelopmentMode else { return nil }
        return windowSize(in: ProcessInfo.processInfo.arguments)
    }

    static func windowSize(in arguments: [String]) -> CGSize? {
        guard let raw = value(for: "-ElephruitWindowSize", in: arguments) else { return nil }

        let parts = raw.lowercased().split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              width > 0, height > 0
        else {
            Diagnostics.shell.error("Unreadable -ElephruitWindowSize \(raw, privacy: .public)")
            return nil
        }
        return CGSize(width: width, height: height)
    }

    /// Whether the sample library should be planted at launch, into an empty library.
    ///
    /// The fixture store persists between runs, so a library seeded by some earlier session is the
    /// normal state — and it carries whatever the *build of that session* wrote. That is not a
    /// theoretical hazard: this audit initially recorded a `promise` tag as a live defect, when the
    /// source had already been changed to write `follow-up` and the tag was simply left over in a
    /// store planted before the change. A review that cannot re-plant the library from the build in
    /// front of it is a review that reports the last build's bugs.
    public static var loadsSampleData: Bool {
        isDevelopmentMode
            && ProcessInfo.processInfo.arguments.contains("-ElephruitLoadSampleData")
    }

    /// How many people the library should hold, for a performance review.
    public static var peopleCount: Int? {
        guard isDevelopmentMode else { return nil }
        return peopleCount(in: ProcessInfo.processInfo.arguments)
    }

    static func peopleCount(in arguments: [String]) -> Int? {
        guard let raw = value(for: "-ElephruitPeopleCount", in: arguments) else { return nil }
        guard let count = Int(raw), count > 0 else {
            Diagnostics.shell.error("Unreadable -ElephruitPeopleCount \(raw, privacy: .public)")
            return nil
        }
        return count
    }

    /// Applies the appearance override, if one was asked for.
    ///
    /// Called once, as early as there is an `NSApplication` to set it on. Setting
    /// `NSApp.appearance` rather than each window's means sheets, popovers, menus and the settings
    /// window all follow — and those are precisely the surfaces a dark-mode review would otherwise
    /// miss, because they are the ones that are hardest to get on screen at the right moment.
    @MainActor
    public static func applyAppearance() {
        guard let appearance else { return }
        NSApplication.shared.appearance = appearance
        Diagnostics.shell.info("Design review appearance forced to \(appearance.name.rawValue, privacy: .public)")
    }

    /// Applies the start override to a freshly restored window.
    ///
    /// Runs *after* scene restoration rather than instead of it, so that the ordinary path is
    /// unchanged and this is visibly an override rather than a second restoration mechanism.
    @MainActor
    public static func applyStart(to navigation: NavigationModel) {
        guard let start else { return }
        switch start {
        case .module(let module): navigation.enterModule(module)
        case .destination(let selection):
            navigation.leaveModule()
            navigation.select(selection)
        }
    }

    /// The person whose profile the window should open on, by name.
    ///
    /// A profile is the densest screen in this app and the one the People module exists for, and it
    /// is unreachable without selecting somebody — which needs a click. So on a locked machine it
    /// could not be photographed at all, and this pass reviewed it by reading it.
    static func selectedPersonName(in arguments: [String]) -> String? {
        value(for: "-ElephruitSelectPerson", in: arguments)
    }

    /// Selects the named person, if one was asked for and one matches.
    ///
    /// Matched on a prefix, case-insensitively, so `-ElephruitSelectPerson Maya` is enough and the
    /// argument does not have to carry a full name through a shell. A name matching nobody selects
    /// nobody rather than selecting the first person in the library: a review that silently
    /// photographs the wrong profile is worse than one that photographs an empty pane.
    @MainActor
    public static func applySelection(to navigation: NavigationModel, using services: AppServices?) {
        guard isDevelopmentMode,
              let name = selectedPersonName(in: ProcessInfo.processInfo.arguments)?.lowercased(),
              let services
        else { return }

        var query = ItemQuery()
        query.kinds = [.person]
        guard let people = try? services.items.items(matching: query) else { return }

        guard let match = people.first(where: { $0.title.lowercased().hasPrefix(name) }) else {
            Diagnostics.shell.error("No person matching \(name, privacy: .public)")
            return
        }

        navigation.selectItem(match.id)
    }

    /// Applies the window-size override to whichever window is showing the library.
    ///
    /// Applied to the window rather than through `.defaultSize`, because a default is only consulted
    /// for a window the system has no saved frame for, and this machine has a saved frame.
    @MainActor
    public static func applyWindowSize(to window: NSWindow?) {
        guard let windowSize, let window else { return }
        var frame = window.frame
        // Anchored at the top-left, because a window grown from its bottom-left corner walks up the
        // screen and eventually under the menu bar across a series of sizes.
        frame.origin.y += frame.height - windowSize.height
        frame.size = windowSize
        window.setFrame(frame, display: true)
    }
}
