import ElephruitCore
import Foundation
import Testing

/// The half of a swipe that can be checked without a trackpad.
///
/// Everything about how far is far enough lives in `SwipeGesture` as arithmetic, precisely so it can
/// be asserted here rather than only felt. The thresholds are the whole feature: too low and a
/// scroll deletes something, too high and the gesture is one nobody can perform.
@Suite("Swipe thresholds")
struct SwipeGestureTests {
    /// A row the width of a list column, with one destructive action on the trailing edge.
    private var oneDeleteAction: SwipeGesture {
        SwipeGesture(leadingCount: 0, trailingCount: 1, rowWidth: 400)
    }

    private var twoAndOne: SwipeGesture {
        SwipeGesture(leadingCount: 2, trailingCount: 1, rowWidth: 400)
    }

    // MARK: - Direction

    @Test("Swiping left heads for the trailing actions, right for the leading ones")
    func signConventionHolds() {
        #expect(SwipeGesture.side(of: -40) == .trailing)
        #expect(SwipeGesture.side(of: 40) == .leading)
    }

    @Test("A row rests with each side exactly as wide as its buttons")
    func restingOffsets() {
        #expect(twoAndOne.restingOffset(for: .leading) == SwipeMetrics.actionWidth * 2)
        #expect(twoAndOne.restingOffset(for: .trailing) == -SwipeMetrics.actionWidth)
    }

    // MARK: - Scrolling must not swipe

    @Test("A mostly vertical movement is a scroll, however far sideways it drifts")
    func verticalMovementIsNotASwipe() {
        // The case this exists for: a fast flick down a long list, where fingers are never
        // perfectly straight. Without the lock ratio every one of those opens a delete button.
        #expect(SwipeGesture.isHorizontal(deltaX: 12, deltaY: 40) == false)
        #expect(SwipeGesture.isVertical(deltaX: 12, deltaY: 40))

        // Diagonal, but not horizontal *enough*. `|dx| > |dy|` alone would have let this through.
        #expect(SwipeGesture.isHorizontal(deltaX: 20, deltaY: 18) == false)
    }

    @Test("A deliberate sideways movement is a swipe")
    func horizontalMovementIsASwipe() {
        #expect(SwipeGesture.isHorizontal(deltaX: -40, deltaY: 6))
        #expect(SwipeGesture.isVertical(deltaX: -40, deltaY: 6) == false)
    }

    @Test("The first few points of any gesture move nothing")
    func tinyMovementsAreIgnored() {
        // A list is scrolled far more often than it is swiped, and a row twitching under every
        // flick costs more than the first eight points of a real swipe being invisible.
        #expect(SwipeGesture.isHorizontal(deltaX: 4, deltaY: 0) == false)
        #expect(oneDeleteAction.offset(forTranslation: -4) == 0)
        #expect(oneDeleteAction.outcome(forTranslation: -4) == .closed)
    }

    @Test("A deliberate window swipe maps left to hide and right to show")
    func sidebarSwipeDirection() {
        let travel = SidebarSwipeGesture.activationTravel
        #expect(SidebarSwipeGesture.direction(forTranslation: -travel) == .hide)
        #expect(SidebarSwipeGesture.direction(forTranslation: travel) == .show)
    }

    @Test("A short horizontal movement does not rearrange the window")
    func shortSidebarSwipeDoesNothing() {
        let short = SidebarSwipeGesture.activationTravel - 1
        #expect(SidebarSwipeGesture.direction(forTranslation: -short) == nil)
        #expect(SidebarSwipeGesture.direction(forTranslation: short) == nil)
    }

    // MARK: - Partial swipes

    @Test("A short swipe snaps shut")
    func shortSwipeCloses() {
        // Below half the button's width. The user started something and changed their mind, which
        // is a thing they are allowed to do.
        let travel = -SwipeMetrics.actionWidth * 0.4
        #expect(oneDeleteAction.outcome(forTranslation: travel) == .closed)
    }

    @Test("A swipe past half the button settles open, waiting to be clicked")
    func partialSwipeOpens() {
        let travel = -SwipeMetrics.actionWidth * 0.6
        #expect(oneDeleteAction.outcome(forTranslation: travel) == .open(.trailing))
    }

