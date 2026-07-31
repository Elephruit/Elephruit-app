import ElephruitCore
import Foundation
import Testing

private let clock = FixedDateProvider.reference  // 2026-06-15 09:00 GMT, a Monday

@Suite("Task entry: the sentences the specification asks for")
struct TaskEntryHeadlineTests {
    @Test("“Call Maya tomorrow at 10”")
    func callMaya() {
        let draft = TaskEntryParser.parse("Call Maya tomorrow at 10")

        #expect(draft.title == "Call Maya")
        // A clock time is a request to be interrupted, so it becomes a reminder — and the start date
        // keeps only the day, so the two are not the same fact written twice.
        #expect(draft.startDate == DateInterpretation(day: .tomorrow))
        #expect(draft.reminder == DateInterpretation(day: .tomorrow, time: TimeOfDay(hour: 10, minute: 0)))
        #expect(draft.deadline == nil)
    }

    @Test("“Send Jordan the proposal today”")
    func sendProposal() {
        let draft = TaskEntryParser.parse("Send Jordan the proposal today")

        #expect(draft.title == "Send Jordan the proposal")
        #expect(draft.startDate?.day == .today)
        #expect(draft.deadline == nil)
        // The crux: a bare date never manufactures a deadline.
        #expect(draft.reminder == nil)
    }

    @Test("“Pay property tax by August 15”")
    func propertyTax() {
        let draft = TaskEntryParser.parse("Pay property tax by August 15")

        #expect(draft.title == "Pay property tax")
        #expect(draft.deadline?.day == .monthDay(month: 8, day: 15))
        #expect(draft.startDate == nil)
    }

    @Test("“Start planning the trip next Monday, deadline September 1”")
    func tripPlanning() {
        let draft = TaskEntryParser.parse("Start planning the trip next Monday, deadline September 1")

        #expect(draft.startDate?.day == .nextWeekday(2))
        #expect(draft.deadline?.day == .monthDay(month: 9, day: 1))
        #expect(draft.title.contains("planning the trip"))
    }

    @Test("“Follow up with Maya in two weeks”")
    func followUpInTwoWeeks() {
        let draft = TaskEntryParser.parse("Follow up with Maya in two weeks")

        #expect(draft.title == "Follow up with Maya")
        #expect(draft.startDate?.day == .weekOffset(2))
    }

    @Test("“Buy milk #groceries”")
    func buyMilk() {
        let draft = TaskEntryParser.parse("Buy milk #groceries")

        #expect(draft.title == "Buy milk")
        #expect(draft.tagSlugs == ["groceries"])
    }

    @Test("“Review contract /Work /Acme”")
    func reviewContract() {
        let draft = TaskEntryParser.parse("Review contract /Work /Acme")

        #expect(draft.title == "Review contract")
        #expect(draft.destinationPath == ["Work", "Acme"])
    }

    @Test("“Someday learn piano”")
    func learnPiano() {
        let draft = TaskEntryParser.parse("Someday learn piano")

        #expect(draft.title == "learn piano")
        #expect(draft.isSomeday)
    }

    @Test("“Every Friday submit timesheet”")
    func timesheet() {
        let draft = TaskEntryParser.parse("Every Friday submit timesheet")

        #expect(draft.title == "submit timesheet")
        #expect(draft.recurrence == RecurrenceRule(frequency: .weekly, weekdays: [6]))
    }

    @Test("“Waiting for Jordan to approve the budget”")
    func waitingForJordan() {
        let draft = TaskEntryParser.parse("Waiting for Jordan to approve the budget")

        #expect(draft.waitingForHint == "Jordan")
        // The phrase stays: "to approve the budget" is a fragment, and the sentence is the task.
        #expect(draft.title == "Waiting for Jordan to approve the budget")
    }

    @Test("“Remind me when I get home to water the plants” says it cannot do that")
    func locationReminderIsDeclinedOutLoud() {
        let draft = TaskEntryParser.parse("Remind me when I get home to water the plants")

        #expect(draft.reminder == nil)
        #expect(draft.unsupportedTokens.count == 1)
        #expect(draft.unsupportedTokens.first?.display == "Location reminder")
        // Nothing is dropped for being unsupported.
        #expect(draft.title.contains("water the plants"))
    }
}

@Suite("Task entry: the raw text is never touched")
struct TaskEntryRawTextTests {
    @Test(
        "Whatever is typed comes back verbatim",
        arguments: [
            "buy   milk",
            "  leading and trailing  ",
            "emoji 🎉 and punctuation!!",
            "a line\nand another",
            "quotes \"like this\" and dashes — here",
            "",
        ]
    )
    func rawTextSurvives(input: String) {
        #expect(TaskEntryParser.parse(input).rawText == input)
    }

