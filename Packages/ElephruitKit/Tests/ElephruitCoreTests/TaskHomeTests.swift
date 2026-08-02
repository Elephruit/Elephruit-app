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

private func home(_ facts: TaskFacts) -> TaskSystemView {
    TaskHome.systemView(for: facts, now: now, calendar: calendar)
}

/// ### Why "where does this task live" became a question
/// A task used to be openable anywhere: select it and a detail pane drew it. It now opens by making
/// its own row taller in the list it lives in, so following a backlink to a task is a *navigation* —
/// and a navigation to the wrong list is a click that appears to do nothing.
@Suite("A loose task can always be found somewhere that draws it")
struct TaskHomeTests {
    @Test("Each state lands in the view that actually holds it")
    func eachStateHasAHome() {
        #expect(home(task { $0.hasHome = false }) == .inbox)
        #expect(home(task { $0.isSomeday = true }) == .someday)
        #expect(home(task { $0.todayCommittedOn = day(0) }) == .today)
        #expect(home(task()) == .anytime)
    }

    @Test("Finished work goes to the Logbook rather than to a list of open work")
    func resolvedWorkGoesToTheLogbook() {
        let done = task {
            $0.status = .completed
            $0.completedAt = now
        }
        #expect(home(done) == .completed)

        let abandoned = task {
            $0.status = .cancelled
            $0.cancelledAt = now
        }
        #expect(home(abandoned) == .completed)
    }

    @Test("A task not yet started is sent to Anytime, never to Upcoming")
    func upcomingIsNeverTheAnswer() {
        let later = task { $0.startAt = day(20) }

        // The task genuinely *is* in Upcoming — but Upcoming is drawn as an agenda of days rather
        // than as a list of rows, so a card cannot open there. Sending somebody to a surface that
        // cannot show them what they clicked is worse than sending them to the second-best list,
        // where the same task appears the moment its date arrives.
        #expect(home(later) != .upcoming)
    }

    @Test("Every answer is a view a card can open in")
    func everyAnswerIsCardCapable() {
        let states: [TaskFacts] = [
            task { $0.hasHome = false },
            task { $0.isSomeday = true },
            task { $0.todayCommittedOn = day(0) },
            task { $0.startAt = day(20) },
            task { $0.deadlineAt = day(-3) },
            task { $0.waitingSince = day(-1) },
            task { $0.status = .completed; $0.completedAt = now },
            task(),
        ]

        // Upcoming is the agenda and has no rows to grow; every other system view is a list of task
        // rows, which is what a card is.
        for facts in states {
            #expect(home(facts) != .upcoming, "\(home(facts)) cannot open a card")
        }
    }
}
