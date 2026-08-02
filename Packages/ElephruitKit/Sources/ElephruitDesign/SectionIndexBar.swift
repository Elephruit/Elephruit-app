import SwiftUI

/// The quick-jump rail down the trailing edge of a long list.
///
/// ### Why a rail rather than a scrollbar
/// A scrollbar answers *where am I in the list*. This answers *take me to the M's*, which is a
/// different question and the one somebody with two thousand contacts is actually asking. Both are
/// present, because the scrollbar still has to behave like a scrollbar — clicking its track, dragging
/// its knob — and this sits beside it rather than replacing it.
///
/// ### Why it is a column and not an overlay
/// It was an overlay. `ZStack(alignment: .topTrailing)` put sixteen points of letters *on top of* the
/// list, which meant every person row was laid out as though the rail were not there and then drawn
/// underneath it: names ran beneath the letters, and — far worse — so did the row separators and the
/// selection fill, so selecting somebody painted the accent colour straight through the alphabet.
/// The rail read as a column of the table rather than as a control beside it, which is exactly
/// backwards: it holds no data about anybody.
///
/// A rail is a sibling now. It has its own width, its own quiet background, and a hairline on its
/// leading edge, and the list ends where the rail begins — so nothing of the list's can reach it,
/// because there is nothing to reach across. It sits outside the scroll view, so it stays put while
/// the list moves under it.
///
/// ### Why it is still narrow
/// Twenty-two points, at nine points of text. It has to be hittable with a trackpad and it must not
/// take a tenth of the list's width away from the names, which are the thing the list is for.
/// Dragging widens the target rather than the control — the whole rail tracks the pointer's vertical
/// position once a drag has begun, so the pointer may wander horizontally without losing it, which is
/// what makes scrubbing possible at this width.
///
/// ### Why the headings come from the caller
/// Because the alphabet is a property of the names, not of the app. See
/// ``ElephruitCore/PersonListOrganiser`` — a fixed A–Z rail promises letters that a list of Greek or
/// Berlin or Japanese names has none of, and every one of those is a target that does nothing. That
/// argument is also why there is no per-letter "no names here" state: a letter with nobody under it
/// is not drawn at all, so the state cannot arise. What *can* be unavailable is the whole rail — see
/// ``isEnabled``.
public struct SectionIndexBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let titles: [String]
    private let activeTitle: String?
    private let isEnabled: Bool
    private let label: String
    private let unavailableReason: String?

    /// Called with the heading under the pointer, repeatedly while scrubbing.
    private let onSelect: (String) -> Void

    @State private var scrubbing: String?
    @State private var hovering: String?
    @State private var height: CGFloat = 0
    @FocusState private var isFocused: Bool

    /// The rail's own width. See the note above on why it is this small.
    public static let width: CGFloat = 22

    /// - Parameters:
    ///   - titles: the headings that exist, in the order the list shows them.
    ///   - activeTitle: the section the list is currently in, marked so the rail says *where you
    ///     are* as well as *where you could go*.
    ///   - isEnabled: `false` draws the rail dimmed and inert rather than removing it. A rail that
    ///     disappears the moment somebody types into the search field takes its width with it and
    ///     shifts every row sideways, which is a worse answer to "this cannot be used right now"
    ///     than saying so.
    ///   - label: what the rail jumps *by*, for VoiceOver — "surname", "first name", "company". A
    ///     rail that says only "jump to a section" leaves a screen-reader user to guess which part
    ///     of the name the letters refer to, and in this app that changes with the sort order.
    ///   - unavailableReason: shown in the tooltip while disabled.
    public init(
        titles: [String],
        activeTitle: String? = nil,
        isEnabled: Bool = true,
        label: String = "section",
        unavailableReason: String? = nil,
        onSelect: @escaping (String) -> Void
    ) {
        self.titles = titles
        self.activeTitle = activeTitle
        self.isEnabled = isEnabled
        self.label = label
        self.unavailableReason = unavailableReason
        self.onSelect = onSelect
    }

    public var body: some View {
        // A rail of one heading can only do what the list already does.
        if titles.count > 1 {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            ForEach(titles, id: \.self) { title in
                Text(shortened(title))
                    .font(.system(size: 9, weight: weight(for: title), design: .rounded))
                    .foregroundStyle(color(for: title))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        // The hover mark is a disc behind one letter rather than a fill across the
                        // rail: the target *is* one letter, and a highlight the width of the column
                        // would claim the whole strip was about to be pressed.
                        Circle()
                            .fill(Theme.Colors.hoverFill)
                            .opacity(hovering == title && scrubbing == nil ? 1 : 0)
                    }
                    .onHover { isInside in
                        guard isEnabled else { return }
                        hovering = isInside ? title : (hovering == title ? nil : hovering)
                    }
            }
        }
        .frame(width: Self.width)
        .padding(.vertical, Theme.Spacing.tight)
        .background(alignment: .leading) {
            // Its own surface and its own boundary, so the rail reads as a control the list stops
            // beside rather than as the list's last column.
            Divider()
        }
        .background(scrubbing == nil ? Color.clear : Theme.Colors.subtleFill)
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.4)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .gesture(
            // `minimumDistance: 0` so a single click on a letter jumps immediately rather than
            // waiting to find out whether the pointer is going to move.
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard isEnabled else { return }
                    select(at: value.location.y)
                }
                .onEnded { _ in scrubbing = nil }
        )
        // Tab reaches the rail, and the system draws its own focus ring around it — which is the
        // right ring, in the user's accent, correct under Increase Contrast, and one this file does
        // not have to keep true.
        //
        // `.activate` interactions only: a plain `.focusable()` also takes focus from a *click*,
        // which left the ring wrapped around the rail after every use of it — a control that keeps
        // announcing itself after it has done its job. Clicking now scrubs and nothing more, which
        // is how every other mouse-first control on the platform behaves; the ring appears only
        // for somebody who tabbed here on purpose.
        .focusable(isEnabled, interactions: .activate)
        .focused($isFocused)
        // Arrow keys step through the sections, which is the same thing the adjustable action does
        // for VoiceOver and the same thing dragging does for a pointer.
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.downArrow) { step(1) }
        .calmAnimation(Theme.Motion.appearance, value: scrubbing)
        .calmAnimation(Theme.Motion.appearance, value: hovering)
        .help(isEnabled ? "Jump to a \(label) section" : (unavailableReason ?? ""))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jump to a \(label) section")
        .accessibilityValue(scrubbing ?? activeTitle ?? titles.first ?? "")
        .accessibilityHint(
            isEnabled
                ? "Drag or use the arrow keys to move through the list by \(label)"
                : (unavailableReason ?? "Not available right now")
        )
        // Adjustable rather than a row of buttons: VoiceOver users get one rotor-friendly control
        // that steps through the sections, instead of twenty-seven stops between the list and
        // whatever is after it.
        .accessibilityAdjustableAction { direction in
            _ = step(direction == .increment ? 1 : -1)
        }
        .accessibilityIdentifier("sectionIndexBar")
    }

    // MARK: - States

    /// Bold while the pointer is on it, medium for the section the list is in, regular otherwise.
    private func weight(for title: String) -> Font.Weight {
        if scrubbing == title { return .bold }
        if activeTitle == title { return .semibold }
        return .medium
    }

    /// Three states, and none of them is the row's own colour.
    ///
    /// The accent is the letter being scrubbed *and* the section the list is actually in, because
    /// those are the same claim — this is where you are. Everything else is secondary text, which is
    /// what keeps a column of twenty-seven letters from competing with the names beside it.
    private func color(for title: String) -> Color {
        if scrubbing == title || activeTitle == title { return Theme.Colors.selection }
        if hovering == title { return Theme.Colors.primaryText }
        return Theme.Colors.secondaryText
    }

    /// A time section is called "This week"; the rail has room for one glyph.
    ///
    /// Shortened rather than truncated with an ellipsis, which at nine points is a smudge that costs
    /// a third of the width and says nothing.
    private func shortened(_ title: String) -> String {
        title.count <= 2 ? title : String(title.prefix(1))
    }

    private func select(at y: CGFloat) {
        guard height > 0, !titles.isEmpty else { return }

        let step = height / CGFloat(titles.count)
        let index = min(titles.count - 1, max(0, Int(y / step)))
        let title = titles[index]

        guard title != scrubbing else { return }
        scrubbing = title
        onSelect(title)
    }

    /// Moves one section, from the one the list is in rather than from the top.
    @discardableResult
    private func step(_ direction: Int) -> KeyPress.Result {
        guard isEnabled, !titles.isEmpty else { return .ignored }

        let current = titles.firstIndex(of: scrubbing ?? activeTitle ?? titles[0]) ?? 0
        let next = min(titles.count - 1, max(0, current + direction))
        guard next != current else { return .handled }

        scrubbing = titles[next]
        onSelect(titles[next])
        return .handled
    }
}

/// The heading shown over the list while the rail is being dragged.
///
/// ### Why this exists at all
/// Scrubbing moves the list faster than it can be read. Without a label the user is dragging against
/// a blur and stopping by luck; with one they are choosing a letter and the list is a consequence.
/// It sits over the list rather than in the rail because the rail is twenty-two points wide and this
/// has to be legible at arm's length.
public struct SectionScrubIndicator: View {
    private let title: String

    public init(title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .font(.system(.title, design: .rounded, weight: .semibold))
            .foregroundStyle(Theme.Colors.primaryText)
            .frame(minWidth: 56, minHeight: 56)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .strokeBorder(Theme.Colors.separator)
            )
            .shadow(radius: 8, y: 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
