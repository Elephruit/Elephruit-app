import ElephruitCore
import ElephruitFeatures
import Foundation
import Testing

@MainActor
@Suite("Browser-style navigation history")
struct BrowserNavigationHistoryTests {
    @Test("Beginning a name edit selects the new item and publishes a one-shot focus request")
    func beginNaming() {
        let navigation = NavigationModel()
        let itemID = UUID()

        navigation.beginNaming(itemID)

        #expect(navigation.selectedItemID == itemID)
        #expect(navigation.titleEditRequest == itemID)
    }

    @Test("Beginning a project reveals Projects and leaves creation pending until its field appears")
    func beginCreatingProject() throws {
        let navigation = NavigationModel()
        navigation.enterModule(.reminders)

        navigation.beginCreatingProject()

        #expect(navigation.selection == .kind(.project))
        #expect(navigation.activeModule == .projects)
        let requestID = try #require(navigation.projectCreationRequestID)

        navigation.consumeProjectCreationRequest(requestID)
        #expect(navigation.projectCreationRequestID == nil)
    }

    @Test("Back and forward restore the selected record")
    func recordHistory() {
        let navigation = NavigationModel()
        let first = UUID()
        let second = UUID()

        navigation.selectItem(first)
        navigation.selectItem(second)
        navigation.goBack()

        #expect(navigation.selectedItemID == first)
        #expect(navigation.canGoForward)

        navigation.goForward()
        #expect(navigation.selectedItemID == second)
    }

    @Test("A new destination after going back clears forward history")
    func branchingClearsForwardHistory() {
        let navigation = NavigationModel()
        navigation.select(.records(.people))
        navigation.selectItem(UUID())
        navigation.goBack()

        #expect(navigation.canGoForward)
        navigation.select(.calendar)
        #expect(navigation.canGoForward == false)
    }

    @Test("History crosses module boundaries")
    func moduleHistory() {
        let navigation = NavigationModel()
        navigation.enterModule(.records)

        #expect(navigation.activeModule == .records)
        navigation.goBack()
        #expect(navigation.selection == .today)
        #expect(navigation.activeModule == nil)

        navigation.goForward()
        #expect(navigation.selection == .records(.all))
        #expect(navigation.activeModule == .records)
    }
}

/// **Criterion A1-10** — one Escape leaves search, the query survives, and reopening restores it
/// selected.
///
/// The behaviour being protected is small but load-bearing: Escape means *move out of this mode*,
/// not *clear this field*. Clearing already has familiar affordances; making Escape do it would mean
/// pressing it twice to leave, and losing what you typed if you only meant to step back.
@MainActor
@Suite("Search as a mode")
struct SearchModeTests {
    @Test("One Escape leaves search")
    func oneEscapeLeaves() {
        let navigation = NavigationModel()
        navigation.beginSearch()
        navigation.searchQuery = "launch"

        #expect(navigation.isSearchActive)
        #expect(navigation.handleEscape())
        #expect(navigation.isSearchActive == false, "Escape leaves rather than clearing first")
    }

    @Test("The query survives leaving and is offered back")
    func queryIsPreserved() {
        let navigation = NavigationModel()
        navigation.beginSearch()
        navigation.searchQuery = "type:task is:open"
        navigation.endSearch()

        #expect(navigation.searchQuery.isEmpty, "The live field is cleared")

        navigation.beginSearch()
        #expect(navigation.searchQuery == "type:task is:open", "…but the query comes back")
    }

    @Test("A restored query is offered selected, so typing replaces it")
    func restoredQueryIsSelected() {
        let navigation = NavigationModel()
        navigation.beginSearch()
        navigation.searchQuery = "launch"
        navigation.endSearch()

        navigation.beginSearch()
        #expect(navigation.shouldSelectSearchQuery, "Typing should replace, an arrow key should keep")

        navigation.didSelectSearchQuery()
        #expect(navigation.shouldSelectSearchQuery == false, "The hint is consumed once")
    }

    @Test("Opening search fresh does not offer the old query")
    func canOpenClean() {
        let navigation = NavigationModel()
        navigation.beginSearch()
        navigation.searchQuery = "old query"
        navigation.endSearch()

        navigation.beginSearch(clearingQuery: true)
        #expect(navigation.searchQuery.isEmpty)
        #expect(navigation.shouldSelectSearchQuery == false)
    }

