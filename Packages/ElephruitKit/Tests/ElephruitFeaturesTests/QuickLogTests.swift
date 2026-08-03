import ElephruitCore
import ElephruitFeatures
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

/// The panel that starts a timer from another application, without the window.
///
/// Everything asserted here is a promise the panel makes in words on screen — the clock starts
/// before anything is named, pressing the keys twice does not produce two entries, closing is not
/// stopping, and a shortcut hit by mistake can be taken back. A window is not needed to check any of
/// them, which is the point of the controller owning them.
@MainActor
@Suite("Quick Log controller")
struct QuickLogControllerTests {
    private func makeController() -> (QuickLogController, AppServices) {
        let services = AppServices.inMemory(populated: false)
        return (services.quickLog, services)
    }

    /// The whole feature in one assertion: the clock is going before anybody has said what it is for.
    @Test("The timer starts before anything has been named")
    func startingComesFirst() {
        let (controller, services) = makeController()

        #expect(controller.startTimerIfIdle())
        #expect(services.timer.running != nil)
        #expect(controller.startedTheTimer)
        #expect(controller.description.isEmpty)
    }

    /// An existing timer is not silently adopted or replaced. The current entry remains exactly as
    /// it was until the user answers the replacement question.
    @Test("An existing timer is preserved while replacement is confirmed")
    func existingTimerWaitsForConfirmation() throws {
        let (controller, services) = makeController()

        services.timer.switchTo(
            item: nil,
            description: "Reviewing the lease",
            tagSlugs: ["legal", "review"],
            isBillable: true
        )
        let first = try #require(services.timer.running?.id)

        #expect(controller.startTimerIfIdle() == false)
        #expect(services.timer.running?.id == first)
        #expect(services.timer.running?.entryDescription == "Reviewing the lease")
        #expect(services.timer.running?.tagSlugs == ["legal", "review"])
        #expect(services.timer.running?.isBillable == true)
        #expect(controller.presentation == .confirmReplacement)
        #expect(controller.description == "Reviewing the lease")
    }

    @Test("Keeping an existing timer does not reinterpret its description")
    func keepingExistingTimerIsReadOnly() {
        let (controller, services) = makeController()
        services.timer.switchTo(item: nil, description: "Reviewing #section 4")
        controller.startTimerIfIdle()

        controller.hide()

        #expect(services.timer.running?.entryDescription == "Reviewing #section 4")
        #expect(services.timer.running?.tagSlugs.isEmpty == true)
    }

    /// Once confirmed, replacement is an explicit switch: the old entry is recorded with its
    /// details and a fresh untitled timer begins.
    @Test("Confirming replacement records the old timer and starts a blank one")
    func replacesWhatIsRunning() throws {
        let (controller, services) = makeController()
        services.timer.switchTo(
            item: nil,
            description: "Reviewing the lease",
            tagSlugs: ["legal"],
            isBillable: true
        )
        let existing = try #require(services.timer.running?.id)

        #expect(controller.startTimerIfIdle() == false)
        #expect(controller.startedTheTimer == false)
        #expect(services.timer.running?.id == existing)
        #expect(controller.description == "Reviewing the lease")

        #expect(controller.replaceRunningTimer())
        #expect(controller.presentation == .editing)
        #expect(controller.startedTheTimer)
        #expect(controller.description.isEmpty)
        #expect(services.timer.running?.id != existing)
        #expect(services.timer.running?.entryDescription.isEmpty == true)

        let oldEntry = try #require(
            try services.timeEntries.recentEntries(limit: 5).first { $0.id == existing }
        )
        #expect(oldEntry.entryDescription == "Reviewing the lease")
        #expect(oldEntry.tagSlugs == ["legal"])
        #expect(oldEntry.isBillable)
        #expect(oldEntry.endedAt != nil)
    }

    /// The sentence in the footer, as a test. Dismissing the panel is a statement about a window, not
    /// about the work — and the name typed into it is written down on the way out rather than lost.
    @Test("Closing writes the name down and leaves the clock running")
    func closingKeepsItRunning() {
        let (controller, services) = makeController()
        controller.startTimerIfIdle()
        controller.description = "Drafting the quarterly note"

        controller.hide()

        #expect(services.timer.running != nil)
        #expect(services.timer.running?.entryDescription == "Drafting the quarterly note")
        #expect(controller.isVisible == false)
    }

    @Test("Inline filing grammar names and files the running timer")
    func inlineFilingGrammar() throws {
        let (controller, services) = makeController()
        let project = try services.items.create(ItemDraft(kind: .project, title: "Website"))
        let person = try services.items.create(ItemDraft(kind: .person, title: "Maya Chen"))
        controller.startTimerIfIdle()
        controller.description = "Review copy #launch >Website @Maya Chen"

        controller.commitDescription()

        let running = try #require(services.timer.running)
        #expect(running.entryDescription == "Review copy")
        #expect(running.tagSlugs == ["launch"])
        #expect(running.projectID == project.id)
        #expect(running.people.map(\.id) == [person.id])
        #expect(controller.description == "Review copy")
    }

    @Test("Stopping keeps both the time and the name")
    func stoppingRecordsTheEntry() throws {
        let (controller, services) = makeController()
        controller.startTimerIfIdle()
        controller.description = "Call with the surveyor"

        controller.stopTimer()

        #expect(services.timer.running == nil)
        let recent = try #require(try services.timeEntries.recentEntries(limit: 5).first)
        #expect(recent.entryDescription == "Call with the surveyor")
        #expect(recent.endedAt != nil)
    }

    /// The answer to keys pressed by accident. Without it a mistaken ⌘⇧L leaves a stray entry to be
    /// hunted down later, which is a worse tax than the mistake was.
    @Test("Discarding leaves nothing behind")
    func discardingLeavesNothing() throws {
        let (controller, services) = makeController()
        controller.startTimerIfIdle()
        controller.description = "pressed by mistake"

        controller.discardTimer()

        #expect(services.timer.running == nil)
        #expect(try services.timeEntries.recentEntries(limit: 5).isEmpty)
        #expect(controller.description.isEmpty)
    }

    /// The panel outlives any one opening of it, so what it shows has to be re-read rather than
    /// remembered — otherwise the second use of the shortcut shows the first use's name.
    @Test("Reopening reads the name off whatever is running")
    func syncingFromTheRunningEntry() {
        let (controller, services) = makeController()
        controller.startTimerIfIdle()
        controller.description = "first thing"
        controller.stopTimer()

        services.timer.switchTo(item: nil, description: "second thing")
        controller.syncFromRunning()

        #expect(controller.description == "second thing")
    }

    /// Nothing running is a state the panel renders rather than a reason to write to an entry that
    /// is no longer there — the menu bar can stop a timer while this window is open.
    @Test("Committing a name with nothing running writes nothing")
    func committingWithoutATimerIsHarmless() throws {
        let (controller, services) = makeController()
        controller.description = "typed at nothing"

        controller.commitDescription()

        #expect(services.timer.running == nil)
        #expect(try services.timeEntries.recentEntries(limit: 5).isEmpty)
    }
}
