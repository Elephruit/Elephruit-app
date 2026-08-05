import ElephruitDesign
import SwiftUI

/// What the shell's plus can make.
///
/// Five, and five is the argument. A day is a small number of kinds of thing — something to do,
/// somewhere to be, something to know, time that went somewhere, and everything that has not been
/// decided yet — and a fan is the one menu shape that cannot grow past what the eye reads at a
/// glance without visibly breaking. A sixth entry would close the gaps between the circles; a
/// seventh would put the far end of the arc outside the thumb. The ceiling is the point: this is
/// the list of things a day is made of, not a list of everything the app can create.
///
/// The order is the arc's order, and it runs from the plus outward: the entry sitting level with
/// the button is the shortest journey the thumb can make, and the one directly above it is the
/// longest. So `reminder` is first — the thing a day is mostly made of — and `capture` is last,
/// because it is the answer when none of the other four is, and reaching for it a little further
/// is the correct cost of not having decided.
enum MobileAddAction: String, CaseIterable, Identifiable {
    case reminder
    case event
    case note
    case time
    case capture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reminder: "Reminder"
        case .event: "Event"
        case .note: "Note"
        case .time: "Time"
        case .capture: "Capture"
        }
    }

    /// The module's own symbol wherever this makes something a module holds, so the fan teaches
    /// the same vocabulary the drawer does rather than inventing a second one for the same thing.
    var symbolName: String {
        switch self {
        case .reminder: "bell"
        case .event: "calendar"
        case .note: "note.text"
        case .time: "timer"
        case .capture: "tray"
        }
    }

    /// What belongs here — the `MobileDestination.hint` standard: a rule about the contents,
    /// never the label spelled back. These carry more weight than a destination's hint does,
    /// because the fan is drawn without visible text and the glyph is all a sighted user gets.
    var hint: String {
        switch self {
        case .reminder: "Something to be done, at the time it matters."
        case .event: "A place to be, at an hour you have to keep."
        case .note: "Something worth knowing later, written down now."
        case .time: "Work that already happened, filed against what it was for."
        case .capture: "Anything at all, into the Inbox, sorted later."
        }
    }

    var accessibilityIdentifier: String { "mobile.add.\(rawValue)" }
}

/// The shell's plus, and everything it can make, on an arc around it.
///
/// ### Why an arc and not a sheet
/// A menu sheet answers "what can I make" by covering the thing being added to, which is the one
/// piece of context the answer depends on. The fan does not: it opens over the corner the thumb
/// is already resting in, leaves the screen readable behind it, and puts every choice at the same
/// distance from where the finger already is. Nothing here is further away than anything else,
/// which is what a list of five siblings should feel like and what a vertical menu never does.
///
/// ### Why the motion is the design
/// Five circles that simply appear are five circles from nowhere. Every one of them travels out
/// of the plus and, on the way back, into it — so the button is visibly the container these came
/// from, the arc is visibly one gesture rather than five arrivals, and closing is visibly an
/// undo rather than a dismissal. The stagger (``Theme/Motion/fanStagger``) runs outward on the
/// way open and inward on the way closed, so the fan unrolls from the button and rolls back up
/// into it, in that order, both times.
struct MobileAddMenu: View {
    /// The drawn circle of every control here, the plus included. One number, so the point the
    /// fan collapses into is exactly the button it collapses into.
    ///
    /// The glass grows the box by a little over a point: 40 here measures 41 on screen, against
    /// the 58 the plus used to draw. Two layers of padding had to be found before that number
    /// meant anything. It began as a 56-point box inside `.buttonStyle(.glassProminent)` — a
    /// style that pads what it is handed *and* refuses to go below its own minimum, so the button
    /// drew at 58 whatever this said, and taking it from 56 to 44 to 26 changed not one pixel.
    /// Applying the glass to the shape directly is what made the number load-bearing again.
    ///
    /// Small because these float over lists whose content is the point, permanently, on every
    /// screen: the loudest object in the room should not be the one you use least.
    private static let glyphBox: CGFloat = 40

    /// The same margin the plus has always carried — invisible to the eye, and the difference
    /// between a 41-point drawing and a 44-point target.
    private static let target: CGFloat = glyphBox + 2 * Theme.Spacing.hairline

    /// How much of the bottom of the screen the plus owns.
    ///
    /// It floats over the content rather than displacing it, so a scrolling view has to leave this
    /// much room underneath or its final row can never be read — it comes to rest under the glass
    /// at every scroll position. Derived from the button's own measurements rather than typed
    /// again: a clearance that stops matching the thing it is clearing is worse than none, because
    /// it looks deliberate while being wrong. Applied once, on the shell — see `MobileRootView`.
    static let footprint: CGFloat = target + Theme.Spacing.section

