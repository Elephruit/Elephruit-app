import Foundation

/// Which edge of a row a set of swipe actions sits against.
///
/// The names are the edges the actions are *revealed from*, matching the vocabulary SwiftUI already
/// uses: swiping the content left uncovers the **trailing** actions, and swiping it right uncovers
/// the **leading** ones.
public enum SwipeSide: String, Sendable, Hashable, Codable, CaseIterable {
    case leading
    case trailing
}

/// What a swipe should do once the fingers leave the trackpad.
public enum SwipeOutcome: Sendable, Hashable {
    /// Snap shut. Nothing happened.
    case closed

    /// Rest with the actions on this side exposed, waiting to be clicked.
    case open(SwipeSide)

    /// Run this side's default action now. The gesture went far enough to *be* the action.
    case commit(SwipeSide)
}

/// The measurements and thresholds a swipe is decided by.
///
/// Separated from the view so that "how far is far enough" is a number in one place with a test
/// against it, rather than a constant buried in a gesture handler where the only way to check it is
/// to swipe at it. Every value here was chosen for a Mac trackpad, where a deliberate two-finger
/// swipe travels a long way and an accidental one is mostly vertical.
public enum SwipeMetrics {
    /// One action button's width. Wide enough for a glyph and a short word at the standard text
    /// size; the button grows with the text, and this is the floor rather than the truth.
    public static let actionWidth: CGFloat = 78

    /// How far a gesture must travel horizontally before anything is drawn.
    ///
    /// Below this the row does not move at all. A list is scrolled far more often than it is
    /// swiped, and the cost of a row twitching under every flick is much higher than the cost of
    /// the first eight points of a real swipe being invisible.
    public static let minimumTravel: CGFloat = 8

    /// How much more horizontal than vertical a gesture must be to count as a swipe.
    ///
    /// The direction lock. A trackpad scroll is never perfectly vertical — fingers drift — so a
    /// simple `|dx| > |dy|` would turn a fast scroll into a row full of half-open delete buttons.
    public static let directionLockRatio: CGFloat = 1.5

    /// The fraction of the resting width a gesture must reach to settle open rather than snap shut.
    public static let openFraction: CGFloat = 0.5

    /// The fraction of the row's width a gesture must reach to commit its default action.
    ///
    /// Deliberately more than half. A full swipe deletes something, and a threshold that could be
    /// crossed by a generous ordinary swipe would make deletion something that happens *to* people.
    public static let fullSwipeFraction: CGFloat = 0.62

    /// Resistance past the resting position, where there is nothing further to reveal.
    public static let rubberBand: CGFloat = 0.3

    /// The furthest a row will move toward a side that has no actions at all.
    public static let deadSideLimit: CGFloat = 22
}

/// The sidebar change requested by a horizontal two-finger trackpad gesture.
public enum SidebarSwipeDirection: Sendable, Hashable {
    case hide
    case show
}

/// Decides when a window-level horizontal swipe is deliberate enough to change the sidebar.
///
/// The direction lock is shared with row swipes, but changing the whole window waits for more
/// travel than merely beginning to reveal a row. That keeps a small sideways wobble in an empty
/// scrolling area from rearranging the shell.
public enum SidebarSwipeGesture {
    public static let activationTravel: CGFloat = 40

    public static func direction(forTranslation translation: CGFloat) -> SidebarSwipeDirection? {
        guard abs(translation) >= activationTravel else { return nil }
        return translation < 0 ? .hide : .show
    }
}

/// One row's swipe, as arithmetic.
///
/// ### The sign convention
/// A positive translation moves the row's content to the **right**, uncovering the leading actions.
/// A negative one moves it left, uncovering the trailing ones — which is where Delete lives, and
/// which is why "swipe left to delete" is a negative number throughout.
///
/// Everything here is a pure function of the translation and the row's shape. That is what makes
/// the thresholds testable without a trackpad, and it is the half of this feature that could
/// otherwise only be checked by feel.
public struct SwipeGesture: Sendable, Hashable {
    public var leadingCount: Int
    public var trailingCount: Int
    public var rowWidth: CGFloat

    /// Whether a long swipe on this side runs its default action rather than merely opening.
    ///
    /// Held per side because they are not symmetrical in practice: a full swipe left deletes, and a
    /// full swipe right marking something complete is a good deal more surprising than it sounds.
    public var allowsFullSwipeLeading: Bool
    public var allowsFullSwipeTrailing: Bool

