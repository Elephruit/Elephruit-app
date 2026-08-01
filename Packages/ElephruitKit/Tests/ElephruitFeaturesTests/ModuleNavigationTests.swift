import ElephruitCore
import ElephruitFeatures
import Foundation
import Testing

/// The module hierarchy: what the top level holds, what entering one does, and what survives a
/// relaunch.
///
/// The rule these all circle is that a module owns no destinations. It names a slice of
/// ``SidebarSelection``, and the inverse — `AppModule.module(for:)` — is what lets a deep link, a
/// menu command and a restored scene put somebody in the right module without their author having
/// remembered to say so. Every test here is a way that could stop being true.
@MainActor
@Suite("Module navigation")
struct ModuleNavigationTests {
    // MARK: - The primary level

    @Test("The primary navigation is Today then Inbox, and nothing else")
    func globalDestinationsAreOrdered() {
        #expect(GlobalDestination.allCases == [.today, .inbox])
        #expect(GlobalDestination.allCases.map(\.selection) == [.today, .inbox])
    }

    @Test("Home and Upcoming still resolve, and resolve to Today")
    func supersededDestinationsRedirect() {
        // The guarantee this pins down is not about the sidebar; it is about everything that stored
        // one of these names before they were joined — a scene string, a restored window, a launch
        // argument, somebody's muscle memory in the menu bar.
        #expect(SidebarSelection.home.canonical == .today)
        #expect(SidebarSelection.upcoming.canonical == .today)
        #expect(SidebarSelection.today.canonical == .today)
        #expect(SidebarSelection.home.isSuperseded)
        #expect(!SidebarSelection.today.isSuperseded)

        #expect(GlobalDestination.contains(.home))
        #expect(GlobalDestination.contains(.upcoming))

        let navigation = NavigationModel()
        navigation.select(.inbox)
        navigation.select(.home)
        #expect(navigation.selection == .today)
        navigation.select(.inbox)
        navigation.select(.upcoming)
        #expect(navigation.selection == .today)
    }

    @Test("A scene written before the merge restores onto Today")
    func restoringASupersededSceneLandsOnToday() {
        let navigation = NavigationModel()
        navigation.restore(NavigationModel.RestorationState(module: nil, selection: .upcoming))

        #expect(navigation.selection == .today)
        #expect(navigation.activeModule == nil, "Today belongs to no module")
    }