    @Test("An open row rests with the button fully visible rather than where the finger stopped")
    func openRowRestsAtTheButtonWidth() {
        #expect(oneDeleteAction.restingOffset(for: .trailing) == -SwipeMetrics.actionWidth)
    }

    @Test("The row follows the finger exactly while the buttons are still being uncovered")
    func trackingIsOneToOne() {
        let travel = -SwipeMetrics.actionWidth * 0.75
        #expect(oneDeleteAction.offset(forTranslation: travel) == travel)
    }

    // MARK: - Full swipes

    @Test("A long swipe commits, and says so before it does")
    func fullSwipeCommits() {
        let travel = -400 * SwipeMetrics.fullSwipeFraction - 1

        // Armed *during* the gesture, which is what draws the warning. A threshold only known on
        // release would be a deletion with no notice at all.
        #expect(oneDeleteAction.isPastFullSwipe(translation: travel))
        #expect(oneDeleteAction.outcome(forTranslation: travel) == .commit(.trailing))
    }

    @Test("A generous ordinary swipe stops short of committing")
    func generousSwipeStillOnlyOpens() {
        // Half the row is a long way, and still not a deletion. The threshold is deliberately more
        // than half so that deleting is something people do rather than something that happens.
        let travel = -400 * 0.5
        #expect(oneDeleteAction.isPastFullSwipe(translation: travel) == false)
        #expect(oneDeleteAction.outcome(forTranslation: travel) == .open(.trailing))
    }

    @Test("A side with no full-swipe default never commits, however far it goes")
    func fullSwipeCanBeRefused() {
        // What a linked reminder and the Trash both need: the button may be revealed, but the
        // gesture alone must not be able to run it.
        let guarded = SwipeGesture(trailingCount: 1, rowWidth: 400, allowsFullSwipeTrailing: false)
        let travel = -390.0

        #expect(guarded.isPastFullSwipe(translation: travel) == false)
        #expect(guarded.outcome(forTranslation: travel) == .open(.trailing))
    }

    @Test("Leading actions do not commit on a full swipe by default")
    func leadingDoesNotCommitByDefault() {
        // Completing something because a swipe went further than intended is a good deal more
        // surprising than it sounds, so the two sides are not symmetrical.
        let travel = 390.0
        #expect(twoAndOne.isPastFullSwipe(translation: travel) == false)
        #expect(twoAndOne.outcome(forTranslation: travel) == .open(.leading))
    }

    @Test("Past the commit threshold the row resists rather than sliding off screen")
    func overshootIsRubberBanded() {
        let limit = 400 * SwipeMetrics.fullSwipeFraction
        let travel = -(limit + 100)
        let offset = oneDeleteAction.offset(forTranslation: travel)

        #expect(abs(offset) > limit)
        #expect(abs(offset) < limit + 100, "The last hundred points should not be free")
    }

    // MARK: - Sides with nothing on them

    @Test("Swiping toward a side with no actions moves a finger's width and stops")
    func deadSideResists() {
        // Not nothing — a row that ignores the gesture entirely reads as broken — and not an open
        // row either, because there is nothing there to open.
        let offset = oneDeleteAction.offset(forTranslation: 200)
        #expect(offset > 0)
        #expect(offset <= SwipeMetrics.deadSideLimit)
        #expect(oneDeleteAction.outcome(forTranslation: 200) == .closed)
    }

    @Test("A row with no actions at all never opens")
    func noActionsNeverOpens() {
        let inert = SwipeGesture(rowWidth: 400)
        #expect(inert.outcome(forTranslation: -390) == .closed)
        #expect(inert.outcome(forTranslation: 390) == .closed)
        #expect(inert.isPastFullSwipe(translation: -390) == false)
    }

    @Test("A row that has not been measured yet cannot full-swipe")
    func unmeasuredRowsAreSafe() {
        // Width arrives from a `GeometryReader` a frame after the row exists. Until it does, a
        // fraction of zero is zero, and every swipe would be a full one.
        let unmeasured = SwipeGesture(trailingCount: 1, rowWidth: 0)
        #expect(unmeasured.isPastFullSwipe(translation: -500) == false)
        #expect(unmeasured.outcome(forTranslation: -500) == .open(.trailing))
    }
}
