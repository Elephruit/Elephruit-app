#if canImport(ActivityKit)
    import ActivityKit
#endif
import Foundation

#if canImport(ActivityKit)

    /// What the Dynamic Island and the Lock Screen are told about a running timer.
    ///
    /// ### Why this file belongs to two targets rather than to a module
    /// It is the contract between the app and its widget extension, and both compile it
    /// directly. A framework would work and would cost the extension the whole of
    /// `ElephruitMobileKit` — SwiftData, the search index, every repository — to learn four
    /// strings and a date. A Live Activity is drawn by a process the system starts and stops at
    /// will, and the cheapest thing it can possibly link is the right amount.
    ///
    /// So this file imports nothing but `ActivityKit` and `Foundation`, and it is the only
    /// place either side is allowed to describe the other's expectations.
    struct ElephruitTimerAttributes: ActivityAttributes {
        /// Everything that can change while one timer runs.
        ///
        /// The elapsed time is deliberately **not** in here. It is derived from `startedAt` by
        /// `Text(timerInterval:)`, which the system animates on its own — pushing a new state
        /// every second would be a rate-limited update per second for a number the widget can
        /// work out for itself, and the first thing to break under it would be the clock.
        struct ContentState: Codable, Hashable {
            /// What the timer is called: the subject if it has one, otherwise the description.
            var title: String

            /// The line under it — project, or who is present. `nil` when there is nothing to
            /// say, rather than an empty string, so the layout closes up rather than leaving a
            /// gap where filing would have gone.
            var detail: String?

            /// Where the clock counts from. The one fact the ticking display needs.
            var startedAt: Date

            var isBillable: Bool

            /// The focus block under way, if there is one.
            var focusPhase: String?

            /// When that block ends, so the island can count it down without being told.
            var focusEndsAt: Date?
        }

        /// Deliberately empty.
        ///
        /// Static attributes are fixed for the life of an activity, so anything put here — the
        /// entry's id, most obviously — would mean ending and restarting the activity every time
        /// the timer switched to a different piece of work. That is a dismissal animation and a
        /// fresh presentation in the Dynamic Island for what the user experienced as renaming
        /// what they are doing. Everything that can change lives in ``ContentState``, and the
        /// activity lasts exactly as long as *a* timer is running.
        init() {}
    }

#endif