    @Test("Runs of whitespace inside a title are collapsed only in the title, not in the source")
    func whitespaceIsOnlyNormalisedInTheTitle() {
        let draft = TaskEntryParser.parse("buy    milk")
        #expect(draft.rawText == "buy    milk")
        #expect(draft.title == "buy milk")
    }

    @Test("Lines after the first become notes")
    func notesAreTheRemainder() {
        let draft = TaskEntryParser.parse("Call the plumber tomorrow\nthe upstairs tap\nand the boiler")
        #expect(draft.title == "Call the plumber")
        #expect(draft.notes == "the upstairs tap\nand the boiler")
    }

    @Test("A capture that is only a paragraph still gets a title")
    func bodyOnlyCaptureGetsATitle() {
        let draft = TaskEntryParser.parse("\nA long thought that begins on the second line.")
        #expect(!draft.title.isEmpty)
    }

    @Test("Every token points at the text it claimed")
    func tokenRangesAreAccurate() {
        let input = "Pay tax by August 15 #finance"
        let draft = TaskEntryParser.parse(input)
        let characters = Array(input)

        for token in draft.tokens {
            #expect(token.range.lowerBound >= 0)
            #expect(token.range.upperBound <= characters.count)
            let quoted = String(characters[token.range])
            #expect(!quoted.isEmpty)
        }

        let tag = draft.tokens.first { $0.kind == .tag }
        #expect(tag.map { String(characters[$0.range]) } == "#finance")
    }
}

@Suite("Task entry: nothing is guessed at")
struct TaskEntryRestraintTests {
    @Test("A weekday used as an adjective is still claimed, and the preview is what makes that safe")
    func aClaimIsAlwaysVisible() {
        // "Friday" here modifies "numbers"; a deterministic parser cannot know that, and it takes
        // the word. That is the honest limit, and it is why the entry surface shows every claim as
        // a token over the text before anything is created — the cost of a wrong reading is one
        // glance, not a mis-scheduled task.
        let draft = TaskEntryParser.parse("Review the Friday numbers with Sam")

        #expect(draft.title == "Review the numbers with Sam")
        #expect(draft.startDate?.day == .nextWeekday(6))
        let token = draft.tokens.first { $0.kind == .startDate }
        #expect(token != nil)
        // The token points at exactly the word it took, so the preview can underline it.
        #expect(token.map { String(Array("Review the Friday numbers with Sam")[$0.range]) } == "Friday")
    }

    @Test("A keyword with nothing usable after it says so and keeps the word")
    func danglingKeyword() {
        let draft = TaskEntryParser.parse("Finish the report by whenever")
        #expect(draft.deadline == nil)
        #expect(draft.title.contains("by"))
        #expect(draft.title.contains("whenever"))
    }

    @Test("An unusable tag keeps its text and explains itself")
    func badTag() {
        let draft = TaskEntryParser.parse("Buy milk #")
        #expect(draft.tagSlugs.isEmpty)
        #expect(draft.title.contains("#"))
    }

    @Test("A date phrase does not swallow the word after it")
    func extensionIsNotSpeculative() {
        let draft = TaskEntryParser.parse("Prepare by Friday meeting notes")
        #expect(draft.deadline?.day == .nextWeekday(6))
        #expect(draft.title.contains("meeting notes"))
    }

    @Test("Parsing is pure: the same text always means the same thing")
    func parsingIsDeterministic() {
        let input = "Call Maya tomorrow at 10 #work !high"
        #expect(TaskEntryParser.parse(input) == TaskEntryParser.parse(input))
    }
}

@Suite("Task entry: sigils")
struct TaskEntrySigilTests {
    @Test("Priority and flag are different things")
    func priorityAndFlag() {
        let draft = TaskEntryParser.parse("Renew insurance !high !!")
        #expect(draft.priority == .high)
        #expect(draft.isFlagged)
        #expect(draft.title == "Renew insurance")
    }

    @Test("A person is linked, not filed")
    func personSigil() {
        let draft = TaskEntryParser.parse("Draft the brief @Maya @Jordan")
        #expect(draft.personHints == ["Maya", "Jordan"])
        #expect(draft.title == "Draft the brief")
    }

    @Test("A project can be named with an angle bracket or a path")
    func destinationSigils() {
        #expect(TaskEntryParser.parse("Ship it >Launch").destinationPath == ["Launch"])
        #expect(TaskEntryParser.parse("Ship it /Work /Launch").destinationPath == ["Work", "Launch"])
    }

    @Test("Explicit keywords beat the bare-date default")
    func keywordsWin() {
        let draft = TaskEntryParser.parse("Renew passport deadline:2026-09-01 start:2026-08-01")
        #expect(draft.deadline?.day == .explicit(year: 2026, month: 9, day: 1))
        #expect(draft.startDate?.day == .explicit(year: 2026, month: 8, day: 1))
        #expect(draft.title == "Renew passport")
    }
}