    public init(
        leadingCount: Int = 0,
        trailingCount: Int = 0,
        rowWidth: CGFloat = 0,
        allowsFullSwipeLeading: Bool = false,
        allowsFullSwipeTrailing: Bool = true
    ) {
        self.leadingCount = leadingCount
        self.trailingCount = trailingCount
        self.rowWidth = rowWidth
        self.allowsFullSwipeLeading = allowsFullSwipeLeading
        self.allowsFullSwipeTrailing = allowsFullSwipeTrailing
    }

    public func actionCount(on side: SwipeSide) -> Int {
        switch side {
        case .leading: leadingCount
        case .trailing: trailingCount
        }
    }

    public func allowsFullSwipe(on side: SwipeSide) -> Bool {
        guard actionCount(on: side) > 0, rowWidth > 0 else { return false }
        return switch side {
        case .leading: allowsFullSwipeLeading
        case .trailing: allowsFullSwipeTrailing
        }
    }

    /// The side a translation is heading toward.
    public static func side(of translation: CGFloat) -> SwipeSide {
        translation < 0 ? .trailing : .leading
    }

    /// Where the row rests with a side fully exposed. Negative for the trailing side.
    public func restingOffset(for side: SwipeSide) -> CGFloat {
        let width = CGFloat(actionCount(on: side)) * SwipeMetrics.actionWidth
        return side == .trailing ? -width : width
    }

    /// Where the row is drawn for a given raw translation.
    ///
    /// Three regimes: free travel while the actions are still being uncovered, free travel beyond
    /// that where a full swipe is possible — because the gesture has somewhere further to go and
    /// resisting it would fight the very motion being asked for — and rubber-banding where it does
    /// not. A side with no actions resists immediately and stops a finger's width in, which is how
    /// a row says "not that way" without pretending nothing happened.
    public func offset(forTranslation translation: CGFloat) -> CGFloat {
        guard abs(translation) >= SwipeMetrics.minimumTravel else { return 0 }

        let side = Self.side(of: translation)
        let direction: CGFloat = side == .trailing ? -1 : 1

        guard actionCount(on: side) > 0 else {
            return direction * min(abs(translation) * SwipeMetrics.rubberBand, SwipeMetrics.deadSideLimit)
        }

        let resting = restingOffset(for: side)
        guard abs(translation) > abs(resting) else { return translation }

        if allowsFullSwipe(on: side) {
            let limit = rowWidth * SwipeMetrics.fullSwipeFraction
            guard abs(translation) > limit else { return translation }
            return direction * (limit + (abs(translation) - limit) * SwipeMetrics.rubberBand)
        }

        return resting + (translation - resting) * SwipeMetrics.rubberBand
    }

    /// Whether the gesture has gone far enough that letting go would run the default action.
    ///
    /// The view asks this *while the gesture is in flight*, not only at the end — it is what draws
    /// the warning, and a threshold that were only known on release would be a deletion with no
    /// notice at all.
    public func isPastFullSwipe(translation: CGFloat) -> Bool {
        let side = Self.side(of: translation)
        guard allowsFullSwipe(on: side) else { return false }
        return abs(translation) >= rowWidth * SwipeMetrics.fullSwipeFraction
    }

    /// What letting go should do.
    public func outcome(forTranslation translation: CGFloat) -> SwipeOutcome {
        guard abs(translation) >= SwipeMetrics.minimumTravel else { return .closed }

        let side = Self.side(of: translation)
        guard actionCount(on: side) > 0 else { return .closed }

        if isPastFullSwipe(translation: translation) { return .commit(side) }

        let threshold = abs(restingOffset(for: side)) * SwipeMetrics.openFraction
        return abs(translation) >= threshold ? .open(side) : .closed
    }

    /// Whether an accumulated movement is a swipe rather than the start of a scroll.
    ///
    /// Asked once per gesture, on the first movement worth judging. Getting it wrong in one
    /// direction opens rows during a scroll; getting it wrong in the other means a swipe that has
    /// to be repeated. The lock ratio is what buys the second over the first.
    public static func isHorizontal(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        guard abs(deltaX) >= SwipeMetrics.minimumTravel else { return false }
        return abs(deltaX) > abs(deltaY) * SwipeMetrics.directionLockRatio
    }

    /// Whether an accumulated movement has committed to being a scroll, so this gesture must be
    /// left alone for the rest of its life.
    public static func isVertical(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        guard abs(deltaY) >= SwipeMetrics.minimumTravel else { return false }
        return abs(deltaY) > abs(deltaX)
    }
}
