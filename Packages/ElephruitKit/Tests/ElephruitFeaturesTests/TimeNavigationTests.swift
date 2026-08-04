import ElephruitCore
import Foundation
import Testing

@testable import ElephruitFeatures

/// Time's information architecture: two surfaces, one toolbar control, no sidebar level.
///
/// The module used to swap the whole first column for a section holding two buttons — the largest
/// possible navigation gesture buying the smallest possible navigation. The rule now: a module
/// swaps the sidebar only when it has real navigation to put there, and Time, Bookmarks, Archive
/// and the Trash do not.
@MainActor
@Suite("Time navigation")
struct TimeNavigationTests {
    @Test("Only the modules with real navigation bring their own sidebar")
    func sidebarIsEarnedByNavigation() {
        #expect(AppModule.calendar.hasOwnSidebar)
        #expect(AppModule.records.hasOwnSidebar)
        #expect(AppModule.notes.hasOwnSidebar)
        #expect(AppModule.areas.hasOwnSidebar)

        #expect(!AppModule.time.hasOwnSidebar, "Two mode buttons are a toolbar control, not a column")
        #expect(!AppModule.bookmarks.hasOwnSidebar, "One list needs no second level")
        #expect(!AppModule.archive.hasOwnSidebar)
        #expect(!AppModule.trash.hasOwnSidebar)
        #expect(!AppModule.projects.hasOwnSidebar)
    }

    @Test("Entering Time keeps the primary sidebar on screen")
    func enteringTimeKeepsThePrimarySidebar() {
        let navigation = NavigationModel()
        navigation.enterModule(.time)

        #expect(navigation.activeModule == .time)
        #expect(navigation.selection == .time)
    }

    @Test("The open surface survives a relaunch")
    func timeSurfaceRestores() {
        let navigation = NavigationModel()
        navigation.select(.time)
        navigation.timeSurface = .report

        let restored = NavigationModel()
        restored.restore(navigation.restorationState)

        #expect(restored.selection == .time)
        #expect(restored.timeSurface == .report, "Reports was open; Reports comes back")
    }

    @Test("A scene written before the surface was recorded restores onto the log")
    func oldScenesDefaultToTheLog() throws {
        // What an earlier build wrote: today's payload minus the key it did not know about.
        let navigation = NavigationModel()
        navigation.select(.time)
        navigation.timeSurface = .report
        let encoded = try #require(navigation.restorationState.encoded)

        var object = try #require(
            try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
        )
        object.removeValue(forKey: "timeSurface")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try #require(String(data: legacyData, encoding: .utf8))

        let state = try #require(NavigationModel.RestorationState(encoded: legacy))
        let restored = NavigationModel()
        restored.restore(state)
        #expect(restored.timeSurface == .log)
    }
}
