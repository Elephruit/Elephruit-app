import ElephruitCore
import ElephruitFeatures
import ElephruitModel
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

    /// A global shortcut is pressed by reflex, and often twice. Producing a fresh untitled entry each
    /// time would fill a log with rubbish faster than anybody could delete it.
    @Test("Pressing it again does not start a second timer")
    func askingTwiceStartsOnce() throws {
        let (controller, services) = makeController()

        #expect(controller.startTimerIfIdle())
        let first = try #require(services.timer.running?.id)

        #expect(controller.startTimerIfIdle() == false)
        #expect(services.timer.running?.id == first)
    }

    /// Pressing a shortcut is not a decision to end the work you are in the middle of. The panel
    /// arrives over what is already running, carrying the name it already has.
    @Test("A timer already running is adopted, not switched away from")
    func adoptsWhatIsRunning() throws {
        let (controller, services) = makeController()
        services.timer.switchTo(item: nil, description: "Reviewing the lease")
        let existing = try #require(services.timer.running?.id)

        #expect(controller.startTimerIfIdle() == false)
        #expect(controller.startedTheTimer == false)
        #expect(services.timer.running?.id == existing)
        #expect(controller.description == "Reviewing the lease")
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