    @Test("Command-F requests focus every time, even while search is active")
    func repeatedSearchRequestsRemainObservable() {
        let navigation = NavigationModel()

        navigation.beginSearch()
        let firstRequest = navigation.searchFocusRequest
        navigation.searchQuery = "people in Austin"

        navigation.beginSearch()

        #expect(navigation.searchFocusRequest == firstRequest + 1)
        #expect(navigation.isSearchActive)
        #expect(navigation.searchQuery == "people in Austin", "refocusing must not replace the live query")
        #expect(navigation.shouldSelectSearchQuery, "repeating Command-F should select the live query")
    }

    @Test("Leaving search restores the selection it began with")
    func selectionIsRestored() {
        let navigation = NavigationModel()
        let original = UUID()
        navigation.selectItem(original)

        navigation.beginSearch()
        navigation.selectItem(UUID())  // walking the results
        navigation.endSearch()

        #expect(navigation.selectedItemID == original, "Escape never changes what was selected")
    }

    @Test("An empty search does not overwrite the remembered query")
    func emptySearchDoesNotClobberHistory() {
        let navigation = NavigationModel()
        navigation.beginSearch()
        navigation.searchQuery = "worth keeping"
        navigation.endSearch()

        navigation.beginSearch(clearingQuery: true)
        navigation.endSearch()

        navigation.beginSearch()
        #expect(navigation.searchQuery == "worth keeping")
    }

    @Test("Searching records recent queries")
    func recentsAreRecorded() {
        let navigation = NavigationModel()

        navigation.beginSearch()
        navigation.searchQuery = "first"
        navigation.endSearch()

        navigation.beginSearch(clearingQuery: true)
        navigation.searchQuery = "second"
        navigation.endSearch()

        #expect(navigation.recentSearches == ["second", "first"])
    }

    @Test("Leaving search when not searching is harmless")
    func endingTwiceIsSafe() {
        let navigation = NavigationModel()
        navigation.endSearch()
        #expect(navigation.isSearchActive == false)
    }
}

@MainActor
@Suite("Layout and focus")
struct LayoutAndFocusTests {
    @Test("Toggling the sidebar moves between full and two-pane")
    func sidebarToggle() {
        let navigation = NavigationModel()
        #expect(navigation.layoutMode == .full)

        navigation.toggleSidebar()
        #expect(navigation.layoutMode == .twoPane)

        navigation.toggleSidebar()
        #expect(navigation.layoutMode == .full)
    }

    @Test("Directional sidebar changes are idempotent")
    func directionalSidebarVisibility() {
        let navigation = NavigationModel()

        navigation.setSidebarVisible(false)
        navigation.setSidebarVisible(false)
        #expect(navigation.layoutMode == .twoPane)

        navigation.setSidebarVisible(true)
        navigation.setSidebarVisible(true)
        #expect(navigation.layoutMode == .full)
    }

    @Test("Showing the sidebar leaves focus mode")
    func showingSidebarLeavesFocusMode() {
        let navigation = NavigationModel()
        navigation.setLayoutMode(.focus)

        navigation.setSidebarVisible(true)

        #expect(navigation.layoutMode == .full)
    }

    @Test("Focus mode is its own toggle and returns to full")
    func focusModeToggle() {
        let navigation = NavigationModel()
        navigation.toggleFocusMode()
        #expect(navigation.layoutMode == .focus)

        navigation.toggleFocusMode()
        #expect(navigation.layoutMode == .full)
    }

    @Test("Hiding a pane moves focus off it")
    func focusFollowsVisibility() {
        let navigation = NavigationModel()
        navigation.focus(.sidebar)
        #expect(navigation.focusedPane == .sidebar)

        navigation.setLayoutMode(.twoPane)
        #expect(navigation.focusedPane != .sidebar, "Focus cannot stay on a pane that just went away")
        #expect(navigation.layoutMode.isVisible(navigation.focusedPane))
    }

    @Test("Focusing a hidden pane is refused rather than leaving the keyboard dead")
    func cannotFocusHiddenPane() {
        let navigation = NavigationModel()
        navigation.setLayoutMode(.focus)

        navigation.focus(.sidebar)
        #expect(navigation.focusedPane != .sidebar)

        navigation.focus(.list)
        #expect(navigation.focusedPane != .list)
    }

