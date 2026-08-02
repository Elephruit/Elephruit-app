import ElephruitCore
import ElephruitDesign
@testable import ElephruitFeatures
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

@MainActor
private func makeServices() -> AppServices {
    let suite = UserDefaults(suiteName: "workitem.tests.\(UUID().uuidString)") ?? .standard
    return AppServices.inMemory(populated: false, defaults: suite)
}

/// The editing surface behind the work-item sheet, and the selection model around it.
///
/// These pin down the P0 that was reported as "a bug selected from a project view cannot be
/// edited": the sheet drew every field as text, the report section vanished for a bug without a
/// record, and the row's tap gesture stayed live under the inline title field. Each of those is a
/// behaviour here now, so it cannot quietly come back.
@MainActor
@Suite("Work item editing")
struct WorkItemEditingTests {
    @Test("Moving an item to another group gives its row a new identity")
    func rowIdentityIncludesGroup() {
        let itemID = UUID()
        let minor = WorkItemGroupRowID(groupKey: "severity.minor", itemID: itemID)
        let cosmetic = WorkItemGroupRowID(groupKey: "severity.cosmetic", itemID: itemID)

        #expect(minor != cosmetic)
    }

    // MARK: - The report

    @Test("Opening the editor never creates the record; the first write does")
    func recordIsCreatedByTheFirstWriteOnly() throws {
        let services = makeServices()
        let project = try services.items.create(ItemDraft(kind: .project, title: "P"))
        // A bug created outside the work-item path — capture from an older build, an import, a
        // kind conversion — has no record. This was the bug that opened onto an empty sheet.
        let bug = try services.items.create(ItemDraft(kind: .bug, title: "It breaks", parentID: project.id))
        #expect(bug.bugRecord == nil)

        let editor = WorkItemEditorModel(services: services, itemID: bug.id)

        // Reading answers with the same defaults the rows substitute, and writes nothing.
        #expect(editor.bugFacts.severity == .minor)
        #expect(bug.bugRecord == nil, "Looking at a report is not an edit")

        editor.setSeverity(.major)
        #expect(bug.bugRecord != nil, "The first write creates the record")
        #expect(bug.bugRecord?.severity == .major)
    }

    @Test("A record-less bug accepts a full report")
    func recordlessBugTakesAFullReport() throws {
        let services = makeServices()
        let project = try services.items.create(ItemDraft(kind: .project, title: "P"))
        let bug = try services.items.create(ItemDraft(kind: .bug, title: "It breaks", parentID: project.id))

        let editor = WorkItemEditorModel(services: services, itemID: bug.id)
        editor.updateBug {
            $0.stepsToReproduce = "Open the sheet"
            $0.expectedBehavior = "Fields"
            $0.actualBehavior = "Text"
            $0.environment = "macOS 26"
            $0.affectedVersion = "1.2"
            $0.isRegression = true
        }
        editor.updateBug { $0.fixVersion = "1.3" }

        let facts = try #require(bug.bugRecord).facts
        #expect(facts.stepsToReproduce == "Open the sheet")
        #expect(facts.expectedBehavior == "Fields")
        #expect(facts.actualBehavior == "Text")
        #expect(facts.environment == "macOS 26")
        #expect(facts.affectedVersion == "1.2")
        #expect(facts.fixVersion == "1.3")
        #expect(facts.isRegression)
    }

    @Test("A newly filed bug keeps the reporting device context in its first save")
    func newBugTakesDeviceContext() throws {
        let services = makeServices()
        let project = try services.items.create(ItemDraft(kind: .project, title: "P"))
        let context = BugReportDeviceContext(
            environment: "MacBook Pro · macOS 26.0.1",
            affectedVersion: "2.4 (build 310)"
        )

        let bug = try services.workItems.createWorkItem(
            title: "It breaks",
            kind: .bug,
            in: project,
            bugFacts: context.facts
        )

        #expect(bug.bugRecord?.environment == context.environment)
        #expect(bug.bugRecord?.affectedVersion == context.affectedVersion)
        #expect(BugReportDeviceContext.versionAndBuild(version: "2.4", build: "310") == "2.4 (build 310)")
    }

