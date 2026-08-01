import Foundation

/// The lengths a focus cycle runs to.
///
/// ### Why this is configurable at all
/// The received answer is twenty-five and five, and it is a fine default and a poor rule. Work has
/// shapes: a fifty-minute block is the only useful unit for anything that needs loading into your
/// head first, and a fifteen-minute one is what somebody clearing a queue of small corrections
/// actually wants. A timer that insists on twenty-five is a timer people stop using in the second
/// week rather than one that taught them to work in twenty-five minute blocks.
///
/// Every value is clamped on the way in rather than trusted, because these arrive from a settings
/// field and a zero-length focus phase would end the moment it began, forever.
public struct PomodoroPlan: Sendable, Hashable, Codable {
    /// How long a focus block runs.
    public var focus: TimeInterval

    /// The break after an ordinary focus block.
    public var shortBreak: TimeInterval

    /// The break after the last block of a set.
    public var longBreak: TimeInterval

    /// How many focus blocks make a set, after which the long break is offered.
    public var roundsBeforeLongBreak: Int

    /// Whether the break begins on its own when a focus block ends.
    ///
    /// On by default. The whole value of the technique is that the break is not a decision — a break
    /// you have to choose to take is a break you skip on the day you most need it.
    public var startsBreaksAutomatically: Bool

    /// Whether the next focus block begins on its own when a break ends.
    ///
    /// **Off** by default, and the asymmetry with breaks is deliberate. A break that starts by itself
    /// costs nothing if you ignore it. Work that starts by itself begins a *timer against your name*
    /// while you are still in the kitchen, and the entry it writes is one you have to find and
    /// correct later. The direction that can quietly record false time is the direction that asks.
    public var startsNextFocusAutomatically: Bool

    /// The received defaults: twenty-five, five, fifteen, four.
    public static let standard = PomodoroPlan(
        focus: 25 * 60,
        shortBreak: 5 * 60,
        longBreak: 15 * 60,
        roundsBeforeLongBreak: 4,
        startsBreaksAutomatically: true,
        startsNextFocusAutomatically: false
    )

    /// The shortest a phase may be. A minute, because anything less is a stopwatch with a bell.
    public static let minimumPhase: TimeInterval = 60

    /// The longest a phase may be. Four hours, which is past the point the technique means anything
    /// and well short of the typo that would make a phase never end.
    public static let maximumPhase: TimeInterval = 4 * 3_600

    public init(
        focus: TimeInterval,
        shortBreak: TimeInterval,
        longBreak: TimeInterval,
        roundsBeforeLongBreak: Int,
        startsBreaksAutomatically: Bool = true,
        startsNextFocusAutomatically: Bool = false
    ) {
        self.focus = Self.clampPhase(focus)
        self.shortBreak = Self.clampPhase(shortBreak)
        self.longBreak = Self.clampPhase(longBreak)
        self.roundsBeforeLongBreak = min(12, max(1, roundsBeforeLongBreak))
        self.startsBreaksAutomatically = startsBreaksAutomatically
        self.startsNextFocusAutomatically = startsNextFocusAutomatically
    }

    private static func clampPhase(_ value: TimeInterval) -> TimeInterval {
        min(maximumPhase, max(minimumPhase, value.rounded()))
    }

    public func length(of phase: PomodoroPhase) -> TimeInterval {
        switch phase {
        case .focus: focus
        case .shortBreak: shortBreak
        case .longBreak: longBreak
        }
    }

    /// How long a whole set takes, for the sentence settings shows under the fields.
    public var setLength: TimeInterval {
        let rounds = Double(roundsBeforeLongBreak)
        return rounds * focus + (rounds - 1) * shortBreak + longBreak
    }
}

/// Which part of the cycle is running.
public enum PomodoroPhase: String, Sendable, Hashable, CaseIterable, Codable {
    case focus
    case shortBreak
    case longBreak

    public var isBreak: Bool { self != .focus }

    public var displayName: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Break"
        case .longBreak: "Long break"
        }
    }

    public var symbolName: String {
        switch self {
        case .focus: "brain.head.profile"
        case .shortBreak: "cup.and.saucer"
        case .longBreak: "figure.walk"
        }
    }

    /// What to say when this phase ends. Written as a fact and an invitation, never an instruction:
    /// a notification that orders somebody to rest is one they turn off.
    public var completionMessage: String {
        switch self {
        case .focus: "Focus block done. Time to stop for a bit."
        case .shortBreak: "Break over — ready when you are."
        case .longBreak: "Long break over — ready when you are."
        }
    }
}

/// Where a focus cycle has got to.
///
/// A value with no clock of its own: everything is asked *at* a moment, so the same session can be
/// asked what it looks like now, at the moment a notification fired, and in a test at a date that
/// has not happened. The service that owns one ticks it; nothing here schedules anything.
///
/// ### Pause is two fields, not one
/// A paused session keeps the time it has already run in ``elapsedBeforePause`` and forgets when it
/// started, because a start date that stops meaning anything while paused is the shape that makes
/// a pause lose or invent minutes when the machine sleeps through one.
public struct PomodoroSession: Sendable, Hashable {
    public var plan: PomodoroPlan
    public var phase: PomodoroPhase

