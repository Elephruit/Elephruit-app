import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

@MainActor
@Suite("Complete reminder creation")
struct ReminderDraftCreationTests {
    @Test("A complete task draft is present from its first save")
    func completeDraft() throws {
        let fixture = try StoreFixture()
        let today = fixture.dateProvider.startOfToday
        var checklist = TaskChecklist()
        checklist.append("Passport")
        checklist.append("Charger")

        let item = try fixture.items.create(
            ItemDraft(
                kind: .task,
                title: "Pack for the trip",
                body: "Leave after lunch",
                tagSlugs: ["travel"],
                dueAt: fixture.dateProvider.startOfDay(daysFromToday: 3),
                startAt: fixture.dateProvider.startOfDay(daysFromToday: 1),
                checklist: checklist,
                todayCommittedOn: today
            )
        )

        #expect(item.body == "Leave after lunch")
        #expect(item.tags.map { $0.slug } == ["travel"])
        #expect(item.checklist.items.map { $0.title } == ["Passport", "Charger"])
        #expect(item.todayCommittedOn == today)
        #expect(item.dayRelevanceKey != Date.distantPast)
    }
}
