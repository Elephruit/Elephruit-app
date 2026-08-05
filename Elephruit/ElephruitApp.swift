import AppKit
import ElephruitCore
import ElephruitDesign
import ElephruitFeatures
import ElephruitModel
import ElephruitPersistence
import ElephruitSearch
import SafariServices
import SwiftUI

/// The application.
///
/// Deliberately thin: it opens the store, puts the services in the environment, declares the scenes,
/// and wires the menu bar. Every behaviour lives in a module — see `docs/02-architecture.md`.
@main
struct ElephruitApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup("Elephruit", id: "main") {
            RootWindow(environment: environment)
        }
        .defaultSize(width: 1180, height: 760)
        // Restoring per-window layout is scene state, which SwiftUI persists for us; the library
        // itself is never restored from here.
        .windowToolbarStyle(.unified)
        .commands {
            ElephruitCommands(services: environment.services)
        }

        // The menu bar timer.
        //
        // A timer runs while you are doing something *else*, usually in another app. One you can
        // only see by switching to Elephruit is one you forget is running, and a forgotten timer is
        // how eleven hours end up billed to a task that took two.
        //
        // `.window` style rather than `.menu` so the elapsed time can be a live label rather than a
        // static icon.
        MenuBarExtra {
            if case .ready(let services) = environment.state {
                TimerMenuBarContent(services: services) { environment.quickJot?.show() }
            } else {
                Text("Opening your library…")
            }
        } label: {
            if case .ready(let services) = environment.state {
                TimerMenuBarLabel(services: services)
            } else {
                Label("Elephruit", systemImage: "timer")
            }
        }
        // The style the comment above always promised: `.window` is what lets the content be a
        // live view rather than a static menu. It was documented and never applied.
        .menuBarExtraStyle(.window)

        // The calendar's menu bar item.
        //
        // A second extra rather than a section inside the timer's, because the two answer different
        // questions and are wanted at different moments: the timer is about what you are doing now,
        // and this is about what is next. Merging them would mean a label that has to choose which
        // to show, and it would be wrong half the time.
        MenuBarExtra {
            if case .ready(let services) = environment.state {
                CalendarMenuBarContent(
                    services: services,
                    onOpenCalendar: { environment.openCalendar() },
                    onQuickEntry: { environment.openCalendarQuickEntry() }
                )
            } else {
                Text("Opening your library…")
            }
        } label: {
            if case .ready(let services) = environment.state {
                CalendarMenuBarLabel(services: services)
            } else {
                Label("Calendar", systemImage: "calendar")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(environment: environment)
        }
    }
}

/// One window's contents, including the states before the library is available.
private struct RootWindow: View {
    let environment: AppEnvironment