@Suite("Task entry: repeats")
struct TaskEntryRecurrenceTests {
    @Test("Plain frequencies")
    func plainFrequencies() {
        #expect(TaskEntryParser.parse("Water plants every day").recurrence?.frequency == .daily)
        #expect(TaskEntryParser.parse("Pay rent every month").recurrence?.frequency == .monthly)
        #expect(TaskEntryParser.parse("Review goals yearly").recurrence?.frequency == .yearly)
    }

    @Test("Intervals")
    func intervals() {
        #expect(TaskEntryParser.parse("Bins every 2 weeks").recurrence == RecurrenceRule(frequency: .weekly, interval: 2))
        #expect(TaskEntryParser.parse("Bins every other week").recurrence == RecurrenceRule(frequency: .weekly, interval: 2))
    }

    @Test("Weekdays, one and several")
    func weekdays() {
        #expect(
            TaskEntryParser.parse("Standup every weekday").recurrence
                == RecurrenceRule(frequency: .weekly, weekdays: [2, 3, 4, 5, 6])
        )
        #expect(
            TaskEntryParser.parse("Gym every monday and thursday").recurrence
                == RecurrenceRule(frequency: .weekly, weekdays: [2, 5])
        )
    }

    @Test("A day of the month")
    func dayOfMonth() {
        #expect(
            TaskEntryParser.parse("Invoice every 15th").recurrence
                == RecurrenceRule(frequency: .monthly, dayOfMonth: 15)
        )
    }

    @Test("“after completion” changes what the interval is measured from")
    func completionAnchor() {
        let draft = TaskEntryParser.parse("Water the plants every 3 days after completion")
        #expect(draft.recurrence?.anchor == .completion)
        #expect(draft.recurrence?.interval == 3)
        #expect(draft.title == "Water the plants")
    }
}

@Suite("Checklists")
struct ChecklistTests {
    @Test("Steps are counted, and an empty list is not a finished one")
    func emptyIsNotComplete() {
        #expect(!TaskChecklist().isFullyComplete)
        #expect(TaskChecklist().progress == nil)
    }

    @Test("Progress is a fraction of what exists")
    func progress() {
        var checklist = TaskChecklist()
        checklist.append("one")
        checklist.append("two")
        guard let first = checklist.items.first else {
            Issue.record("append should have added a step")
            return
        }
        checklist.setCompleted(first.id, true, at: clock.now)

        #expect(checklist.progress == 0.5)
        #expect(checklist.completed == 1)
    }

    @Test("Unticking clears the completion date as well as the tick")
    func untickClearsTheStamp() {
        var checklist = TaskChecklist(items: [ChecklistItem(title: "one")])
        guard let id = checklist.items.first?.id else { return }

        checklist.setCompleted(id, true, at: clock.now)
        #expect(checklist.items[0].completedAt != nil)

        checklist.setCompleted(id, false, at: clock.now)
        #expect(checklist.items[0].completedAt == nil)
    }

    @Test("Resetting keeps the steps and drops the ticks — what a repeat needs")
    func resetKeepsTheSteps() {
        var checklist = TaskChecklist(items: [
            ChecklistItem(title: "one", isCompleted: true, completedAt: clock.now),
            ChecklistItem(title: "two"),
        ])
        checklist.reset()

        #expect(checklist.total == 2)
        #expect(checklist.completed == 0)
        #expect(checklist.items.allSatisfy { $0.completedAt == nil })
    }

    @Test("Reordering moves the right step to the right place")
    func reordering() {
        var checklist = TaskChecklist(items: ["a", "b", "c", "d"].map { ChecklistItem(title: $0) })
        checklist.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(checklist.items.map(\.title) == ["b", "c", "a", "d"])

        checklist.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        #expect(checklist.items.map(\.title) == ["d", "b", "c", "a"])
    }

    @Test("Pasted lists are read in the shapes people actually paste")
    func parsing() {
        let checklist = TaskChecklist.parse(
            """
            - passport
            * tickets
            1. currency
            - [x] visa
            - [ ] adapter
            plain line
            """
        )

        #expect(checklist.items.map(\.title) == ["passport", "tickets", "currency", "visa", "adapter", "plain line"])
        #expect(checklist.completed == 1)
        #expect(checklist.items[3].isCompleted)
    }

    @Test("An empty checklist stores nothing at all")
    func emptyStoresNothing() {
        #expect(TaskChecklist().encoded() == nil)
    }

    @Test("A checklist survives a round trip, and unreadable data reads as empty")
    func roundTrip() {
        var checklist = TaskChecklist()
        checklist.append("buy stamps")
        checklist.append("address it")

        #expect(TaskChecklist.decode(from: checklist.encoded()) == checklist)
        #expect(TaskChecklist.decode(from: Data("not json".utf8)).isEmpty)
        #expect(TaskChecklist.decode(from: nil).isEmpty)
    }
}