    @Test("Verification round-trips, record or no record")
    func verificationRoundTrips() throws {
        let services = makeServices()
        let project = try services.items.create(ItemDraft(kind: .project, title: "P"))
        let bug = try services.items.create(ItemDraft(kind: .bug, title: "It breaks", parentID: project.id))

        let editor = WorkItemEditorModel(services: services, itemID: bug.id)
        #expect(!editor.isVerified)

        editor.setVerified(true)
        #expect(editor.isVerified, "Verifying a record-less bug creates the record")

        editor.setVerified(false)
        #expect(!editor.isVerified)
    }

    @Test("An edit is visible to every presentation, because they read the same facts")
    func editsReachEveryView() throws {
        let services = makeServices()
        let project = try services.items.create(ItemDraft(kind: .project, title: "P"))
        let bug = try services.workItems.createWorkItem(
            title: "It breaks", kind: .bug, in: project
        )

        let editor = WorkItemEditorModel(services: services, itemID: bug.id)
        editor.setSeverity(.critical)

        // The rows — list, board, bugs — all draw `taskFacts()`; the sheet reads the record. One
        // write, one answer everywhere.
        #expect(bug.taskFacts().severity == .critical)
        #expect(editor.bugFacts.severity == .critical)
    }

    // MARK: - The item's own fields

    @Test("Title, notes, status and priority commit through the editor")
    func plainFieldsCommit() throws {
        let services = makeServices()
        let project = try services.items.create(ItemDraft(kind: .project, title: "P"))
        let bug = try services.workItems.createWorkItem(
            title: "Untitled", kind: .bug, in: project
        )

        let editor = WorkItemEditorModel(services: services, itemID: bug.id)
        var changes = 0
        editor.onChange = { changes += 1 }

        editor.setTitle("Board drops clicks")
        editor.setBody("Seen twice on the 26.0 beta.")
        editor.setPriority(.high)
        editor.setStatus(.completed)

        #expect(bug.title == "Board drops clicks")
        #expect(bug.body == "Seen twice on the 26.0 beta.")
        #expect(bug.priority == .high)
        #expect(bug.status == .completed)
        #expect(changes == 4, "Every commit told the workspace to redraw")

        editor.setStatus(.open)
        #expect(bug.status == .open)
        #expect(bug.completedAt == nil)
    }

    @Test("A no-op write commits nothing")
    func noOpWritesAreSkipped() throws {
        let services = makeServices()
        let project = try services.items.create(ItemDraft(kind: .project, title: "P"))
        let bug = try services.workItems.createWorkItem(
            title: "It breaks", kind: .bug, in: project
        )

        let editor = WorkItemEditorModel(services: services, itemID: bug.id)
        var changes = 0
        editor.onChange = { changes += 1 }

        editor.setTitle("It breaks")
        editor.setPriority(bug.priority)
        editor.updateBug { _ in }
        // A blank title is not a rename — the sheet commits on focus loss, and focus is lost by
        // closing a sheet whose field somebody had just emptied.
        editor.setTitle("   ")

        #expect(changes == 0)
        #expect(bug.title == "It breaks")
    }

    // MARK: - Selection versus editing

    @Test("Row gestures stand down for the row being renamed, and only that row")
    func rowGesturesYieldToTheTitleField() throws {
        let services = makeServices()
        let model = ProjectWorkspaceModel(services: services)
        let a = UUID()
        let b = UUID()

        #expect(model.rowGesturesAreActive(for: a))
        model.beginRenaming(a)
        #expect(!model.rowGesturesAreActive(for: a), "The field owns the clicks now")
        #expect(model.rowGesturesAreActive(for: b), "Other rows still select")
        model.endRenaming()
        #expect(model.rowGesturesAreActive(for: a))
    }

