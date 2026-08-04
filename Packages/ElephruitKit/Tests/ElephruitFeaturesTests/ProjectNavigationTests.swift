import ElephruitCore
import Foundation
import Testing

@testable import ElephruitFeatures

/// Opening a project must never take the sidebar away.
///
/// The regression these pin down: `SidebarView` swapped its levels for *any* active module, while
/// the header above it consulted ``AppModule/hasOwnSidebar`` — and Projects is exactly the module
/// that declares it has no sidebar of its own. Entering a project therefore suppressed the header,
/// swapped the primary list for a module sidebar that draws nothing, and left a blank column with
/// no visible way anywhere. The tree the user navigates projects with had been removed by the act
/// of using it.
@MainActor
@Suite("Project navigation")
struct ProjectNavigationTests {
    @Test("Opening a project keeps the primary sidebar on screen")
    func openingAProjectKeepsThePrimarySidebar() {
        let navigation = NavigationModel()
        navigation.select(.project(id: UUID(), viewID: nil))

        #expect(navigation.activeModule == .projects, "Layout still keys off the module")
    }

    @Test("The Library band holds the working modules, and only those")
    func libraryBandComposition() {
        // The sidebar no longer has a second level to swap to — a module's sources render as
        // sections inside the one primary list. What is worth pinning instead: Areas live inside
        // the projects tree, and Archive and Trash live on the bottom rail, because a wastebasket
        // listed as a peer of Calendar is what made the old module band read as an index.
        #expect(SidebarView.libraryModules == [.notes, .reminders, .calendar, .records, .time, .bookmarks])
        #expect(!SidebarView.libraryModules.contains(.areas))
        #expect(!SidebarView.libraryModules.contains(.archive))
        #expect(!SidebarView.libraryModules.contains(.trash))
        #expect(!SidebarView.libraryModules.contains(.projects))
    }

    @Test("Every selection the Projects module owns keeps the primary sidebar")
    func projectShapedSelectionsKeepThePrimarySidebar() {
        // Not only `.project(id:viewID:)` — "All Projects", the goal and work-item kind lists, and
        // the project inbox all resolve to the Projects module and must all inherit the same rule.
        let selections: [SidebarSelection] = [
            .project(id: UUID(), viewID: UUID()),
            .projectInbox,
            .kind(.project), .kind(.goal), .kind(.bug), .kind(.feature),
            .kind(.milestone), .kind(.release),
        ]
        for selection in selections {
            let navigation = NavigationModel()
            navigation.select(selection)
            #expect(navigation.activeModule == .projects, "\(selection) resolved elsewhere")
        }
    }

    @Test("A project selection matches its sidebar row whichever view is open")
    func projectSelectionMatchesItsRowRegardlessOfView() {
        // The row is tagged with `viewID: nil`; the live selection carries the open view so that
        // returning lands on it. The row form is what makes the two meet, or the highlight would
        // vanish the moment a tab was chosen.
        let project = UUID()
        let board = UUID()

        #expect(
            SidebarSelection.project(id: project, viewID: board).sidebarRowForm
                == .project(id: project, viewID: nil)
        )
        #expect(
            SidebarSelection.project(id: project, viewID: nil).sidebarRowForm
                == .project(id: project, viewID: nil)
        )
        #expect(SidebarSelection.today.sidebarRowForm == .today)
        #expect(SidebarSelection.kind(.note).sidebarRowForm == .kind(.note))
    }

    @Test("A window restored into a project comes back with the sidebar it needs")
    func restorationIntoAProjectKeepsThePrimarySidebar() {
        let navigation = NavigationModel()
        navigation.select(.project(id: UUID(), viewID: UUID()))

        let restored = NavigationModel()
        restored.restore(navigation.restorationState)

        #expect(restored.selection == navigation.selection, "Same project, same view")
    }

    @Test("Leaving a project for a global destination and coming back preserves the view")
    func returningToAProjectResumesItsView() {
        let navigation = NavigationModel()
        let project = UUID()
        let view = UUID()
        navigation.select(.project(id: project, viewID: view))
        navigation.select(.today)

        #expect(navigation.activeModule == nil)
        navigation.goBack()

        #expect(navigation.selection == .project(id: project, viewID: view))
    }
}
