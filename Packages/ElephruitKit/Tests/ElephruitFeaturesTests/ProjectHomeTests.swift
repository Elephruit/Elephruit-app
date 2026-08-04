import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

@testable import ElephruitFeatures

/// One project, one front door.
///
/// The regression class these pin down: a project used to open onto different surfaces depending
/// on which door was used — the sidebar led to the workspace, the palette and a note's link led
/// to a separate detail page — and the workspace itself landed on whichever saved view happened
/// to be first. Home is the answer stated once, and legacy Overview routes resolve to it without
/// touching the records they were saved in.
@MainActor
@Suite("Project Home routing")
struct ProjectHomeTests {
    private func makeServices() -> AppServices {
        let suiteName = "project-home-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return AppServices.inMemory(defaults: defaults)
    }

    @discardableResult
    private func makeProject(in services: AppServices, title: String = "Launch") throws -> Item {
        let project = try services.items.create(ItemDraft(kind: .project, title: title))
        _ = try services.projectWorkspace.ensureWorkspace(for: project)
        return project
    }

    @Test("Opening a project through the canonical opener lands on the workspace, viewless")
    func openLandsOnWorkspaceHome() throws {
        let services = makeServices()
        let project = try makeProject(in: services)

        let navigation = NavigationModel()
        navigation.open(project)

        #expect(navigation.selection == .project(id: project.id, viewID: nil))
        #expect(navigation.activeModule == .projects)
    }

    @Test("A viewless load is Home, not the first saved view")
    func viewlessLoadIsHome() throws {
        let services = makeServices()
        let project = try makeProject(in: services)

        let model = ProjectWorkspaceModel(services: services)
        model.load(projectID: project.id, viewID: nil)

        #expect(model.isHome)
        #expect(model.activeView == nil)
    }

    @Test("A saved Overview route resolves to Home without touching the record")
    func legacyOverviewResolvesToHome() throws {
        let services = makeServices()
        let project = try makeProject(in: services)

        let views = services.projectWorkspace.views(in: project)
        let overview = try #require(views.first { $0.kind == .overview })

        let model = ProjectWorkspaceModel(services: services)
        model.load(projectID: project.id, viewID: overview.id)

        #expect(model.isHome, "The Overview tab's content lives on Home now")
        // Resolution, not migration: the record is still in the store for other old routes.
        #expect(services.projectWorkspace.views(in: project).contains { $0.id == overview.id })
    }

    @Test("An explicitly selected view still opens that view")
    func explicitViewsStayExplicit() throws {
        let services = makeServices()
        let project = try makeProject(in: services)

        let views = services.projectWorkspace.views(in: project)
        let board = try #require(views.first { $0.kind == .board })

        let model = ProjectWorkspaceModel(services: services)
        model.load(projectID: project.id, viewID: board.id)

        #expect(!model.isHome)
        #expect(model.activeView?.id == board.id)
    }

    @Test("Selecting a saved Overview by identifier lands on Home")
    func selectingOverviewSelectsHome() throws {
        let services = makeServices()
        let project = try makeProject(in: services)

        let views = services.projectWorkspace.views(in: project)
        let overview = try #require(views.first { $0.kind == .overview })
        let board = try #require(views.first { $0.kind == .board })

        let model = ProjectWorkspaceModel(services: services)
        model.load(projectID: project.id, viewID: board.id)
        model.selectView(overview.id)

        #expect(model.isHome)
    }

    @Test("Home returns from any view, and clears the transient search")
    func selectHomeReturnsAndClearsSearch() throws {
        let services = makeServices()
        let project = try makeProject(in: services)

        let views = services.projectWorkspace.views(in: project)
        let board = try #require(views.first { $0.kind == .board })

        let model = ProjectWorkspaceModel(services: services)
        model.load(projectID: project.id, viewID: board.id)
        model.searchText = "pricing"
        model.selectHome()

        #expect(model.isHome)
        #expect(model.searchText.isEmpty)
    }
}