    var body: some View {
        Group {
            switch environment.state {
            case .opening:
                // Deliberately quiet. Opening a local store takes milliseconds; a prominent spinner
                // would flash and draw the eye for no reason.
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.Colors.windowBackground)
                    .accessibilityLabel("Opening your library")

            case .ready(let services):
                RootView(
                    pendingCalendarRequest: environment.pendingCalendarRequest,
                    onCalendarRequestHandled: { environment.clearCalendarRequest() }
                )
                .appServices(services)
                .environment(\.prefersMonospacedEditor, prefersMonospacedEditor)

            case .failed(let error):
                FailureStateView(error: error) { option in
                    handleRecovery(option, error: error)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 520)
        .task {
            if case .opening = environment.state {
                environment.start()
            }
            // Anything an intent left behind while the app was not running, or not frontmost.
            environment.adoptIntentRouting()

            // Development-only review overrides. Both are no-ops unless the matching argument was
            // passed alongside `-ElephruitDevelopmentMode`; see ``DesignReviewLaunch``.
            DesignReviewLaunch.applyAppearance()
            DesignReviewLaunch.applyWindowSize(
                to: NSApplication.shared.windows.first { $0.canBecomeMain && $0.isVisible }
            )
        }
    }

    /// A lightweight preference, so `@AppStorage` is the right home — see the storage matrix.
    @AppStorage("prefersMonospacedEditor") private var prefersMonospacedEditor = false

    private func handleRecovery(_ option: RecoveryOption, error: AppError) {
        switch option {
        case .retry:
            environment.start()

        case .revealLibraryInFinder:
            if let location = try? StoreLocation.application() {
                NSWorkspace.shared.activateFileViewerSelecting([location.root])
            }

        case .revealBackupInFinder:
            if let location = try? StoreLocation.application() {
                NSWorkspace.shared.activateFileViewerSelecting([location.backupsRoot])
            }

        case .quit:
            NSApplication.shared.terminate(nil)

        default:
            break
        }
    }
}

// MARK: - Menu bar

/// The menu bar.
///
/// Every command here is a real menu item with a real shortcut, because that is how a Mac app is
/// discoverable and how the shortcuts show up in Help. The command palette offers the same actions;
/// neither is the only route to anything.
///
/// Commands act on the *focused* window through `@FocusedValue`, so a shortcut in one window never
/// moves another.
struct ElephruitCommands: Commands {
    @FocusedValue(\.navigationModel) private var navigation
    @FocusedValue(\.transferActions) private var transfer
    @FocusedValue(\.rowActions) private var rowActions
    @FocusedValue(\.workItemActions) private var workItem
    @FocusedValue(\.newItemCommand) private var newItem
    @FocusedValue(\.noteEditor) private var noteEditor

    @Environment(\.openWindow) private var openWindow

    /// The services, for the few commands that act on the app rather than on a window.
    ///
    /// Switching Calendar Set is one: which calendars are showing is a property of the app's
    /// calendar rather than of a particular window, and two windows showing two different sets would
    /// be two answers to a question with one.
    let services: AppServices?

    /// The bindings, from the one place that decides them.
    ///
    /// Read from preferences rather than held, because `Commands` is a value rebuilt on change and
    /// has no services in its environment. The registry is small and the read is rare — a menu is
    /// not rebuilt on a keystroke.
    private var shortcuts: ShortcutRegistry { ShortcutRegistry.load(from: .standard) }

