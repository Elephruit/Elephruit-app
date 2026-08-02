import ElephruitCore
import ElephruitDesign
@testable import ElephruitFeatures
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

@MainActor
private func makeServices() -> AppServices {
    let suite = UserDefaults(suiteName: "deletion.tests.\(UUID().uuidString)") ?? .standard
    return AppServices.inMemory(populated: false, defaults: suite)
}

/// The one deletion model, held still.
///
/// The rules: user content moves to the Trash, undoably, through `StructuralUndoCoordinator`;
/// configuration — a saved search, a project view, a calendar set — cannot be trashed, so it is
/// confirmed at the call site and the consequence stays as small as these tests pin it to be.
@MainActor
@Suite("Deletion model")
struct DeletionModelTests {
    @Test("Deleting a saved search hides it without touching what it finds")
    func savedSearchDeletionIsSoftAndScoped() throws {
        let services = makeServices()
        let note = try services.items.create(ItemDraft(kind: .note, title: "Findable"))
        let search = SavedSearch(name: "Open work", queryString: "is:open")
        services.context.insert(search)
        try services.context.save()
        services.refreshDerivedState()
        #expect(services.sidebar.savedSearches.count == 1)

        services.deleteSavedSearch(id: search.id)

        #expect(services.sidebar.savedSearches.isEmpty, "Gone from the sidebar")
        #expect(search.deletedAt != nil, "Soft-deleted, not destroyed")
        #expect(try services.items.item(id: note.id)?.isInTrash == false, "The search is only its text")
    }

    @Test("Deleting a smart list leaves its tasks where they are")
    func smartListDeletionKeepsTheTasks() throws {
        let services = makeServices()
        let task = try services.items.create(ItemDraft(kind: .task, title: "Still here"))
        let list = SavedSearch(name: "Errands", queryString: "")
        list.taskFilterData = Data("{}".utf8)
        services.context.insert(list)
        try services.context.save()
        #expect(services.taskViews.smartLists().count == 1)

        services.deleteSavedSearch(id: list.id)

        #expect(services.taskViews.smartLists().isEmpty)
        #expect(try services.items.item(id: task.id)?.isInTrash == false)
    }

    @Test("The last project view cannot be removed, and the guard is reachable")
    func lastProjectViewIsRefused() throws {
        let services = makeServices()
        let project = try services.items.create(ItemDraft(kind: .project, title: "P"))
        _ = try services.projectWorkspace.ensureWorkspace(for: project)
        let views = services.projectWorkspace.views(in: project)
        #expect(views.count > 1, "A fresh workspace ships every view")

        for view in views.dropLast() {
            #expect(try services.projectWorkspace.removeView(view))
        }
        let last = try #require(services.projectWorkspace.views(in: project).first)
        #expect(try services.projectWorkspace.removeView(last) == false, "The last view stays")
        #expect(services.projectWorkspace.views(in: project).count == 1)
    }

    @Test("Deleting a tag strips the tagging and spares the items and children")
    func tagDeletionIsScopedToTheTagging() throws {
        let services = makeServices()
        let item = try services.items.create(ItemDraft(kind: .note, title: "Tagged"))
        let tags = try services.tags.ensureTags(named: ["work/clients"])
        let child = try #require(tags.first)
        let parent = try #require(child.parent)
        try services.items.update(item) { $0.tags.append(child) }

        try services.tags.delete(parent)

        #expect(try services.tags.tag(slug: "work") == nil)
        #expect(try services.tags.tag(slug: "work/clients") != nil, "Children are orphaned, not destroyed")
        #expect(try services.items.item(id: item.id)?.isInTrash == false)
    }
}