    /// When the current phase last began running. `nil` while paused.
    public var runningSince: Date?

    /// How much of the current phase had already run when it was paused.
    public var elapsedBeforePause: TimeInterval

    /// Focus blocks finished in this run, which is what decides when the long break is due.
    public var completedFocusRounds: Int

    public init(
        plan: PomodoroPlan,
        phase: PomodoroPhase = .focus,
        runningSince: Date?,
        elapsedBeforePause: TimeInterval = 0,
        completedFocusRounds: Int = 0
    ) {
        self.plan = plan
        self.phase = phase
        self.runningSince = runningSince
        self.elapsedBeforePause = max(0, elapsedBeforePause)
        self.completedFocusRounds = max(0, completedFocusRounds)
    }

    /// Starts a fresh run at the first focus block.
    public static func starting(_ plan: PomodoroPlan, at now: Date) -> PomodoroSession {
        PomodoroSession(plan: plan, phase: .focus, runningSince: now)
    }

    public var isPaused: Bool { runningSince == nil }

    public var phaseLength: TimeInterval { plan.length(of: phase) }

    public func elapsed(at now: Date) -> TimeInterval {
        guard let runningSince else { return elapsedBeforePause }
        return elapsedBeforePause + max(0, now.timeIntervalSince(runningSince))
    }

    /// How much of the phase is left, floored at zero.
    public func remaining(at now: Date) -> TimeInterval {
        max(0, phaseLength - elapsed(at: now))
    }

    /// Nought to one, clamped, for a ring or a bar.
    public func progress(at now: Date) -> Double {
        guard phaseLength > 0 else { return 0 }
        return min(1, max(0, elapsed(at: now) / phaseLength))
    }

    /// Whether the phase is over and the next one is due.
    public func hasFinishedPhase(at now: Date) -> Bool {
        elapsed(at: now) >= phaseLength
    }

    /// Which phase follows this one.
    ///
    /// A break follows focus, and which break depends on whether the set is complete. Focus follows
    /// either break — including a long break, which starts the next set rather than ending the run,
    /// because stopping is something the user does and not something a counter does for them.
    public var nextPhase: PomodoroPhase {
        guard phase == .focus else { return .focus }
        let finished = completedFocusRounds + 1
        return finished % plan.roundsBeforeLongBreak == 0 ? .longBreak : .shortBreak
    }

    /// Whether the phase after this one begins on its own.
    public var nextPhaseStartsAutomatically: Bool {
        phase == .focus ? plan.startsBreaksAutomatically : plan.startsNextFocusAutomatically
    }

    /// The session that follows, whether or not it is running.
    ///
    /// The round counter moves only on a *finished focus block*, so a set cannot be completed by
    /// taking four breaks, and skipping a break does not cost a round somebody has already worked.
    public func advanced(at now: Date, running: Bool) -> PomodoroSession {
        PomodoroSession(
            plan: plan,
            phase: nextPhase,
            runningSince: running ? now : nil,
            elapsedBeforePause: 0,
            completedFocusRounds: phase == .focus ? completedFocusRounds + 1 : completedFocusRounds
        )
    }

    public func paused(at now: Date) -> PomodoroSession {
        guard !isPaused else { return self }
        return PomodoroSession(
            plan: plan,
            phase: phase,
            runningSince: nil,
            elapsedBeforePause: elapsed(at: now),
            completedFocusRounds: completedFocusRounds
        )
    }

    public func resumed(at now: Date) -> PomodoroSession {
        guard isPaused else { return self }
        return PomodoroSession(
            plan: plan,
            phase: phase,
            runningSince: now,
            elapsedBeforePause: elapsedBeforePause,
            completedFocusRounds: completedFocusRounds
        )
    }

    /// Restarts the current phase from the top, keeping the rounds already worked.
    public func restartedPhase(at now: Date) -> PomodoroSession {
        PomodoroSession(
            plan: plan,
            phase: phase,
            runningSince: now,
            elapsedBeforePause: 0,
            completedFocusRounds: completedFocusRounds
        )
    }

    /// Where this is in the set — round three of four — for the line under the clock.
    ///
    /// A break belongs to the round it *follows*, not the one it precedes. Somebody resting after
    /// their fourth block has finished the set, and telling them they are on round one would be the
    /// counter congratulating them for work they have not started.
    public var roundDescription: String {
        let rounds = plan.roundsBeforeLongBreak
        let position: Int = if phase == .focus {
            (completedFocusRounds % rounds) + 1
        } else {
            ((max(1, completedFocusRounds) - 1) % rounds) + 1
        }
        return "Round \(min(max(1, position), rounds)) of \(rounds)"
    }
}
