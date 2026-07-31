import AppKit
import ElephruitCore
import SwiftUI

/// One action revealed by a swipe.
///
/// The handler is supplied by the list, never by this file: what "delete" means differs between a
/// task linked to a reminder, a note, and a row that is already in the Trash, and a shared gesture
/// layer that decided any of that would be deciding it wrongly for two of the three.
@MainActor
public struct SwipeAction: Identifiable {
    public enum Role: Sendable, Hashable {
        case standard

        /// Drawn in red, and eligible to be what a full swipe runs.
        case destructive
    }

    public var id: String
    public var title: String
    public var systemImage: String

    /// The glyph shown once a full swipe has passed its threshold, if it differs.
    ///
    /// A filled variant of the same symbol, usually. The change is the clearest signal available
    /// that letting go now will do something, and it costs no room.
    public var armedSystemImage: String?

    public var role: Role
    public var tint: Color

    /// Whether a full swipe on this side runs this action. At most one per side.
    public var isFullSwipeDefault: Bool

    public var handler: () -> Void

    public init(
        id: String,
        title: String,
        systemImage: String,
        armedSystemImage: String? = nil,
        role: Role = .standard,
        tint: Color? = nil,
        isFullSwipeDefault: Bool = false,
        handler: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.armedSystemImage = armedSystemImage
        self.role = role
        self.tint = tint ?? (role == .destructive ? Theme.Colors.destructive : Theme.Colors.selection)
        self.isFullSwipeDefault = isFullSwipeDefault
        self.handler = handler
    }
}

/// The one open row, and the trackpad.
///
/// ### Why a coordinator rather than a gesture on each row
/// Two things are true of swipe actions that a per-row gesture cannot express. Only one row may be
/// open at a time, which is a fact about the *list*; and a two-finger trackpad swipe is a scroll
/// event, which arrives at the window rather than at a view. So there is one of these per window: it
/// watches scroll events, routes them to whichever row the pointer is over, and owns the answer to
/// "which row is open".
///
/// ### Why scroll events rather than a drag gesture
/// A two-finger swipe on a trackpad has no button held down, so it is not a drag and SwiftUI's
/// `DragGesture` never sees it. Reading `NSEvent.scrollWheel` is how Mail does this and is the only
/// way to get the gesture people actually make. Consuming the event only once the direction lock has
/// chosen horizontal is what keeps ordinary scrolling untouched.
@MainActor
@Observable
public final class SwipeActionCoordinator {
    /// The row whose actions are exposed, if any.
    public private(set) var openRow: AnyHashable?
    public private(set) var openSide: SwipeSide = .trailing

    /// The row a gesture is currently moving.
    public private(set) var trackingRow: AnyHashable?

    /// How far that gesture has travelled. Positive uncovers the leading actions.
    public private(set) var translation: CGFloat = 0

    /// Whether letting go now would run the default action.
    public private(set) var isArmed = false

    @ObservationIgnored private var hoveredRow: AnyHashable?
    @ObservationIgnored private var geometry: [AnyHashable: SwipeGesture] = [:]

    /// The row a gesture might belong to, from the moment it starts until the lock decides.
    @ObservationIgnored private var candidate: AnyHashable?
    @ObservationIgnored private var accumulatedX: CGFloat = 0
    @ObservationIgnored private var accumulatedY: CGFloat = 0
    @ObservationIgnored private var hasGivenUp = false

    /// Rows with an action in flight, so a gesture and a click landing together delete once.
    @ObservationIgnored private var performing: Set<AnyHashable> = []

    /// The monitor tokens, in something that can clean up after itself.
    ///
    /// A box rather than two stored properties, because a `@MainActor` type's `deinit` is not
    /// isolated and so cannot read them. Putting them behind an object whose own `deinit` removes
    /// them means the monitors go when the window does, without the owner having to remember —
    /// which is exactly the promise `GlobalHotKeyCenter` could not make and documents not making.
    @ObservationIgnored private let monitors = EventMonitorBox()

    public init() {
        install()
    }

    // MARK: - Row registration

    /// Tells the coordinator a row's shape. Called when the row is laid out, and on resize.
    public func setGeometry(_ gesture: SwipeGesture, for row: AnyHashable) {
        guard geometry[row] != gesture else { return }
        geometry[row] = gesture
    }