    @Test("Selecting presents nothing; presenting is its own act")
    func selectionAndPresentationStaySeparate() throws {
        let services = makeServices()
        let model = ProjectWorkspaceModel(services: services)
        let id = UUID()

        model.select(id)
        #expect(model.presentedItemID == nil, "A click must not throw a sheet")

        model.present(id)
        #expect(model.presentedItemID == id)
    }

    @Test("Opening a bug from any project view routes to its inline report, never a sheet")
    func everyBugOpeningUsesInlinePresentation() throws {
        let services = makeServices()
        let project = try services.items.create(ItemDraft(kind: .project, title: "P"))
        let bug = try services.workItems.createWorkItem(title: "It breaks", kind: .bug, in: project)

        let model = ProjectWorkspaceModel(services: services)
        model.load(projectID: project.id, viewID: nil)
        #expect(model.activeView?.kind != .bugs)

        model.present(bug.id)

        #expect(model.activeView?.kind == .bugs)
        #expect(model.expandedBugID == bug.id)
        #expect(model.presentedItemID == nil)
    }

    @Test("The verification concern opens the completed bug that can clear it")
    func verificationConcernOpensItsFix() throws {
        let services = makeServices()
        let project = try services.items.create(ItemDraft(kind: .project, title: "P"))
        let openBug = try services.workItems.createWorkItem(
            title: "Still broken", kind: .bug, in: project
        )
        let fixedBug = try services.workItems.createWorkItem(
            title: "Ready to check", kind: .bug, in: project
        )
        _ = try services.tasks.complete(fixedBug)

        let model = ProjectWorkspaceModel(services: services)
        model.load(projectID: project.id, viewID: nil)

        #expect(model.health.bugsAwaitingVerification == 1)
        #expect(model.presentFixAwaitingVerification())
        #expect(model.activeView?.kind == .bugs)
        #expect(model.expandedBugID == fixedBug.id)
        #expect(model.presentedItemID == nil)
        #expect(model.selectedItemIDs == [fixedBug.id])
        #expect(model.expandedBugID != openBug.id)

        try services.bugs.markVerified(fixedBug)
        model.refresh()

        #expect(model.health.bugsAwaitingVerification == 0)
        #expect(!model.presentFixAwaitingVerification())
    }

    @Test("Deleting from the workspace lands the selection on the nearest survivor")
    func deletionMovesTheSelectionPredictably() throws {
        let services = makeServices()
        let project = try services.items.create(ItemDraft(kind: .project, title: "P"))
        let first = try services.workItems.createWorkItem(title: "One", in: project)
        let second = try services.workItems.createWorkItem(title: "Two", in: project)
        let third = try services.workItems.createWorkItem(title: "Three", in: project)

        let model = ProjectWorkspaceModel(services: services)
        model.load(projectID: project.id, viewID: nil)
        model.select(second.id)

        model.moveSelectionToTrash()

        #expect(try services.items.item(id: second.id)?.isInTrash == true)
        #expect(model.selectedItemIDs.count == 1)
        #expect(
            model.selectedItemIDs.first == first.id || model.selectedItemIDs.first == third.id,
            "The selection moved to a neighbour rather than to nothing"
        )

        // Through the undo coordinator, like every list in the app.
        services.undoManager.undo()
        #expect(try services.items.item(id: second.id)?.isInTrash == false)
    }

    @Test("Deleting the presented item closes the sheet rather than leaving it over a ghost")
    func deletionClosesTheSheet() throws {
        let services = makeServices()
        let project = try services.items.create(ItemDraft(kind: .project, title: "P"))
        let bug = try services.workItems.createWorkItem(title: "It breaks", kind: .bug, in: project)

        let model = ProjectWorkspaceModel(services: services)
        model.load(projectID: project.id, viewID: nil)
        model.present(bug.id)

        model.moveToTrash([bug.id])

        #expect(model.presentedItemID == nil)
        #expect(model.expandedBugID == nil)
    }
}