    @Test("The modules are listed in the order the design fixed")
    func modulesAreOrdered() {
        #expect(
            AppModule.displayOrder == [
                .calendar, .tasks, .people, .notes, .time,
                .projects, .areas, .bookmarks, .archive, .trash,
            ]
        )
    }

    @Test("No global destination belongs to a module, and no module claims one")
    func theTwoLevelsDoNotOverlap() {
        for destination in GlobalDestination.allCases {
            #expect(
                AppModule.module(for: destination.selection) == nil,
                "\(destination.rawValue) is both global and inside a module"
            )
        }

        for module in AppModule.displayOrder {
            #expect(
                !GlobalDestination.contains(module.defaultSelection),
                "\(module.title) opens on a global destination, which would be the old duplication"
            )
        }
    }

    @Test("Every module opens on a destination it can actually draw")
    func defaultSelectionsBelongToTheirModule() {
        for module in AppModule.displayOrder {
            #expect(
                module.contains(module.defaultSelection),
                "\(module.title) opens somewhere its own sidebar would not show"
            )
        }
    }

    @Test("The Tasks module keeps its own Today, Upcoming and Inbox")
    func tasksHasScopedVersionsOfTheGlobalRows() {
        // Not a duplication: the global Today is the whole day — work, meetings and the people they
        // involve — and the Tasks one is the list of work you planned. They are different questions
        // with the same name, which is exactly the case the rule about redundant rows carves out.
        #expect(AppModule.module(for: .taskView(.today)) == .tasks)
        #expect(AppModule.module(for: .taskView(.upcoming)) == .tasks)
        #expect(AppModule.module(for: .taskView(.inbox)) == .tasks)
        #expect(AppModule.module(for: .today) == nil)
    }

    // MARK: - Entering and leaving

    @Test("Entering a module selects its default and puts the sidebar inside it")
    func enteringSelectsTheDefault() {
        let navigation = NavigationModel()
        navigation.enterModule(.tasks)

        #expect(navigation.activeModule == .tasks)
        #expect(navigation.selection == .taskView(.today))
    }

    @Test("Selecting a module's destination enters that module, from anywhere")
    func selectingDerivesTheModule() {
        let navigation = NavigationModel()

        navigation.select(.people(.celebrations))
        #expect(navigation.activeModule == .people)

        // A deep link into the calendar, which is what an intent or a menu bar click produces.
        navigation.select(.calendar)
        #expect(navigation.activeModule == .calendar)

        navigation.select(.builtInSmartList(id: "anything"))
        #expect(navigation.activeModule == .tasks)
    }

    @Test("Selecting a global destination leaves whatever module you were in")
    func globalDestinationsLeaveTheModule() {
        let navigation = NavigationModel()
        navigation.enterModule(.notes)
        navigation.select(.inbox)

        #expect(navigation.activeModule == nil)
        #expect(navigation.selection == .inbox)
    }

    @Test("A tag opened inside a module keeps you in it")
    func ambiguousSelectionsKeepTheModule() {
        // A tag belongs to no module — it reaches across all of them — so the honest answer to
        // "which module is this" is "the one you were in". Guessing would eject somebody from
        // Notes for clicking a tag in the Notes sidebar.
        let navigation = NavigationModel()
        navigation.enterModule(.notes)
        navigation.select(.tag(slug: "reading"))

        #expect(navigation.activeModule == .notes)
        #expect(navigation.selection == .tag(slug: "reading"))
    }

    @Test("Leaving a module returns to a real main view")
    func leavingReturnsToToday() {
        let navigation = NavigationModel()
        navigation.enterModule(.people)
        navigation.select(.people(.favorites))
        navigation.leaveModule()

        #expect(navigation.activeModule == nil)
        #expect(navigation.selection == .today)
        navigation.goBack()
        #expect(navigation.activeModule == .people)
        #expect(navigation.selection == .people(.favorites))
    }

    @Test("Re-entering a module resumes where it was left")
    func modulesRememberWhereTheyWere() {
        let navigation = NavigationModel()
        navigation.enterModule(.tasks)
        navigation.select(.taskView(.someday))

        navigation.enterModule(.people)
        #expect(navigation.selection == .people(.all))

        navigation.enterModule(.tasks)
        #expect(navigation.selection == .taskView(.someday), "Tasks resumed rather than restarting")
    }

    @Test("Stepping back into the module you just left works")
    func reEnteringAfterLeavingWorks() {
        let navigation = NavigationModel()
        navigation.enterModule(.notes)
        navigation.leaveModule()
        navigation.enterModule(.notes)

        #expect(navigation.activeModule == .notes)
        #expect(navigation.selection == .kind(.note))
    }

    @Test("A remembered selection that stopped belonging to the module is dropped")
    func staleRememberedSelectionsFallBack() {
        let navigation = NavigationModel()
        navigation.enterModule(.tasks)
        navigation.select(.taskView(.waiting))
        navigation.leaveModule()

        // What a deleted smart list looks like from here: the module remembers a destination whose
        // module is no longer itself.
        navigation.restore(
            NavigationModel.RestorationState(
                module: nil,
                selection: .home,
                moduleSelections: [.tasks: .kind(.note)]
            )
        )
        navigation.enterModule(.tasks)

        #expect(navigation.selection == .taskView(.today), "Fell back rather than showing a note")
    }

    @Test("Entering a module clears the list selection")
    func enteringClearsTheItemSelection() {
        let navigation = NavigationModel()
        navigation.selectItem(UUID())
        navigation.enterModule(.bookmarks)

        #expect(navigation.selectedItemIDs.isEmpty)
        #expect(navigation.selectedItemID == nil)
    }

    // MARK: - Unsaved work

    @Test("Any navigation flushes a pending editor write first")
    func navigationFlushesPendingEdits() {
        let navigation = NavigationModel()
        var flushes = 0
        navigation.registerEditFlush(UUID()) { flushes += 1 }

        navigation.select(.kind(.note))
        #expect(flushes == 1)

        navigation.enterModule(.people)
        #expect(flushes == 2, "Switching module must not be the one navigation that loses a draft")

        navigation.select(.people(.favorites))
        #expect(flushes == 3)
    }

    @Test("An editor that has gone away is not asked to flush")
    func unregisteringStopsTheFlush() {
        let navigation = NavigationModel()
        let id = UUID()
        var flushes = 0
        navigation.registerEditFlush(id) { flushes += 1 }
        navigation.unregisterEditFlush(id)

        navigation.select(.kind(.note))
        #expect(flushes == 0)
    }

    // MARK: - Titles

    @Test("The window is named for the module at its front door, and the destination elsewhere")
    func windowTitleNamesWhereYouAre() {
        let navigation = NavigationModel()
        #expect(navigation.windowTitle == "Today")

        navigation.enterModule(.tasks)
        // "Today" here would be indistinguishable from the global one it is not.
        #expect(navigation.windowTitle == "Tasks")

        navigation.select(.taskView(.someday))
        #expect(navigation.windowTitle == "Someday")
    }

    // MARK: - Restoration

    @Test("A window comes back in the module and the destination it was left in")
    func restorationRoundTrips() {
        let navigation = NavigationModel()
        navigation.enterModule(.people)
        navigation.select(.people(.needsFollowUp))

        let encoded = navigation.restorationState.encoded
        #expect(encoded != nil)

        let restored = NavigationModel()
        restored.restore(NavigationModel.RestorationState(encoded: encoded ?? "") ?? .init(module: nil, selection: .today))

        #expect(restored.activeModule == .people)
        #expect(restored.selection == .people(.needsFollowUp))
    }

    @Test("A restored tag comes back inside the module it was being read in")
    func restorationKeepsTheModuleForAnAmbiguousSelection() {
        // The case the selection alone cannot carry: a tag belongs to no module, so without the
        // stored module the window would come back showing the primary navigation with a selection
        // that is not in it.
        let navigation = NavigationModel()
        navigation.enterModule(.notes)
        navigation.select(.tag(slug: "reading"))

        let restored = NavigationModel()
        restored.restore(navigation.restorationState)

        #expect(restored.activeModule == .notes)
        #expect(restored.selection == .tag(slug: "reading"))
    }

    @Test("Each module's own place survives the relaunch too")
    func restorationCarriesEveryModulesPlace() {
        let navigation = NavigationModel()
        navigation.enterModule(.tasks)
        navigation.select(.taskView(.flagged))
        navigation.enterModule(.people)
        navigation.select(.people(.favorites))

        let restored = NavigationModel()
        restored.restore(navigation.restorationState)
        restored.enterModule(.tasks)

        #expect(restored.selection == .taskView(.flagged))
    }

    @Test("A scene string that cannot be read is not a scene string")
    func garbageDoesNotDecode() {
        #expect(NavigationModel.RestorationState(encoded: "") == nil)
        #expect(NavigationModel.RestorationState(encoded: "{\"module\":\"telepathy\"}") == nil)
    }

    // MARK: - Deep links

    @Test("A calendar deep link enters the Calendar module")
    func calendarDeepLinkEntersTheModule() {
        // `RootView` acts on a pending request by selecting `.calendar`, and that is all it does.
        // The module follows from the selection, which is the property that keeps every other entry
        // point — intent, menu bar, URL — from having to remember this.
        let navigation = NavigationModel()
        navigation.enterModule(.notes)
        navigation.select(.calendar)

        #expect(navigation.activeModule == .calendar)
    }

    @Test("Quick task entry lands in the Tasks module's inbox")
    func taskEntryEntersTasks() {
        let navigation = NavigationModel()
        navigation.select(.taskView(.inbox))

        #expect(navigation.activeModule == .tasks)
        #expect(navigation.windowTitle == "Inbox")
    }
}