    public func forget(_ row: AnyHashable) {
        geometry.removeValue(forKey: row)
        if hoveredRow == row { hoveredRow = nil }
        if candidate == row { candidate = nil }
        if trackingRow == row { endTracking() }
        if openRow == row { openRow = nil }
    }

    public func setHovered(_ row: AnyHashable, _ isHovered: Bool) {
        if isHovered {
            hoveredRow = row
        } else if hoveredRow == row {
            hoveredRow = nil
        }
    }

    // MARK: - What a row draws

    /// Where a row's content sits.
    public func offset(for row: AnyHashable) -> CGFloat {
        let gesture = geometry[row] ?? SwipeGesture()

        if trackingRow == row {
            return gesture.offset(forTranslation: translation)
        }
        if openRow == row {
            return gesture.restingOffset(for: openSide)
        }
        return 0
    }

    public func isOpen(_ row: AnyHashable) -> Bool { openRow == row }

    /// Whether this row is the one about to run its default action.
    public func isArmed(_ row: AnyHashable) -> Bool { isArmed && trackingRow == row }

    /// The side a row is currently showing, if it is showing one.
    public func exposedSide(for row: AnyHashable) -> SwipeSide? {
        if trackingRow == row, abs(translation) >= SwipeMetrics.minimumTravel {
            return SwipeGesture.side(of: translation)
        }
        if openRow == row { return openSide }
        return nil
    }

    // MARK: - Closing

    /// Closes whatever is open. Returns whether anything was.
    ///
    /// The return value is what lets Escape fall through to the next rung of the ladder when there
    /// was nothing to close, rather than swallowing the key.
    @discardableResult
    public func closeAll() -> Bool {
        let wasOpen = openRow != nil || trackingRow != nil
        openRow = nil
        endTracking()
        return wasOpen
    }

    private func endTracking() {
        trackingRow = nil
        translation = 0
        isArmed = false
        candidate = nil
        accumulatedX = 0
        accumulatedY = 0
        hasGivenUp = false
    }

    // MARK: - Running an action

    /// Runs an action once, however many times it is asked for.
    ///
    /// A full swipe that completes at the same moment as a click on the button it was expanding is
    /// two requests to delete one row, arriving in the same turn of the run loop. The guard is
    /// released on the next turn, which is long enough to cover that and short enough that a
    /// genuine second deletion a moment later still happens.
    public func perform(_ action: SwipeAction, on row: AnyHashable) {
        guard performing.insert(row).inserted else { return }

        closeAll()
        action.handler()

        Task { @MainActor [weak self] in
            self?.performing.removeAll()
        }
    }

    // MARK: - The trackpad

    /// Installs the two monitors.
    ///
    /// Both hand the event across to the main actor as a *decision* rather than as an event:
    /// `assumeIsolated` may only return something `Sendable`, and an `NSEvent` is not. So the
    /// isolated half answers "consume it?" and this half does the consuming, which is also the
    /// clearer division — the coordinator decides, the monitor obeys.
    private func install() {
        monitors.add(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consume = MainActor.assumeIsolated { self?.shouldConsume(scroll: event) ?? false }
            return consume ? nil : event
        })

