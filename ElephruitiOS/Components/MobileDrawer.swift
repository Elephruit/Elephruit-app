import ElephruitDesign
import SwiftUI

/// The iPhone's drawer: a screen that slides aside, and the panel that occupies the strip it
/// leaves behind.
///
/// ### Why the movement lives here rather than in the shell
/// The offset used to be `@State` on `MobileRootView`. That meant every frame of a drag — a
/// hundred and twenty of them a second — re-evaluated the shell's body, and the shell's body
/// builds the restoration value it writes to scene storage, reads the running timer, and hands
/// the environment to every screen. None of that has anything to say about where the drawer is.
/// Here the state that moves belongs to the only view that moves, and the shell's body runs when
/// the shell actually changes: twice in a drag rather than two hundred times.
///
/// The two layers are built by the caller and *stored*, not rebuilt from a closure on each
/// frame, so a drag re-applies two modifiers instead of re-making a navigation stack.
struct MobileDrawer<Content: View, Drawer: View>: View {
    /// Where the drawer has settled. A drag adds to this rather than replacing it, which is what
    /// lets a gesture start from either end.
    let isOpen: Bool

    /// Whether the stack has somewhere to go back to — which decides who owns the leading edge.
    /// Above a root that strip belongs to the system's interactive pop, and it is the same
    /// gesture in the hand, so this must not intercept it.
    let canPop: Bool

    let width: CGFloat

    /// Settles the drawer. Deliberately *not* animated by the caller: this view is the one that
    /// knows a gesture was in flight, so it owns the animation that follows through from it.
    let setOpen: (Bool) -> Void

    private let content: Content
    private let drawer: Drawer

    @State private var dragTranslation: CGFloat = 0

    init(
        isOpen: Bool,
        canPop: Bool,
        width: CGFloat,
        setOpen: @escaping (Bool) -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder drawer: () -> Drawer
    ) {
        self.isOpen = isOpen
        self.canPop = canPop
        self.width = width
        self.setOpen = setOpen
        self.content = content()
        self.drawer = drawer()
    }

    /// How far a drag must travel before it decides. Below this the drawer springs back, which
    /// keeps a hesitant thumb from committing to a screen change it did not mean.
    private static var commitDistance: CGFloat { 60 }

    /// The strip along the leading edge that starts the drawer. Matches the width the system's
    /// own interactive-pop gesture claims, so the two feel like one gesture at different depths
    /// rather than two gestures with different targets.
    private static var edgeWidth: CGFloat { 20 }

    /// How much of the top of that strip belongs to the toolbar instead.
    ///
    /// The chevron sits about thirteen points from the leading edge, so its first seven points
    /// were underneath the strip. A perfectly still tap there still reached the button — which is
    /// why every synthetic test passed — but a real thumb moves, and eight points of drift handed
    /// the touch to the drag recognizer, which cancelled the button and, having gone nowhere,
    /// did nothing itself. A button that works unless your thumb slips is a button that works
    /// most of the time.
    ///
    /// Generous enough for a bar under the tallest status bar the phones have. Nobody starts a
    /// drawer swipe from inside the navigation bar; they start it where their hand already is.
    private static var toolbarClearance: CGFloat { 120 }

    var body: some View {
        ZStack(alignment: .leading) {
            content
                .overlay { scrim }
                // Resolved as one piece: without this each child settles its own geometry
                // against the moving frame, and a screen full of rows animating individually is
                // exactly what a drawer slide must never look like.
                .geometryGroup()
                .offset(x: revealedWidth)
                .overlay(alignment: .leading) { edgeGestureCatcher }
                .gesture(isOpen ? closeDrag : nil)

            // Above the content in z-order though the two never overlap: a `NavigationStack` is
            // a UIKit container that shadows its siblings in the accessibility tree, so a drawer
            // *behind* one is a drawer VoiceOver and the UI tests cannot reach.
            drawer
                .frame(width: width)
                .offset(x: revealedWidth - width)
                .accessibilityHidden(revealedWidth == 0)
        }
    }

    // MARK: - Layers

    /// The scrim both dims and disarms: while the drawer is open the screen behind it is
    /// scenery, and a tap on scenery should close the drawer rather than land on whatever
    /// control happens to be under the thumb.
    ///
    /// Always present, at zero opacity when the drawer is shut. It used to appear the moment the
    /// offset left zero, which inserted a view into the hierarchy on the first frame of every
    /// drag — a structural change is the most expensive thing that can happen at the exact
    /// moment a gesture needs to be cheapest.
    private var scrim: some View {
        Rectangle()
            .fill(Theme.Colors.scrim.opacity(0.28 * revealProgress))
            .contentShape(Rectangle())
            .allowsHitTesting(revealedWidth > 0)
            .onTapGesture { commit(open: false) }
            .accessibilityHidden(revealedWidth == 0)
            .accessibilityLabel("Close the sidebar")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { commit(open: false) }
    }

    /// The leading strip that starts the drawer, live only at the root of a stack. Popping the
    /// last route arms it again, which is what makes "keep swiping right" walk all the way home.
    @ViewBuilder
    private var edgeGestureCatcher: some View {
        if !isOpen && !canPop {
            Color.clear
                .frame(width: Self.edgeWidth)
                .contentShape(Rectangle())
                .gesture(openDrag)
                .padding(.top, Self.toolbarClearance)
        }
    }

    // MARK: - The gesture

    private var openDrag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                dragTranslation = max(0, min(value.translation.width, width))
            }
            .onEnded { value in
                commit(
                    open: value.translation.width > Self.commitDistance
                        || value.predictedEndTranslation.width > width / 2
                )
            }
    }

    private var closeDrag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                dragTranslation = max(-width, min(0, value.translation.width))
            }
            .onEnded { value in
                let closed = value.translation.width < -Self.commitDistance
                    || value.predictedEndTranslation.width < -width / 2
                commit(open: !closed)
            }
    }

    /// Ends a gesture: the finger's contribution and the settled position change together, in
    /// one animated transaction. Zeroing the drag outside the animation was a frame where the
    /// drawer jumped back to where the gesture started before springing to where it ended.
    private func commit(open: Bool) {
        withCalmAnimation(Theme.Motion.drawer) {
            dragTranslation = 0
            setOpen(open)
        }
    }

    /// How far the content currently sits from home: the settled state plus whatever the thumb
    /// is adding, clamped so no drag can push past either end.
    private var revealedWidth: CGFloat {
        min(max((isOpen ? width : 0) + dragTranslation, 0), width)
    }

    private var revealProgress: Double {
        Double(revealedWidth / width)
    }
}
