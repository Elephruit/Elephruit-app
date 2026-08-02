import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

@Suite("Capture into a project")
@MainActor
struct CaptureIntoProjectTests {

    @Test("A note tagged to a project is filed, not rejected")
    func noteFilesUnderProject() throws {
        // The bug this fixes: capture set parentID for *any* kind, and
        // ItemKind.project.canContain(.note) is false — so the validator rejected the whole capture
        // and tagging a jot to a project filed nothing at all.
        let fixture = try CaptureFixture()
        let project = try fixture.makeProject("Elephruit")

        let note = try #require(try fixture.capture.capture(text: "Thoughts on the board >Elephruit"))

        #expect(note.kind == .note)
        // Filed by link, which the project reads back as "Project notes".
        #expect(project.filedItems().contains { $0.id == note.id })
    }

    @Test("A task tagged to a project is contained by it")
    func taskParentsUnderProject() throws {
        let fixture = try CaptureFixture()
        let project = try fixture.makeProject("Elephruit")

        var draft = CaptureDraft(kind: .task, title: "Wire the board")
        draft.projectHint = "Elephruit"
        let task = try fixture.capture.capture(draft)

        #expect(task.parent?.id == project.id)
    }

    @Test("#bug files a defect rather than tagging a task")
    func bugSigilSetsKind() throws {
        let parsed = CaptureParser.parse("#bug crash on launch")
        #expect(parsed.kind == .bug)
        #expect(!parsed.tagSlugs.contains("bug"))
    }

    @Test("#bugs and #bug-triage stay ordinary tags")
    func onlyExactWordsAreClaimed() throws {
        // A sigil that swallowed every word starting with "bug" would be worse than no shorthand.
        let plural = CaptureParser.parse("#bugs review the list")
        #expect(plural.kind != .bug)
        #expect(plural.tagSlugs.contains("bugs"))

        let compound = CaptureParser.parse("#bug-triage on Friday")
        #expect(compound.kind != .bug)
    }

    @Test("A captured bug arrives with a record, a reference and a column")
    func capturedBugIsFullyFiled() throws {
        let fixture = try CaptureFixture()
        let project = try fixture.makeProject("Elephruit")

        let bug = try #require(try fixture.capture.capture(text: "#bug crash on launch >Elephruit"))

        #expect(bug.kind == .bug)
        // Without the record it reads as "Not a bug" in every severity band.
        #expect(bug.bugRecord != nil)
        #expect(bug.referenceKey != nil)
        // In the first non-terminal column, so it is visible on the board rather than unplaced.
        #expect(bug.workflowStageID != nil)
        #expect(bug.parent?.id == project.id)
    }

    @Test("A bug captured into the Inbox still gets somewhere to write steps")
    func inboxBugStillHasARecord() throws {
        // Filing and being a defect are independent facts, so the record is created before the
        // project is even considered.
        let fixture = try CaptureFixture()
        let bug = try #require(try fixture.capture.capture(text: "#bug it crashes"))
        #expect(bug.bugRecord != nil)
    }
}

@MainActor
private struct CaptureFixture {
    let store: StoreFixture
    let capture: CaptureService
    let workspace: ProjectWorkspaceService
    let templates: ProjectTemplateService

    init() throws {
        store = try StoreFixture()
        capture = CaptureService(items: store.items, context: store.context, dateProvider: store.dateProvider)
        workspace = ProjectWorkspaceService(
            items: store.items,
            context: store.context,
            dateProvider: store.dateProvider
        )
        let workItems = WorkItemService(
            items: store.items,
            workspace: workspace,
            context: store.context,
            dateProvider: store.dateProvider
        )
        templates = ProjectTemplateService(
            items: store.items,
            workspace: workspace,
            workItems: workItems,
            context: store.context
        )
    }

    func makeProject(_ name: String) throws -> Item {
        try templates.createProject(named: name, from: .blank)
    }
}