        // Clicking somewhere other than the open row closes it. Clicking *on* it is left alone, so
        // the buttons that were just revealed can actually be pressed — which is the failure mode a
        // blanket "close on any click" would have. The event is always passed on: closing a row is
        // not a reason to swallow somebody's click.
        monitors.add(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.closeIfClickedAway() }
            return event
        })
    }

    private func closeIfClickedAway() {
        guard let openRow, hoveredRow != openRow else { return }
        closeAll()
    }

    /// Decides whether a scroll event is a swipe, and so should be swallowed.
    ///
    /// Answering `false` is what leaves ordinary scrolling — and every mouse wheel, which has no
    /// precise deltas and is therefore never a swipe — exactly as it was.
    private func shouldConsume(scroll event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return false }

        // Momentum is the glide after the fingers have left. A row that kept opening through it
        // would open further than anybody asked for, so the gesture ends when the touch does.
        guard event.momentumPhase.isEmpty else {
            return trackingRow != nil
        }

        switch event.phase {
        case .began:
            candidate = hoveredRow
            accumulatedX = 0
            accumulatedY = 0
            hasGivenUp = candidate == nil
            return false

        case .changed:
            return handleChange(event)

        case .ended, .cancelled:
            if trackingRow != nil {
                settle()
                return true
            }
            candidate = nil
            hasGivenUp = false
            return false

        default:
            return false
        }
    }

    private func handleChange(_ event: NSEvent) -> Bool {
        // `scrollingDeltaX` is positive for the gesture that reveals content to the left — the same
        // one that slides a row to the right and uncovers its leading actions. The sign convention
        // in `SwipeGesture` is written to match, so the arithmetic and the trackpad agree.
        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY

        if let trackingRow {
            translation += deltaX
            let gesture = geometry[trackingRow] ?? SwipeGesture()
            updateArmed(gesture.isPastFullSwipe(translation: translation))
            return true
        }

        guard !hasGivenUp, let candidate else { return false }

        accumulatedX += deltaX
        accumulatedY += deltaY

        if SwipeGesture.isVertical(deltaX: accumulatedX, deltaY: accumulatedY) {
            // A scroll. Left alone for the rest of this gesture, however far sideways it wanders
            // later — a lock that could be un-picked mid-flick is not a lock.
            hasGivenUp = true
            return false
        }

        guard SwipeGesture.isHorizontal(deltaX: accumulatedX, deltaY: accumulatedY) else {
            return false
        }

        // Only one row is ever open, and beginning a swipe on another is one of the ways of saying
        // so.
        if openRow != candidate { openRow = nil }

        trackingRow = candidate
        translation = accumulatedX
        return true
    }

    private func settle() {
        guard let row = trackingRow else { return }
        let gesture = geometry[row] ?? SwipeGesture()
        let outcome = gesture.outcome(forTranslation: translation)

        switch outcome {
        case .closed:
            openRow = nil
            endTracking()

        case .open(let side):
            openSide = side
            openRow = row
            endTracking()

        case .commit(let side):
            endTracking()
            openRow = nil
            pendingCommit = (row, side)
        }
    }

    /// A full swipe that has landed, waiting for the row to run its own default action.
    ///
    /// Held rather than run here because the coordinator does not know what any action *is* — the
    /// list supplies those — and reaching for a handler it was never given would be the shared
    /// layer deciding what delete means.
    @ObservationIgnored public private(set) var pendingCommit: (row: AnyHashable, side: SwipeSide)?

    /// Claims a landed full swipe, if it belongs to this row. Clears it either way.
    public func takeCommit(for row: AnyHashable) -> SwipeSide? {
        guard let pendingCommit, pendingCommit.row == row else { return nil }
        self.pendingCommit = nil
        return pendingCommit.side
    }

    private func updateArmed(_ armed: Bool) {
        guard armed != isArmed else { return }
        isArmed = armed

        // The threshold is invisible, so it is announced by feel. `.alignment` is the same tick the
        // system uses when a window snaps to a guide: brief, and unmistakably a boundary.
        if armed {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }
}

/// Holds event-monitor tokens and removes them when it goes.
///
/// Deliberately *not* actor-isolated. A `@MainActor` type's `deinit` is not isolated and so cannot
/// read its own stored properties, which is why the tokens cannot live on the coordinator itself.
/// An ordinary class has an ordinary `deinit`, and the monitors go when the window does without the
/// owner having to remember — which is exactly the promise `GlobalHotKeyCenter` documents not
/// being able to make.
private final class EventMonitorBox {
    private var tokens: [Any] = []

    func add(_ token: Any?) {
        guard let token else { return }
        tokens.append(token)
    }

    deinit {
        for token in tokens { NSEvent.removeMonitor(token) }
    }
}

// MARK: - Environment

extension EnvironmentValues {
    /// The window's swipe coordinator.
    ///
    /// Optional, and absent by default, so a view drawn outside a window — a preview, a test host —
    /// simply has no swipe actions rather than constructing an event monitor it will never use.
    @Entry public var swipeActions: SwipeActionCoordinator?
}

extension View {
    public func swipeActionCoordinator(_ coordinator: SwipeActionCoordinator) -> some View {
        environment(\.swipeActions, coordinator)
    }
}
