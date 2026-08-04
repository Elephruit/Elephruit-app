import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

@MainActor
@Suite("Task-to-reminder preservation")
struct TaskToReminderMigrationTests {
    @Test("The same item becomes a reminder with its graph intact")
    func preservesIdentityAndRelationships() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Launch")
        let person = try fixture.items.create(ItemDraft(kind: .person, title: "Maya"))
        let task = try fixture.makeTask(title: "Send brief", parentID: project.id)
        try fixture.items.link(task, to: person, kind: .promisedTo)
        let identity = task.id
        let createdAt = task.createdAt

        #expect(try TaskToReminderMigration.plan(in: fixture.context) == [identity])
        #expect(try TaskToReminderMigration.apply(in: fixture.context) == 1)

        let reminder = try fixture.requireItem(id: identity)
        #expect(reminder.kind == .reminder)
        #expect(reminder.createdAt == createdAt)
        #expect(reminder.parent?.id == project.id)
        #expect((reminder.outgoingLinks ?? []).first?.target?.id == person.id)
        #expect((reminder.outgoingLinks ?? []).first?.kind == .promisedTo)
    }

    @Test("A completed reminder migration is idempotent")
    func runsOnce() throws {
        let fixture = try StoreFixture()
        _ = try fixture.makeTask(title: "Legacy")

        #expect(try TaskToReminderMigration.apply(in: fixture.context) == 1)
        #expect(try TaskToReminderMigration.apply(in: fixture.context) == 0)
        #expect(try TaskToReminderMigration.plan(in: fixture.context).isEmpty)
    }

    @Test("Project bugs and features remain project work records")
    func preservesProjectSpecificWorkKinds() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Launch")
        let task = try fixture.makeTask(title: "Legacy", parentID: project.id)
        let bug = try fixture.items.create(ItemDraft(kind: .bug, title: "Crash", parentID: project.id))
        let feature = try fixture.items.create(ItemDraft(kind: .feature, title: "Export", parentID: project.id))

        #expect(try TaskToReminderMigration.plan(in: fixture.context) == [task.id])
        #expect(try TaskToReminderMigration.apply(in: fixture.context) == 1)

        #expect(try fixture.requireItem(id: task.id).kind == .reminder)
        #expect(try fixture.requireItem(id: bug.id).kind == .bug)
        #expect(try fixture.requireItem(id: feature.id).kind == .feature)
        #expect(try fixture.requireItem(id: bug.id).parent?.id == project.id)
        #expect(try fixture.requireItem(id: feature.id).parent?.id == project.id)
    }
}
