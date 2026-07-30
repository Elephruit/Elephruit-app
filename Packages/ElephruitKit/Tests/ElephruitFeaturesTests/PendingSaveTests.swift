import ElephruitFeatures
import Foundation
import Testing

/// The editor's debounce, on its own.
///
/// The property worth asserting is that scheduled work runs **exactly once**, whichever of the timer
/// and the flush gets there first. Before this was a type, it was a `Task` a view juggled, the flush
/// only ran on `onDisappear`, and `onDisappear` does not fire when macOS quits the app — so the
/// half-second of typing that the debounce is happy to hold was the half-second a quit threw away.
@MainActor
@Suite("Pending save")
struct PendingSaveTests {
    @Test("Flushing runs the scheduled work immediately")
    func flushRunsTheWork() {
        let pending = PendingSave(delay: .seconds(60))
        var writes = 0

        pending.schedule { writes += 1 }
        #expect(writes == 0, "the delay had not elapsed")

        pending.flush()
        #expect(writes == 1)
    }

    /// The race a terminate handler creates: the timer may already be running when the flush lands.
    @Test("Work runs once even if the flush and the timer both fire")
    func flushIsIdempotent() async {
        let pending = PendingSave(delay: .milliseconds(10))
        var writes = 0

        pending.schedule { writes += 1 }
        pending.flush()
        try? await Task.sleep(for: .milliseconds(80))

        #expect(writes == 1)
        #expect(pending.isPending == false)
    }

    @Test("Flushing twice does not write twice")
    func doubleFlush() {
        let pending = PendingSave(delay: .seconds(60))
        var writes = 0

        pending.schedule { writes += 1 }
        pending.flush()
        pending.flush()

        #expect(writes == 1)
    }

    @Test("Flushing with nothing scheduled does nothing")
    func flushWithoutWork() {
        let pending = PendingSave(delay: .seconds(60))
        pending.flush()
        #expect(pending.isPending == false)
    }

    /// Each keystroke re-schedules, and only the last text should reach the store.
    @Test("Only the most recent write survives a burst")
    func burstCollapsesToTheLatest() {
        let pending = PendingSave(delay: .seconds(60))
        var written: [String] = []

        pending.schedule { written.append("Th") }
        pending.schedule { written.append("The") }
        pending.schedule { written.append("The p") }
        pending.flush()

        #expect(written == ["The p"])
    }

    @Test("Work still runs on its own once the delay elapses")
    func timerFiresWithoutAFlush() async {
        let pending = PendingSave(delay: .milliseconds(10))
        var writes = 0

        pending.schedule { writes += 1 }
        try? await Task.sleep(for: .milliseconds(120))

        #expect(writes == 1)
        #expect(pending.isPending == false)
    }

    @Test("Cancelling discards the write rather than running it")
    func cancelDiscards() {
        let pending = PendingSave(delay: .seconds(60))
        var writes = 0

        pending.schedule { writes += 1 }
        pending.cancel()
        pending.flush()

        #expect(writes == 0)
    }
}
