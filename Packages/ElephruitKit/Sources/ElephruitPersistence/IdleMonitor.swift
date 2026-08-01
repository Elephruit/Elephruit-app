import CoreGraphics
import ElephruitCore
import Foundation

/// How long the machine has gone without seeing anybody.
///
/// A protocol with one property, so the idle rules can be tested by handing in a number rather than
/// by not typing for five minutes.
public protocol IdleClock: Sendable {
    /// Seconds since the last keyboard or pointer event, from the machine's point of view.
    var secondsSinceLastInput: TimeInterval { get }
}

/// The real one.
///
/// ### Why this needs no permission
/// `CGEventSource` will report *when* the last input event happened without any entitlement, an
/// accessibility grant, or an event tap — it is a timestamp, not a keystroke. Nothing here can see
/// what was typed, and nothing here would be allowed to. That is the whole reason idle detection
/// can exist in a sandboxed app that asks the user for nothing.
public struct SystemIdleClock: IdleClock {
    public init() {}

    public var secondsSinceLastInput: TimeInterval {
        // `kCGAnyInputEventType` is `~0`, which Swift imports as a failable initialiser rather than
        // a constant. The fallback is unreachable in practice and is here because a force unwrap in
        // shipping code is banned, on the grounds that "unreachable" is what everybody says.
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}

/// Decides when a gap in input becomes a question worth asking.
///
/// ### Why this is a value and not a service
/// The whole of idle detection is one rule — *input stopped for longer than the threshold, and then
/// came back* — and it is a rule with two states and three edges. Kept as a struct fed a number and
/// a clock, every one of those edges is a two-line test. Folded into `TimerService`, where it would
/// sit beside a ticking task, a heartbeat and a store, none of them would be.
public struct IdleDetector {
    /// How long the machine must see nothing before the gap is worth mentioning.
    ///
    /// Five minutes, matching the layout's default. Long enough that reading a page or a phone call at
    /// the desk does not trigger it; short enough that lunch always does.
    public static let defaultThreshold: TimeInterval = 5 * 60

    public var threshold: TimeInterval

    /// When the current gap began, once it passed the threshold. `nil` when somebody is here.
    private var idleSince: Date?

    public init(threshold: TimeInterval = defaultThreshold) {
        self.threshold = threshold
    }

    /// Whether a gap is open right now — used to leave a partly-elapsed gap alone rather than
    /// reporting it before the user has come back to answer for it.
    public var isIdle: Bool { idleSince != nil }

    /// Forgets any open gap without reporting it.
    ///
    /// Called when the machine wakes. A gap that spans a sleep belongs to crash recovery, which can
    /// say precisely how much of it the app was awake for; reporting it here as well would ask the
    /// same question twice in two banners with two different sets of answers.
    public mutating func reset() {
        idleSince = nil
    }

    /// Feeds the detector one observation, and returns the gap that has just ended, if one has.
    ///
    /// - Parameters:
    ///   - secondsSinceInput: what the clock says now.
    ///   - now: the current instant.
    ///   - timerStartedAt: when the running entry began, so a gap cannot be reported as starting
    ///     before the timer it belongs to. `nil` when nothing is running, which closes any open gap
    ///     without reporting it — a gap that ended because the timer stopped is not a question.
    /// - Returns: the closed gap as `(from, to)`, or `nil`.
    public mutating func observe(
        secondsSinceInput: TimeInterval,
        now: Date,
        timerStartedAt: Date?
    ) -> (from: Date, to: Date)? {
        guard let timerStartedAt else {
            idleSince = nil
            return nil
        }

        if secondsSinceInput >= threshold {
            // Still away. The moment it began is recorded once and then left alone, so a gap that
            // spans many ticks reports the instant input stopped rather than the latest tick.
            if idleSince == nil {
                idleSince = max(timerStartedAt, now.addingTimeInterval(-secondsSinceInput))
            }
            return nil
        }

        guard let began = idleSince else { return nil }
        idleSince = nil

        // The gap has to still be worth the threshold after being clipped to the timer's own start:
        // starting a timer and immediately walking away leaves nothing to ask about.
        guard now.timeIntervalSince(began) >= threshold else { return nil }
        return (from: began, to: now)
    }
}