    var body: some Commands {
        // MARK: File

        CommandGroup(replacing: .newItem) {
            // The focused surface says what creating means there — a reminder in Reminders, a note
            // in Notes — and the menu owns the key. The two toolbar buttons that used to bind ⌘N
            // behind the registry's back are wired through this instead.
            Button(newItem?.title ?? "New Note") {
                if let newItem {
                    newItem.run()
                } else {
                    create(.note)
                }
            }
            .shortcut(.newItem, in: shortcuts)

            Button("New Reminder") { navigation?.requestNewReminder() }
                .shortcut(.newReminder, in: shortcuts)

            Button("New Project") { create(.project) }
                .shortcut(.newProject, in: shortcuts)

            Divider()

            Button("Quick Jot…") { navigation?.isQuickCaptureVisible = true }
                .shortcut(.quickCapture, in: shortcuts)

            Button("New Event…") {
                navigation?.select(.calendar)
                navigation?.isCalendarQuickEntryVisible = true
            }
            .shortcut(.newEvent, in: shortcuts)
            .disabled(navigation == nil)

            Button("Quick Reminder…") { navigation?.requestNewReminder() }
                .shortcut(.quickReminderEntry, in: shortcuts)

            // The same panel the global shortcut opens, rather than a second in-window route to the
            // same act. Quick Jot has two doors because a sheet is genuinely better than a floating
            // panel when the app is already in front of you; a timer has no such asymmetry — it is
            // one window, one clock, and the Time module already holds the full version of it.
            Button("Quick Log…") { services?.quickLog.show() }
                .shortcut(.quickLog, in: shortcuts)
                .disabled(services == nil)

            Divider()

            // A new window is genuinely useful in this app — two projects side by side — so it is a
            // first-class command rather than something the user has to discover. Through the
            // scene action, not a URL: this used to open `everything://main`, a scheme the
            // Info.plist never registered, behind a `.disabled(true)` — a menu item that was
            // wrong twice and pressable zero times.
            Button("New Window") { openWindow(id: "main") }
                .shortcut(.newWindow, in: shortcuts)
        }

        CommandGroup(after: .newItem) {
            Divider()

            Button("Import Files…") { transfer?.importFiles() }
                .shortcut(.importFiles, in: shortcuts)
                .disabled(transfer == nil)

            Button("Export Library…") { transfer?.export() }
                .shortcut(.exportLibrary, in: shortcuts)
                .disabled(transfer == nil)
        }

        // MARK: Edit

        CommandGroup(after: .pasteboard) {
            Divider()

            // Disabled from milestone one, which meant ⌘⌫ was printed in a menu and did nothing
            // in lists where ⌫ already worked. Each middle column publishes what deleting means
            // there, and this calls it.
            Button("Move to Trash") { rowActions?.moveToTrash() }
                .shortcut(.moveToTrash, in: shortcuts)
                .disabled(rowActions?.isEnabled != true)

            Divider()

            // The three work-item verbs the registry has carried since the module shipped — bound,
            // shown in Settings, and wired to nothing until the surfaces below published what they
            // mean. The focused surface decides; the menu only carries the keys.
            Button("Mark Complete") { workItem?.complete() }
                .shortcut(.completeReminder, in: shortcuts)
                .disabled(workItem?.isEnabled != true)

            Button(workItem?.isFlagged == true ? "Unflag" : "Flag") { workItem?.toggleFlag() }
                .shortcut(.flagReminder, in: shortcuts)
                .disabled(workItem?.isEnabled != true)

            Button("Move to Today") { workItem?.moveToToday() }
                .shortcut(.moveToToday, in: shortcuts)
                .disabled(workItem?.isEnabled != true)
        }

        // MARK: Find

        CommandGroup(replacing: .textEditing) {
            // ⌘F, and the focused context wins: with a note open the key finds *in the note* —
            // Mail's rule, where ⌘F searches the message being read — and everywhere else it is
            // the app-wide search it has always been. One key, titled for what it will do.
            Button(noteEditor != nil ? "Find in Note" : "Search Everything") {
                if let noteEditor {
                    noteEditor.showFindBar()
                } else {
                    navigation?.beginSearch()
                }
            }
            .shortcut(.search, in: shortcuts)
            .disabled(navigation == nil)

            Button("Command Palette…") { navigation?.isCommandPaletteVisible = true }
                .shortcut(.commandPalette, in: shortcuts)
                .disabled(navigation == nil)

            Button("Search Calendar") {
                navigation?.select(.calendar)
                navigation?.isCalendarSearchVisible = true
            }
            .shortcut(.searchCalendar, in: shortcuts)
            .disabled(navigation == nil)

            // The natural-language command bar for records. Its binding existed in the registry
            // and in Settings from the day it shipped, and fired nothing — reachable only by name
            // inside the other palette.
            Button("Records Command Bar…") { navigation?.isRecordsCommandBarVisible = true }
                .shortcut(.recordsCommandBar, in: shortcuts)
                .disabled(navigation == nil)
        }

        // MARK: View

        CommandGroup(after: .sidebar) {
            Divider()

            // A keyboard way in and out, because the buttons themselves are revealed on hover and a
            // control you can only reach with a pointer is one a keyboard user cannot reach at all.
            if services?.miniTimer.isCollapsed == true {
                Button("Back to Elephruit") { services?.miniTimer.expand() }
                    .shortcut(.collapseToTimer, in: shortcuts)
            } else {
                Button("Collapse to Timer") { services?.miniTimer.collapse() }
                    .shortcut(.collapseToTimer, in: shortcuts)
                    .disabled(services == nil)
            }

            Divider()

            // ⌃⌘T finally does what its name says, on the thing you have selected. It started an
            // *untitled* timer from the palette — there was no keyboard route to "time this".
            Button("Start or Stop Timer") {
                guard let services else { return }
                if services.timer.isRunning {
                    services.timer.stop()
                } else if let id = navigation?.selectedItemID,
                          let item = try? services.items.item(id: id) {
                    services.timer.switchTo(item: item)
                } else {
                    services.timer.switchTo(item: nil)
                }
            }
            .shortcut(.toggleTimer, in: shortcuts)
            .disabled(services == nil)

            Divider()

            Button("Back") { navigation?.goBack() }
                .shortcut(.goBack, in: shortcuts)
                .disabled(navigation?.canGoBack != true)

            Button("Forward") { navigation?.goForward() }
                .shortcut(.goForward, in: shortcuts)
                .disabled(navigation?.canGoForward != true)

            Divider()

            // The two destinations that belong to no module, in sidebar order. Both go through the
            // registry — nothing here is allowed to bind keys behind its back, because a binding
            // whose name and effect disagree is worse than no binding, and `ShortcutRegistry` gives
            // every shortcut exactly one owner so that a collision fails a test rather than
            // silently shadowing another menu item.
            Button("Today") { navigation?.select(.today) }
                .shortcut(.goToday, in: shortcuts)
            Button("Inbox") { navigation?.select(.inbox) }
                .shortcut(.goInbox, in: shortcuts)

            // Projects is not a module — the tree lives at the top level of the sidebar — so its
            // shortcut lives here with the other top-level destinations rather than in the Module
            // menu below, whose loop iterates `displayOrder` and rightly never sees it.
            Button("All Projects") { navigation?.select(.kind(.project)) }
                .shortcut(.goProjects, in: shortcuts)

            Divider()

            // Every module, in the order the sidebar lists them. This is the keyboard route into a
            // module: the module rows themselves are buttons rather than selectable list rows, so
            // that arrowing through the sidebar cannot enter one by accident.
            Menu("Module") {
                ForEach(AppModule.displayOrder) { module in
                    moduleButton(module)
                }

                Divider()

                Button("Back to All Modules") { navigation?.leaveModule() }
                    .disabled(navigation?.activeModule == nil)
            }

            Divider()

            Button("Next Calendar Set") {
                guard let calendar = services?.calendar else { return }
                let next = calendar.setAfterActive()
                Task { await calendar.activate(setID: next?.id) }
            }
            .shortcut(.switchCalendarSet, in: shortcuts)
            .disabled(services == nil)

            Divider()

            Button("Toggle Sidebar") { navigation?.toggleSidebar() }
                .shortcut(.toggleSidebar, in: shortcuts)
                .disabled(navigation == nil)

            Button("Toggle Inspector") { navigation?.isInspectorVisible.toggle() }
                .shortcut(.toggleInspectorAlternate, in: shortcuts)
                .disabled(navigation == nil)

            Button(navigation?.layoutMode == .focus ? "Leave Focus Mode" : "Focus Mode") {
                navigation?.toggleFocusMode()
            }
            .shortcut(.focusMode, in: shortcuts)
            .disabled(navigation == nil)

            Divider()

            Button("Focus Sidebar") { navigation?.focus(.sidebar) }
                .shortcut(.clearSelection, in: shortcuts)
                .disabled(navigation == nil)
        }

        // MARK: Format

        // The menu a rich-text editor owes the menu bar: every operation the in-window Format
        // popover offers was reachable only by mouse, and none appeared where macOS users look
        // for formatting. Enabled exactly while a note's editor is open.
        CommandMenu("Format") {
            Button("Bold") { noteEditor?.toggleInlineMark(.bold) }
                .keyboardShortcut("b")
                .disabled(noteEditor == nil)
            Button("Italic") { noteEditor?.toggleInlineMark(.italic) }
                .keyboardShortcut("i")
                .disabled(noteEditor == nil)
            Button("Strikethrough") { noteEditor?.toggleInlineMark(.strikethrough) }
                .disabled(noteEditor == nil)
            Button("Code") { noteEditor?.toggleInlineMark(.code) }
                .disabled(noteEditor == nil)

            Divider()

            Menu("Paragraph") {
                Button("Body") { noteEditor?.applyParagraph(.paragraph) }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                Button("Heading 1") { noteEditor?.applyParagraph(.heading1) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Heading 2") { noteEditor?.applyParagraph(.heading2) }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button("Heading 3") { noteEditor?.applyParagraph(.heading3) }
                    .keyboardShortcut("3", modifiers: [.command, .option])
                Divider()
                Button("Quote") { noteEditor?.applyParagraph(.quote) }
                Button("Code Block") { noteEditor?.applyParagraph(.code) }
            }
            .disabled(noteEditor == nil)

            Menu("Lists") {
                // Apple Notes' own keys, because fingers already know them.
                Button("Numbered List") { noteEditor?.applyParagraph(.numbered) }
                    .keyboardShortcut("7", modifiers: [.command, .shift])
                Button("Bulleted List") { noteEditor?.applyParagraph(.bulleted) }
                    .keyboardShortcut("8", modifiers: [.command, .shift])
                Button("Checklist") { noteEditor?.applyParagraph(.checklist) }
                    .keyboardShortcut("9", modifiers: [.command, .shift])
            }
            .disabled(noteEditor == nil)
        }

        // MARK: Help

        CommandGroup(replacing: .help) {
            // A Help menu whose only item is permanently disabled is worse than no Help menu:
            // it also removed the system's Help search field, which is how macOS users discover
            // menu commands. The documentation genuinely lives in the repository, and the app's
            // no-network entitlement is about the *app* — the link opens in the browser.
            Link(
                "Elephruit Documentation",
                destination: URL(string: "https://github.com/Elephruit/Elephruit-app/tree/main/docs")!
            )
        }
    }

    /// One module's menu item, carrying the named shortcut where the registry has one for it.
    ///
    /// Only four modules have a binding of their own, and inventing six more would be inventing six
    /// claims on keys the user may already have spent. The rest are reachable by name here, in the
    /// palette, and by clicking.
    @ViewBuilder
    private func moduleButton(_ module: AppModule) -> some View {
        let command: ShortcutCommand? = switch module {
        case .calendar: .goCalendar
        case .reminders: .goReminders
        case .notes: .goNotes
        case .records: .goRecords
        case .time: .goTime
        default: nil
        }

        Button {
            navigation?.enterModule(module)
        } label: {
            Label(module.title, systemImage: module.symbolName)
        }
        .shortcut(command, in: shortcuts)
        .disabled(navigation == nil)
    }

    private func create(_ kind: ItemKind) {
        guard let navigation else { return }
        navigation.select(.kind(kind))
        // The list's own new-item action creates in context; this puts the user where it will land.
        navigation.isQuickCaptureVisible = false
    }
}

// MARK: - Settings

/// Preferences.
///
/// Only genuine preferences live here. Anything that is user *content* belongs in the library, and
/// anything derived belongs in a cache — see `docs/03-storage-matrix.md`.
///
/// ### Why this is a source list rather than five tabs across the top
/// Because it stopped being five. A row of tabs is the right shape while every one of them fits on
/// one line and each holds a handful of switches; past that the labels shorten until they stop
/// saying what is behind them, and a setting somebody is hunting for is behind whichever one they
/// have not tried yet. A list down the side names all nine at their full length, holds any number
/// more, and is what every settings window on this system has looked like since Ventura.
///
/// The reorganisation is not only cosmetic. Keyboard shortcuts were a section *inside* General's
/// Calendar group, which is not somewhere anybody would think to look for them; they now have their
/// own place. Everything time tracking can be told is in one place rather than scattered between a
/// toolbar, a menu, and nowhere.
struct SettingsView: View {
    let environment: AppEnvironment