    @Test("The inspector can only be focused while it is showing")
    func inspectorFocusRequiresVisibility() {
        let navigation = NavigationModel()

        navigation.focus(.inspector)
        #expect(navigation.focusedPane != .inspector)

        navigation.isInspectorVisible = true
        navigation.focus(.inspector)
        #expect(navigation.focusedPane == .inspector)
    }

    @Test("Escape walks the ladder outward and then stops")
    func escapeWalksOutward() {
        let navigation = NavigationModel()
        navigation.focus(.detail)

        #expect(navigation.handleEscape())
        #expect(navigation.focusedPane == .list)

        #expect(navigation.handleEscape())
        #expect(navigation.focusedPane == .sidebar)

        #expect(navigation.handleEscape() == false, "The outermost rung consumes nothing")
        #expect(navigation.focusedPane == .sidebar)
    }

    @Test("Escape from the detail in focus mode leaves the mode")
    func escapeLeavesFocusMode() {
        let navigation = NavigationModel()
        navigation.setLayoutMode(.focus)
        navigation.focus(.detail)

        #expect(navigation.handleEscape())
        #expect(navigation.layoutMode == .full)
    }

    @Test("Escape dismisses an overlay first")
    func escapeDismissesOverlay() {
        let navigation = NavigationModel()
        navigation.isCommandPaletteVisible = true
        navigation.focus(.detail)

        #expect(navigation.handleEscape())
        #expect(navigation.isCommandPaletteVisible == false)
        #expect(navigation.focusedPane == .detail, "Dismissing an overlay does not also move focus")
    }

    @Test("Advancing focus never lands on a hidden pane")
    func advanceStaysVisible() {
        let navigation = NavigationModel()
        navigation.setLayoutMode(.twoPane)

        for _ in 1...8 {
            navigation.advanceFocus()
            #expect(navigation.layoutMode.isVisible(navigation.focusedPane))
            #expect(navigation.focusedPane != .inspector, "The inspector is not showing")
        }
    }
}

/// **Criterion A1-7 (selection half)** — a multi-selection can act on many items while the detail
/// pane still shows something coherent.
@MainActor
@Suite("Multi-selection")
struct MultiSelectionTests {
    @Test("Selecting one item shows it")
    func singleSelection() {
        let navigation = NavigationModel()
        let id = UUID()

        navigation.selectItem(id)
        #expect(navigation.selectedItemID == id)
        #expect(navigation.hasMultipleSelection == false)
    }

    @Test("A multi-selection still shows one item rather than going blank")
    func multiSelectionKeepsAPrimary() {
        let navigation = NavigationModel()
        let first = UUID()

        navigation.selectItem(first)
        navigation.selectedItemIDs.insert(UUID())
        navigation.selectedItemIDs.insert(UUID())

        #expect(navigation.hasMultipleSelection)
        #expect(navigation.selectedItemID == first, "The pane does not jump as the selection grows")
    }

    @Test("Shrinking a selection past the shown item moves to one still selected")
    func primaryFollowsShrinkingSelection() {
        let navigation = NavigationModel()
        let first = UUID()
        let second = UUID()

        navigation.selectedItemIDs = [first, second]
        #expect(navigation.selectedItemID != nil)

        // Deselect whichever one is being shown.
        navigation.selectedItemIDs = navigation.selectedItemIDs.filter { $0 != navigation.selectedItemID }

        #expect(navigation.selectedItemID != nil, "The pane never goes blank while something is selected")
        #expect(navigation.selectedItemIDs.contains(navigation.selectedItemID ?? UUID()))
    }

    @Test("Clearing the selection empties the detail pane")
    func clearingEmptiesThePane() {
        let navigation = NavigationModel()
        navigation.selectedItemIDs = [UUID(), UUID()]

        navigation.selectedItemIDs = []
        #expect(navigation.selectedItemID == nil)
    }

    @Test("Changing destination clears the selection")
    func changingDestinationClears() {
        let navigation = NavigationModel()
        navigation.selectedItemIDs = [UUID(), UUID()]

        navigation.select(.inbox)
        #expect(navigation.selectedItemIDs.isEmpty)
        #expect(navigation.selectedItemID == nil)
    }
}
