import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// What the timer does when the other device moves it.
///
/// ### How "the other device" is staged
/// A second `ModelContext` over the same container. That is the honest shape of an import: the
/// change lands in the store through something the service knows nothing about, and the service's
/// own cached `running` snapshot is left describing a world that no longer exists. Whether the
/// bytes arrived over CloudKit or from a context in the same process makes no difference to the
/// only question these tests ask — does the service converge when it is told to look again.
@MainActor
@Suite("Timer sync")
struct TimerSyncTests {
    private struct Stage {
        let stack: PersistenceStack
        let service: TimerService
        /// The repository the service reads through.
        let here: SwiftDataTimeEntryRepository
        /// A second context over the same store: the other device.
        let elsewhere: SwiftDataTimeEntryRepository
    }

    private func stage(clock: FixedDateProvider = .reference) throws -> Stage {
        let stack = try PersistenceStack.inMemory()

        let localContext = ModelContext(stack.container)
        let here = SwiftDataTimeEntryRepository(
            context: localContext,
            dateProvider: clock,
            tags: SwiftDataTagRepository(context: localContext, dateProvider: clock)
        )

        let remoteContext = ModelContext(stack.container)
        let elsewhere = SwiftDataTimeEntryRepository(
            context: remoteContext,
            dateProvider: clock,
            tags: SwiftDataTagRepository(context: remoteContext, dateProvider: clock)
        )

        return Stage(
            stack: stack,
            service: TimerService(entries: here, dateProvider: clock),
            here: here,
            elsewhere: elsewhere
        )
    }

    @Test("A timer stopped on another device stops here")
    func remoteStopStopsTheClock() throws {
        let stage = try stage()
        stage.service.start()
        defer { stage.service.shutDown() }

        stage.service.start(item: nil, description: "Drafting the brief")
        #expect(stage.service.isRunning)

        try stage.elsewhere.stopRunning(at: nil)
        stage.service.absorbRemoteChange()

        #expect(stage.service.running == nil)
        #expect(stage.service.elapsed == 0)
    }

    @Test("A timer started on another device is adopted here")
    func remoteStartIsAdopted() throws {
        let stage = try stage()
        stage.service.start()
        defer { stage.service.shutDown() }

        #expect(!stage.service.isRunning)

        try stage.elsewhere.start(item: nil, description: "On the train", tagSlugs: [])
        stage.service.absorbRemoteChange()

        #expect(stage.service.running?.entryDescription == "On the train")
    }

    @Test("Two devices timing at once are reconciled into one")
    func concurrentTimersAreReconciled() throws {
        let stage = try stage()
        stage.service.start()
        defer { stage.service.shutDown() }

        stage.service.start(item: nil, description: "Started here")

        // Inserted rather than started through the repository, because `start` refuses while
        // something is running — which is exactly the guard two offline devices cannot enforce
        // between them, and the state an import produces.
        let context = ModelContext(stage.stack.container)
        let second = TimeEntry(
            startedAt: FixedDateProvider.reference.now.addingTimeInterval(60),
            entryDescription: "Started on the phone"
        )
        context.insert(second)
        try context.save()

        stage.service.absorbRemoteChange()

        #expect(stage.service.running?.entryDescription == "Started on the phone")
        #expect(stage.service.reconciledTimerCount == 1)
    }

    @Test("A focus cycle does not outlive the entry it was counting")
    func focusEndsWithARemoteStop() throws {
        let stage = try stage()
        stage.service.start()
        defer { stage.service.shutDown() }

        stage.service.startFocus(description: "Deep work")
        #expect(stage.service.isFocusing)

        try stage.elsewhere.stopRunning(at: nil)
        stage.service.absorbRemoteChange()

        #expect(stage.service.pomodoro == nil)
        #expect(!stage.service.isFocusing)
    }

    @Test("An entry closed elsewhere is announced like any other ending")
    func remoteStopAnnouncesTheEnding() throws {
        let stage = try stage()
        stage.service.start()
        defer { stage.service.shutDown() }

        var finished: [UUID] = []
        stage.service.onEntryFinished = { finished.append($0) }

        stage.service.start(item: nil, description: "Billable call")
        let identifier = try #require(stage.service.running?.id)

        try stage.elsewhere.stopRunning(at: nil)
        stage.service.absorbRemoteChange()

        #expect(finished == [identifier])
    }

    @Test("An import that changed nothing leaves the sitting alone")
    func anUnrelatedImportKeepsTheCycle() throws {
        let stage = try stage()
        stage.service.start()
        defer { stage.service.shutDown() }

        stage.service.startFocus(description: "Deep work")
        let identifier = try #require(stage.service.running?.id)

        // Somebody else's change: a finished entry from yesterday arriving late.
        try stage.elsewhere.addManual(
            item: nil,
            project: nil,
            people: [],
            description: "Yesterday's review",
            startedAt: FixedDateProvider.reference.now.addingTimeInterval(-86_400),
            endedAt: FixedDateProvider.reference.now.addingTimeInterval(-82_800),
            tagSlugs: [],
            isBillable: false
        )
        stage.service.absorbRemoteChange()

        #expect(stage.service.running?.id == identifier)
        #expect(stage.service.isFocusing)
    }

    @Test("A pause is over once the work is being timed again elsewhere")
    func aRemoteResumeEndsThePause() throws {
        let stage = try stage()
        stage.service.start()
        defer { stage.service.shutDown() }

        stage.service.start(item: nil, description: "Half-written section")
        stage.service.pause()
        #expect(stage.service.paused != nil)

        try stage.elsewhere.start(item: nil, description: "Half-written section", tagSlugs: [])
        stage.service.absorbRemoteChange()

        #expect(stage.service.paused == nil)
        #expect(stage.service.isRunning)
    }
}