    @AppStorage("confirmBeforeEmptyingTrash") private var confirmBeforeEmptyingTrash = true
    @AppStorage("people.showsFollowUps") private var showsFollowUpSuggestions = false
    @AppStorage("people.followUpThresholdDays") private var followUpThresholdDays = 0

    @State private var indexStatistics: (items: Int, terms: Int, isWarm: Bool)?
    @State private var clipperSettingsError: String?
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                general.accessibilityIdentifier(AccessibilityID.Settings.generalTab)
            }

            Tab("Appearance", systemImage: "paintpalette") {
                Form { AppearanceSettingsSection() }
                    .formStyle(.grouped)
                    .accessibilityIdentifier(AccessibilityID.Settings.editorTab)
            }

            Tab("Time", systemImage: "timer") {
                whenReady { services in
                    TimeSettingsSection().appServices(services)
                }
                .accessibilityIdentifier(AccessibilityID.Settings.timeTab)
            }

            Tab("Reminders", systemImage: "bell") {
                whenReady { services in
                    RemindersSettingsSection().appServices(services)
                }
                .accessibilityIdentifier("settings.reminders")
            }

            Tab("Calendar", systemImage: "calendar") {
                whenReady { services in
                    CalendarPreferencesSection(services: services)
                }
                .accessibilityIdentifier(AccessibilityID.Settings.calendarTab)
            }

