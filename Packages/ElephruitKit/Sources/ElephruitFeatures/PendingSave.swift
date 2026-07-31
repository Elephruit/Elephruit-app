import Foundation

/// A debounced write that can always be forced to happen *now*.
///
/// ### Why this is a type rather than a `Task` in a view
/// The editor debounces by half a second, which is the right trade while the app is running and the
/// wrong one at the moment it stops: a quit, or a switch to another app, is exactly when the pending
/// half-second matters and exactly when nothing was flushing it. The flush lived on `onDisappear`,
/// which does not fire on quit.
///
/// Making the debounce a value the view owns rather than a `Task` it juggles means the property that
/// matters — *scheduled work always runs exactly once, whether the timer or the flush gets there
/// first* — is assertable without a window.
///
/// The work is supplied at `schedule` rather than at `init`, because each keystroke needs to write
/// the text as it stands *then*. Storing one closure at construction would capture the first value
/// and save it forever.
@MainActor
public final class PendingSave {
    private var task: Task<Void, Never>?
    private var work: (() -> Void)?
    private let delay: Duration

    public init(delay: Duration = .milliseconds(500)) {
        self.delay = delay
    }

    /// Whether a write is waiting.
    public var isPending: Bool { work != nil }

    /// Replaces any scheduled write with this one, restarting the delay.
    public func schedule(_ work: @escaping () -> Void) {
        self.work = work
        task?.cancel()
        task = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.run()
        }
    }

    /// Runs the scheduled write immediately. Does nothing if there is none.
    ///
    /// Safe to call from a terminate handler: it is synchronous, so the write completes before the
    /// caller returns rather than being handed to a runloop that is about to stop existing.
    public func flush() {
        task?.cancel()
        task = nil
        run()
    }

    /// Discards the scheduled write without running it.
    public func cancel() {
        task?.cancel()
        task = nil
        work = nil
    }

    /// Clears the work *before* running it, so a flush racing the timer cannot write twice.
    private func run() {
        guard let work else { return }
        self.work = nil
        work()
    }
}
