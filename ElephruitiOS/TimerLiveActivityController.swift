import ActivityKit
import ElephruitCore
import ElephruitFeaturesCore
import Foundation
import Observation

/// Keeps the Dynamic Island in step with the timer.
///
/// ### Why this is a controller rather than a call at each command
/// Because there are eleven ways to change what is running — start, switch, stop, pause,
/// resume, restart, discard, a focus block beginning or ending, a recovery being resolved, and
/// the other device doing any of it — and a Live Activity that is started by ten of them and
/// ended by nine is one that outlives its timer. So nothing here is called by a command.
/// Instead the whole of the timer's public state is reduced to one value, and this object's job
/// is to make the system's copy equal to it: no value means no activity, a new value means an
/// update, and a value where there was none means a request. Every path through the timer ends
/// somewhere in that one comparison, including the paths nobody has written yet.
@MainActor
@Observable
final class TimerLiveActivityController {
    /// The activity this app is currently showing, by id.
    ///
    /// ### Why an id and not the activity
    /// `Activity` is a non-`Sendable` class, and every method that changes one is `nonisolated
    /// async` — so holding the object here would mean handing a main-actor value to another
    /// isolation domain on every update, which Swift 6 refuses outright and is right to. The id
    /// is a `String`: it crosses freely, and the object is fetched and used entirely inside the
    /// one asynchronous context that needs it.
    @ObservationIgnored private var activityID: String?

    /// Whatever this process left running last time.
    ///
    /// A Live Activity outlives the app that started it — that is the point of one — so a fresh
    /// launch can find its own activity from before the last quit still on the Lock Screen.
    /// Adopting it rather than requesting a second one is what stops a phone accumulating a
    /// stack of identical timers, each counting from a different morning.
    func adoptExisting() {
        activityID = Activity<ElephruitTimerAttributes>.activities.first?.id
    }

    /// Makes the system's copy equal to `state`.
    func apply(_ state: ElephruitTimerAttributes.ContentState?) {
        guard let state else {
            end()
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            // Turned off in Settings. Not an error and not worth a banner: the timer is running,
            // the app says so, and the person has already told the system what they want.
            end()
            return
        }

        if let activityID {
            Task { await Self.update(activityID, to: state) }
            return
        }

        do {
            let activity = try Activity.request(
                attributes: ElephruitTimerAttributes(),
                content: ActivityContent(state: state, staleDate: nil),
                // No push token: everything this activity will ever say is derivable from a
                // start date the widget already has, so it needs neither a server nor an
                // entitlement to keep counting.
                pushType: nil
            )
            activityID = activity.id
        } catch {
            Diagnostics.features.error(
                "Live Activity refused: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Takes the activity down now rather than leaving it to expire.
    ///
    /// `.immediate` because the timer has stopped: a dismissal policy that left the banner up
    /// for four hours would leave a clock on the Lock Screen counting time nobody is working,
    /// which is the exact failure this whole slice exists to remove.
    private func end() {
        guard let identifier = activityID else { return }
        activityID = nil
        Task { await Self.end(identifier) }
    }

    private nonisolated static func update(
        _ identifier: String,
        to state: ElephruitTimerAttributes.ContentState
    ) async {
        guard let activity = activity(identifier) else { return }
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    private nonisolated static func end(_ identifier: String) async {
        guard let activity = activity(identifier) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    private nonisolated static func activity(_ identifier: String) -> Activity<ElephruitTimerAttributes>? {
        Activity<ElephruitTimerAttributes>.activities.first { $0.id == identifier }
    }
}

extension ElephruitTimerAttributes.ContentState {
    /// What the island should be saying, given the services — or `nil` when it should be saying
    /// nothing.
    ///
    /// ### Why the focus deadline is computed rather than read
    /// `PomodoroSession.remaining(at:)` takes the current moment, so a value built from it would
    /// differ on every redraw and this whole state would look like it had changed sixty times a
    /// minute. The end *date* is a fact about the session — when it started and how long the
    /// phase is — and it does not move until the phase does.
    @MainActor
    static func current(_ services: AppServices?) -> Self? {
        guard let services, let running = services.timer.running else { return nil }

        let session = services.timer.pomodoro
        var focusEndsAt: Date?
        if let session, let since = session.runningSince {
            focusEndsAt = since.addingTimeInterval(session.phaseLength - session.elapsedBeforePause)
        }

        return Self(
            title: running.displayTitle,
            detail: detail(for: running),
            startedAt: running.startedAt,
            isBillable: running.isBillable,
            focusPhase: session?.phase.displayName,
            focusEndsAt: focusEndsAt
        )
    }

    /// The second line: the project, or the subject when the title is already the description.
    ///
    /// Never the people, and never the note. A Lock Screen is readable by whoever is holding the
    /// phone, and `docs/29` refuses to put somebody's name on a surface they did not agree to
    /// appear on — a shared calendar there, a stranger's glance here, the same rule.
    private static func detail(for running: RunningTimer) -> String? {
        if let project = running.projectTitle, !project.isEmpty { return project }
        if running.itemTitle != nil, !running.entryDescription.isEmpty {
            return running.entryDescription
        }
        return nil
    }
}