            Tab("Records", systemImage: "person.text.rectangle") {
                records.accessibilityIdentifier(AccessibilityID.Records.contactsSettings)
            }

            Tab("Shortcuts", systemImage: "keyboard") {
                whenReady { services in
                    ShortcutSettingsSection(
                        services: services,
                        globalResults: environment.hotKeyResults
                    )
                }
                .accessibilityIdentifier(AccessibilityID.Settings.shortcutsTab)
            }

            Tab("Web Clipper", systemImage: "safari") {
                webClipper
            }

            trailingTabs
        }
        .tabViewStyle(.sidebarAdaptable)
        .frame(width: 720, height: 520)
        .accessibilityIdentifier(AccessibilityID.Settings.root)
    }

    /// The last three tabs, folded through one builder property.
    ///
    /// Not an organisational statement — the result builder counts statements, eleven tabs
    /// exceeded its arity, and this property makes three of them count as one. The window
    /// looks exactly as it would if they were inline.
    @TabContentBuilder<Never>
    private var trailingTabs: some TabContent<Never> {
        Tab("Sync", systemImage: "arrow.triangle.2.circlepath.icloud") {
            SyncSettingsSection()
        }

        Tab("Privacy", systemImage: "lock.shield") {
            privacy.accessibilityIdentifier(AccessibilityID.Settings.privacyTab)
        }

        Tab("Advanced", systemImage: "wrench.and.screwdriver") {
            advanced.accessibilityIdentifier(AccessibilityID.Settings.advancedTab)
        }
    }

    /// A form whose contents need the library, and which says so plainly when it is not open yet.
    ///
    /// One helper rather than the same `if case .ready` at six call sites — which is where a tab
    /// added later quietly crashes a window opened during a migration.
    @ViewBuilder
    private func whenReady<Content: View>(
        @ViewBuilder _ content: @escaping (AppServices) -> Content
    ) -> some View {
        Form {
            if case .ready(let services) = environment.state {
                content(services)
            } else {
                Text("Available once your library is open.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
        }
        .formStyle(.grouped)
    }

    /// Managing the address book connection.
    ///
    /// Its own tab rather than a section under General, because it is the one integration with an
    /// ongoing state — linked counts, a last-refresh time, conflicts awaiting a decision — and burying
    /// that under a Trash preference would make it undiscoverable at exactly the moment somebody goes
    /// looking for why a phone number is out of date.
    private var records: some View {
        Form {
            if case .ready(let services) = environment.state {
                ContactsSettingsSection()
                    .appServices(services)

                Section {
                    Toggle("Suggest people to follow up with", isOn: $showsFollowUpSuggestions)

                    if showsFollowUpSuggestions {
                        Stepper(
                            "After \(effectiveFollowUpDays) days without contact",
                            value: followUpThresholdBinding,
                            in: 7...365,
                            step: 7
                        )
                    }
                } header: {
                    Text("Follow-ups")
                } footer: {
                    Text("Off by default. An app that starts telling you who you have neglected, unprompted, is a different and worse product than one that answers when asked.")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Available once your library is open.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
        }
        .formStyle(.grouped)
    }

    private var effectiveFollowUpDays: Int {
        followUpThresholdDays > 0 ? followUpThresholdDays : FollowUpPolicy.defaultThresholdDays
    }

    private var followUpThresholdBinding: Binding<Int> {
        Binding(get: { effectiveFollowUpDays }, set: { followUpThresholdDays = $0 })
    }

    private var general: some View {
        Form {
            Section {
                Toggle("Ask before emptying the Trash", isOn: $confirmBeforeEmptyingTrash)
            } footer: {
                Text("Emptying the Trash cannot be undone.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
        }
        .formStyle(.grouped)
    }

    /// What the app does and does not do with anything it can reach.
    ///
    /// Its own tab rather than a paragraph at the bottom of General. It is the claim this whole app
    /// is built around, it is the thing somebody checks before trusting it with a decade of notes,
    /// and a privacy claim buried under a Trash preference is too easy to miss.
    ///
    /// ### What was wrong with the old headline
    /// It said "This app makes no network requests", under a paragraph ending "iCloud sync is not
    /// enabled in this version". Both outlived their truth: sync shipped with a switch of its own
    /// and a whole tab beside this one, and `MapPlaceSearchField` reaches Apple Maps whenever
    /// somebody types a venue into a record. A headline that says *none* is worthless once there is
    /// one; a headline that names each one is still checkable by a reader, so that is what this is
    /// now. Two is a number somebody can hold in their head — the moment it stops being two, this
    /// screen has to change again, and that is the point of writing it as a count.
    private var privacy: some View {
        Form {
            Section {
                Label("Two things here can reach the network, and both are named below.", systemImage: "lock.shield")

                Text("Your library goes nowhere but your own private iCloud database, and only if you turn on sync. Searching for a place in a record asks Apple Maps, and sends only the words you typed. There is no account with us, no analytics, no telemetry, no crash reporting, and no third-party service.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("What each integration may do") {
                PrivacyRow(
                    symbolName: "person.2",
                    title: "Contacts",
                    detail: "Read only. Your notes, reflections, and relationship history are never put into a contact."
                )
                PrivacyRow(
                    symbolName: "calendar",
                    title: "Calendar",
                    detail: "Reads your events, and writes only the events you ask it to — including tracked time, if you turn that on. What you record *about* a meeting stays here."
                )
                PrivacyRow(
                    symbolName: "checklist",
                    title: "Reminders",
                    detail: "Reads and writes the lists you tick. Areas, projects, Today, waiting-for, linked people, and provenance never cross."
                )
                PrivacyRow(
                    symbolName: "safari",
                    title: "Web Clipper",
                    detail: "Reads only the Safari tab where you open the clipper. The page travels through a private on-device inbox and is never uploaded."
                )
                // Last, because it is the only one here that sends something out rather than
                // reading something already on this Mac — and the only one with nothing to turn
                // off, which is the part a row indistinguishable from Contacts' would hide.
                PrivacyRow(
                    symbolName: "map",
                    title: "Apple Maps",
                    detail: "Asked when you type into a record's place field, and sent only the words you typed — never a note, never who the record is about. It has no switch: it happens while you are searching, and at no other moment."
                )
            }
        }
        .formStyle(.grouped)
    }

    private var webClipper: some View {
        Form {
            Section {
                LabeledContent("Safari extension") {
                    HStack(spacing: Theme.Spacing.tight) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                        Text("Included")
                    }
                }

                Button("Open Safari Extension Settings") {
                    openSafariExtensionSettings()
                }
            } header: {
                Text("Elephruit Web Clipper")
            } footer: {
                Text("In Safari, pin Elephruit to the toolbar. Open it on any page to keep an article, selection, full page, bookmark, or visible-page screenshot.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("What gets saved") {
                Label("Readable Markdown for search and editing", systemImage: "text.document")
                Label("Cleaned HTML for a faithful source snapshot", systemImage: "doc.richtext")
                Label("Original URL, author, site, tags, and your note", systemImage: "link")
                Label("Screenshots as managed local attachments", systemImage: "camera.viewfinder")
            }

            Section {
                Label("Nothing is uploaded", systemImage: "lock.shield")
                Text("Safari hands the clip directly to Elephruit through a private app-group container on this Mac. No account or web service is involved.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .alert(
            "Couldn’t Open Safari Extension Settings",
            isPresented: Binding(
                get: { clipperSettingsError != nil },
                set: { if !$0 { clipperSettingsError = nil } }
            )
        ) {
            Button("OK") { clipperSettingsError = nil }
        } message: {
            Text(clipperSettingsError ?? "")
        }
    }

    private func openSafariExtensionSettings() {
        // Do not probe `SFSafariExtensionManager` here. SafariServices marks its state callback as
        // UI-actor isolated but currently invokes it on an ExtensionHelper XPC queue, which trips
        // Swift 6's executor check. Opening Safari's settings is reliable and remains authoritative.
        Task {
            do {
                try await SFSafariApplication.showPreferencesForExtension(
                    withIdentifier: "com.elephruit.Elephruit.Clipper"
                )
            } catch {
                clipperSettingsError = "Safari could not find the Elephruit extension. The app and extension must be signed by the same development team before Safari can enable it.\n\n\(error.localizedDescription)"
            }
        }
    }

    private var advanced: some View {
        Form {
            // A string title and a footer are not combinable in one `Section` initialiser, so the
            // header is spelled out.
            Section {
                if let statistics = indexStatistics {
                    LabeledContent("Indexed items", value: "\(statistics.items)")
                    LabeledContent("Distinct terms", value: "\(statistics.terms)")
                    LabeledContent("State", value: statistics.isWarm ? "Ready" : "Building")
                }

                Button("Rebuild Search Index") { rebuildIndex() }
                    .accessibilityIdentifier(AccessibilityID.Settings.rebuildIndexButton)
            } header: {
                Text("Search Index")
            } footer: {
                Text("The index is a cache built from your library. Rebuilding it cannot lose data.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            Section("Library") {
                LabeledContent("Schema version", value: schemaVersion)
                Button("Reveal Library in Finder") { revealLibrary() }
            }

            if environment.services?.isDevelopmentMode == true {
                Section("Development") {
                    Button("Load Sample Data") { environment.services?.loadSampleData() }
                    Text("Only available in development mode.")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }
        }
        .formStyle(.grouped)
        .task { await refreshStatistics() }
    }

    private var schemaVersion: String {
        CurrentSchema.versionString
    }

    private func rebuildIndex() {
        guard let services = environment.services else { return }
        Task {
            await services.search.invalidateIndex()
            await services.warmSearchIndex()
            await refreshStatistics()
        }
    }

    private func refreshStatistics() async {
        guard let search = environment.services?.search else { return }
        indexStatistics = await search.indexStatistics()
    }

    private func revealLibrary() {
        guard let location = try? StoreLocation.application() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([location.root])
    }
}

/// One integration, and the shape of what it may do.
///
/// A row rather than a paragraph, because the question people arrive with is *which* of these
/// touches my data and in which direction — and three sentences of prose answers that only for
/// somebody who reads all three.
private struct PrivacyRow: View {
    let symbolName: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Image(systemName: symbolName)
                .frame(width: Theme.Size.rowGlyph)
                .foregroundStyle(Theme.Colors.secondaryText)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Text.rowTitleEmphasised)

                Text(detail)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
