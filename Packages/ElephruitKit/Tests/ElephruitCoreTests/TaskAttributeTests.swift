import ElephruitCore
import Foundation
import Testing

private let clock = FixedDateProvider.reference
private var calendar: Calendar { clock.calendar }
private var now: Date { clock.now }

private func day(_ offset: Int) -> Date { clock.startOfDay(daysFromToday: offset) }

private func task(_ configure: (inout TaskFacts) -> Void = { _ in }) -> TaskFacts {
    var facts = TaskFacts(title: "A task", hasHome: true, createdAt: now, updatedAt: now)
    configure(&facts)
    return facts
}

private func layout(
    _ facts: TaskFacts,
    names: TaskAttributes.Names = TaskAttributes.Names(),
    offersChecklist: Bool = true
) -> TaskAttributes.Layout {
    TaskAttributes.layout(
        for: facts,
        names: names,
        now: now,
        calendar: calendar,
        offersChecklist: offersChecklist
    )
}

/// ### Why this rule earns a suite of its own
/// "A button appears if and only if its value is absent" is what keeps a task with nothing set to one
/// short row instead of six blank form rows. It is also exactly the kind of rule that quietly becomes
/// "mostly" — five of six cases handled and the sixth forgotten during a refactor — which is why the
/// assertion below walks all six rather than spot-checking two.
@Suite("A task's attributes are buttons only while they are absent")
struct TaskAttributeVisibilityTests {
    @Test("An empty task offers all six and shows no chips")
    func emptyTaskIsAllOffers() {
        let result = layout(task())
        #expect(result.chips.isEmpty)
        #expect(result.buttons == TaskAttributes.Kind.offered)
    }

    @Test("Setting any one of the six replaces its button with its chip, and touches no other")
    func eachValueRemovesExactlyItsOwnButton() {
        let cases: [(TaskAttributes.Kind, TaskFacts, TaskAttributes.Names)] = [
            (.when, task { $0.startAt = day(3) }, .init()),
            (.tags, task { $0.tagSlugs = ["admin"] }, .init()),
            (.checklist, task { $0.checklistTotal = 2 }, .init()),
            (.deadline, task { $0.deadlineAt = day(5) }, .init()),
            (.people, task { $0.relatedPersonIDs = [UUID()] }, .init(people: ["Ana"])),
            (.priority, task { $0.priority = .high }, .init()),
        ]

        for (kind, facts, names) in cases {
            let result = layout(facts, names: names)

            #expect(!result.buttons.contains(kind), "\(kind.rawValue) still offers a button")
            #expect(result.chips.map(\.kind) == [kind], "\(kind.rawValue) drew the wrong chips")

            // The other five are untouched. A control that changes what a neighbouring control
            // offers is how a row starts rearranging itself as you fill it in.
            let expected = TaskAttributes.Kind.offered.filter { $0 != kind }
            #expect(result.buttons == expected, "\(kind.rawValue) disturbed the other buttons")
        }
    }

    @Test("Every kind that is offered as a button can be turned into a chip")
    func nothingIsOfferedThatCannotBeSet() {
        // Guards the inverse mistake: a seventh button added to `offered` with no branch producing
        // its chip would be a control that never goes away however many times it is used.
        let all = layout(
            task {
                $0.startAt = day(1)
                $0.tagSlugs = ["admin"]
                $0.checklistTotal = 1
                $0.deadlineAt = day(2)
                $0.relatedPersonIDs = [UUID()]
                $0.priority = .low
            },
            names: .init(people: ["Ana"])
        )

        #expect(all.buttons.isEmpty)
        #expect(Set(all.chips.map(\.kind)).isSuperset(of: TaskAttributes.Kind.offered))
    }

    @Test("The checklist button is withheld where the surface has nowhere to put steps")
    func checklistIsTheOneConditionalOffer() {
        #expect(layout(task(), offersChecklist: false).buttons == [.when, .tags, .deadline, .people, .priority])
    }

    @Test("Reminder and waiting are chips with no button, because another control sets them")
    func chipOnlyAttributes() {
        let reminded = layout(task { $0.reminderAt = day(1) })
        #expect(reminded.chips.map(\.kind) == [.reminder])
        #expect(reminded.buttons == TaskAttributes.Kind.offered)

        let waiting = layout(task { $0.waitingSince = day(-2) }, names: .init(waitingOn: "Ana"))
        #expect(waiting.chips.contains { $0.kind == .waiting && $0.text == "Waiting on Ana" })
        #expect(!waiting.buttons.contains(.waiting))
    }
}

@Suite("What a chip says is only ever what is currently true")
struct TaskAttributeChipTests {
    @Test("When is one chip, however many ways there are to answer it")
    func whenIsSingular() {
        // Someday wins over a start date, because the invariants do not permit both and showing
        // them together would be showing a contradiction.
        let parked = layout(task {
            $0.isSomeday = true
            $0.startAt = day(4)
        })
        #expect(parked.chips.filter { $0.kind == .when }.count == 1)
        #expect(parked.chips.first { $0.kind == .when }?.text == "Someday")

        let today = layout(task { $0.todayCommittedOn = day(0) })
        #expect(today.chips.first { $0.kind == .when }?.text == "Today")

        let evening = layout(task {
            $0.todayCommittedOn = day(0)
            $0.isLaterToday = true
        })
        #expect(evening.chips.first { $0.kind == .when }?.text == "This Evening")
    }

    @Test("A deadline is coloured only once it has arrived")
    func onlyPressingDeadlinesAreTinted() {
        #expect(layout(task { $0.deadlineAt = day(30) }).chips.first?.tintName == nil)
        #expect(layout(task { $0.deadlineAt = day(3) }).chips.first?.tintName == nil)
        #expect(layout(task { $0.deadlineAt = day(0) }).chips.first?.tintName == .dueToday)
        #expect(layout(task { $0.deadlineAt = day(-2) }).chips.first?.tintName == .dueToday)
    }

    @Test("A start date reads differently once it has passed, because it is no longer news")
    func startDateTense() {
        #expect(layout(task { $0.startAt = day(4) }).chips.first?.text.hasPrefix("Starts") == true)
        #expect(layout(task { $0.startAt = day(-4) }).chips.first?.text.hasPrefix("Started") == true)
    }

    @Test("A checklist chip offers no way to clear itself")
    func checklistCannotBeClearedWholesale() {
        let chip = layout(task { $0.checklistTotal = 6 }).chips.first
        #expect(chip?.text == "0/6")
        // A single ✕ that silently threw away six steps is not an undo anybody meant to ask for.
        #expect(chip?.isClearable == false)
    }

    @Test("One person is named; several are counted")
    func peopleChipText() {
        let one = layout(task { $0.relatedPersonIDs = [UUID()] }, names: .init(people: ["Ana"]))
        #expect(one.chips.first { $0.kind == .people }?.text == "Ana")

        let several = layout(
            task { $0.relatedPersonIDs = [UUID(), UUID(), UUID()] },
            names: .init(people: ["Ana", "Bo", "Cai"])
        )
        #expect(several.chips.first { $0.kind == .people }?.text == "3 people")
    }

    @Test("Normal priority draws nothing, because it is the absence of a priority")
    func normalPriorityIsNotAValue() {
        let result = layout(task { $0.priority = .normal })
        #expect(result.chips.isEmpty)
        #expect(result.buttons.contains(.priority))
    }
}