    /// How far each control travels from the plus's center.
    ///
    /// Measured against the controls rather than picked. Five of them across a quarter turn sit
    /// `2·r·sin(11.25°)` apart, so under about 115 points their edges touch and the arc reads as
    /// one scalloped blob; over about 135 the top of the arc leaves the arc of the thumb, and a
    /// menu that requires regripping the phone is a menu that costs more than the screen it was
    /// meant to save. 124 clears the circles by four points and stays inside the reach.
    private static let radius: CGFloat = 124

    /// How much of the screen the fan claims: the arc's reach, plus the control standing at the
    /// end of it. Stated as a frame so that every control is laid out *inside* this view.
    private static let span: CGFloat = radius + target

    /// Where the plus sits in that square — the bottom-right corner, half a control in. Every
    /// other position here is measured from this point, because every other control comes from
    /// it and goes back into it.
    private static let origin = CGPoint(x: span - target / 2, y: span - target / 2)

    /// The same point, as a top-left corner, which is what an alignment guide shifts.
    private static let originCorner = CGPoint(x: origin.x - target / 2, y: origin.y - target / 2)

    var isOpen: Bool
    var setOpen: (Bool) -> Void
    var perform: (MobileAddAction) -> Void

    private let actions = MobileAddAction.allCases

    /// Every control is placed by shifting its alignment guides inside this square.
    ///
    /// Emphatically not by `offset`, which is how this was first written and was a real defect:
    /// an offset draws in one place and *lays out* in another, so the system went on believing
    /// all five controls were stacked under the plus. Taps aimed at a circle fell through it onto
    /// whatever the screen had underneath, and the one choice that happened to work worked
    /// because it was last in the stack. Anything reading geometry rather than pixels — hit
    /// testing, VoiceOver, every automated tap — was reading the wrong geometry.
    ///
    /// `position` fixes that much. Alignment guides are preferred over it only because they move
    /// a view without ever making it bigger than itself: `position` lays its child out in a layer
    /// the size of this whole square, so the control's frame and the layer it lives in disagree
    /// about how large it is, and modifiers applied afterwards — a `scaleEffect`, most sharply —
    /// silently take the square as their reference instead of the circle. One geometry, no
    /// second thing for anything to consult.
    ///
    /// Worth knowing for the next person: this square sits over screens that have their own
    /// full-screen tap targets underneath it — Reminders' background is one large "new reminder"
    /// button — and `XCUIElement.tap()` mis-aims at those. See `FloatingControlTaps` in the UI
    /// tests. A finger is fine; it is the harness that needs the coordinate.
    private func placed(_ view: some View, at corner: CGPoint) -> some View {
        view
            .alignmentGuide(.leading) { _ in -corner.x }
            .alignmentGuide(.top) { _ in -corner.y }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: Self.span, height: Self.span)
                .allowsHitTesting(false)

            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                placed(control(action, at: index), at: corner(at: index))
            }

            placed(trigger, at: Self.originCorner)
        }
        .frame(width: Self.span, height: Self.span, alignment: .topLeading)
        .padding(.trailing, Theme.Spacing.large)
        // The tab bar this used to clear is gone, so this is now the ordinary content inset:
        // the button sits where the thumb already is rather than where the chrome used to be.
        .padding(.bottom, Theme.Spacing.section)
    }

    // MARK: - The plus

    /// The button, and the only moving part that stays put.
    ///
    /// It turns forty-five degrees into a cross rather than swapping glyph, because a plus and a
    /// cross are the same two strokes and the rotation is the sentence: *this opened, and this is
    /// how it closes*. A cross faded in over a plus faded out would be two symbols disagreeing
    /// for a tenth of a second about which one you are looking at.
    private var trigger: some View {
        Button {
            setOpen(!isOpen)
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.Colors.onAccent)
                .rotationEffect(.degrees(isOpen ? 45 : 0))
                .frame(width: Self.glyphBox, height: Self.glyphBox)
                .glassEffect(
                    .regular.tint(Theme.Colors.selection).interactive(),
                    in: .circle
                )
                .padding(Theme.Spacing.hairline)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .elevation(.floating)
        .calmAnimation(Theme.Motion.fan, value: isOpen)
        .accessibilityLabel(isOpen ? "Close the add menu" : "Add")
        .accessibilityHint(
            isOpen
                ? "Puts the choices away"
                : "Opens a reminder, event, note, time entry, or quick capture"
        )
        // The name the shell's button has always had. Every UI test reaches for the plus by it,
        // and what the plus *does* changing is not a reason for what it is *called* to change.
        .accessibilityIdentifier("mobile.capture.button")
    }

    // MARK: - The fan

    private func control(_ action: MobileAddAction, at index: Int) -> some View {
        Button {
            // Closed first, then acted on: the fan is the question, and it should be off the
            // screen before the answer — a composer or a sheet — arrives over the top of it.
            setOpen(false)
            perform(action)
        } label: {
            Image(systemName: action.symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.Colors.onAccent)
                .frame(width: Self.glyphBox, height: Self.glyphBox)
                .glassEffect(
                    .regular.tint(Theme.Colors.selection).interactive(),
                    in: .circle
                )
                .padding(Theme.Spacing.hairline)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .elevation(.floating)
        // Not to zero: a zero scale is a view with no geometry, and the spring has nothing to
        // interpolate a position for. A hundredth is a point wide and reads as the same thing.
        // Scaled before it is placed, so each control shrinks toward its own middle rather than
        // toward the middle of the square it is placed in.
        .scaleEffect(isOpen ? 1 : 0.01)
        .opacity(isOpen ? 1 : 0)
        .calmAnimation(Theme.Motion.fan.delay(delay(at: index)), value: isOpen)
        // Collapsed, these are five invisible buttons stacked exactly under the plus. Without
        // this the plus would be unreachable — every tap on it would land on whichever of them
        // SwiftUI happened to order last.
        .allowsHitTesting(isOpen)
        .accessibilityLabel(action.title)
        .accessibilityHint(action.hint)
        // Nameless while folded, and hidden as well, because neither alone is enough.
        //
        // `accessibilityHidden` stops the control being *reached* — folded, it is not hittable —
        // but it does not reliably take the element back out of the tree once the modifiers
        // below have built one, so five collapsed controls go on answering to their own names
        // from underneath the plus. Anything that looks a control up by name finds the folded
        // copy sitting at the plus's coordinates. Withholding the name too is the honest version
        // of what is true: a folded control is not a control yet.
        .accessibilityIdentifier(isOpen ? action.accessibilityIdentifier : "")
        .accessibilityHidden(!isOpen)
    }

    /// One control's top-left corner, which is what an alignment guide shifts.
    private func corner(at index: Int) -> CGPoint {
        let centre = position(at: index)
        return CGPoint(x: centre.x - Self.target / 2, y: centre.y - Self.target / 2)
    }

    /// Where one control sits — on the arc when the fan is open, on the plus when it is not.
    ///
    /// The arc is a quarter turn, split evenly, from level with the button to directly above it.
    /// A quarter because that is the whole of the screen a bottom-right button has: any further
    /// round and the arc walks off the right edge, any less and five circles crowd into a cluster
    /// whose members are told apart by their glyphs alone rather than by where they are.
    private func position(at index: Int) -> CGPoint {
        guard isOpen else { return Self.origin }
        let steps = Double(max(actions.count - 1, 1))
        let angle = Angle.degrees(90 * Double(index) / steps)
        return CGPoint(
            x: Self.origin.x - Self.radius * cos(angle.radians),
            y: Self.origin.y - Self.radius * sin(angle.radians)
        )
    }

    /// When one control starts moving, relative to the first.
    ///
    /// Reversed on the way closed, so the far end of the arc leaves first and the near end last.
    /// Keeping the opening order would have the control nearest the plus vanish while the one
    /// furthest away is still standing there, which is a fan being deleted rather than a fan
    /// being folded.
    private func delay(at index: Int) -> TimeInterval {
        let position = isOpen ? index : actions.count - 1 - index
        return Double(position) * Theme.Motion.fanStagger
    }
}

/// What the fan puts between itself and the screen.
///
/// It dims, and it disarms — the same two jobs the drawer's scrim has, for the same reason. A row
/// tapped through an open menu is a tap nobody meant: the finger was on its way to a circle and
/// missed. Catching it here turns the miss into "put the menu away", which is what a miss should
/// cost.
struct MobileAddMenuScrim: View {
    /// Matched to the drawer's, because it is the same statement — *this is not what you are
    /// touching right now* — and two different greys for one idea would be two ideas.
    private static let dimming: Double = 0.28

    var isOpen: Bool
    var close: () -> Void

    var body: some View {
        Rectangle()
            .fill(Theme.Colors.scrim.opacity(isOpen ? Self.dimming : 0))
            .ignoresSafeArea()
            .onTapGesture(perform: close)
            // Last, so it covers the gesture as well as the fill. Closed, this is a full-screen
            // invisible rectangle over the entire app: anything it can still catch, it eats.
            .allowsHitTesting(isOpen)
            // A curve rather than the fan's spring: a spring overshoots, and an overshooting
            // opacity would darken past the value that was chosen before settling back onto it.
            .calmAnimation(Theme.Motion.standard, value: isOpen)
            .accessibilityHidden(!isOpen)
    }
}
