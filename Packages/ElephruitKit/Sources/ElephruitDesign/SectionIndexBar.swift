import SwiftUI

/// The narrow strip of headings down the trailing edge of a long list.
///
/// ### Why a strip rather than a scrollbar
/// A scrollbar answers *where am I in the list*. This answers *take me to the M's*, which is a
/// different question and the one somebody with two thousand contacts is actually asking. Both are
/// present, because the scrollbar still has to behave like a scrollbar — clicking its track, dragging
/// its knob — and this sits beside it rather than replacing it.
///
/// ### Why it is this small
/// Sixteen points wide, at the list's own text size minus two, right against the edge. It has to be
/// hittable with a trackpad and it must not read as a second column: a strip wide enough to feel
/// generous is a strip that has taken a tenth of the list's width away from the names, which are the
/// thing the list is for. Dragging widens the target rather than the control — the whole strip
/// tracks the pointer's vertical position once a drag has begun, so the pointer may wander
/// horizontally without losing it, which is what makes scrubbing possible at this width.
///
/// ### Why the headings come from the caller
/// Because the alphabet is a property of the names, not of the app. See
/// ``ElephruitCore/PersonListOrganiser`` — a fixed A–Z strip promises letters that a list of Greek
/// or Berlin or Japanese names has none of, and every one of those is a target that does nothing.
public struct SectionIndexBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let titles: [String]

    /// Called with the heading under the pointer, repeatedly while scrubbing.
    private let onSelect: (String) -> Void

    @State private var scrubbing: String?
    @State private var height: CGFloat = 0

    public init(titles: [String], onSelect: @escaping (String) -> Void) {
        self.titles = titles
        self.onSelect = onSelect
    }

    public var body: some View {
        // A strip of one heading is a strip that can only do what the list already does.
        if titles.count > 1 {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            ForEach(titles, id: \.self) { title in
                Text(shortened(title))
                    .font(.system(size: 9, weight: scrubbing == title ? .bold : .medium, design: .rounded))
                    .foregroundStyle(scrubbing == title ? Theme.Colors.selection : Theme.Colors.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 16)
        .padding(.vertical, Theme.Spacing.tight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(scrubbing == nil ? Color.clear : Theme.Colors.subtleFill)
        )
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .gesture(
            // `minimumDistance: 0` so a single click on a letter jumps immediately rather than
            // waiting to find out whether the pointer is going to move.
            DragGesture(minimumDistance: 0)
                .onChanged { value in select(at: value.location.y) }
                .onEnded { _ in scrubbing = nil }
        )
        .calmAnimation(Theme.Motion.appearance, value: scrubbing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jump to a section")
        .accessibilityValue(scrubbing ?? titles.first ?? "")
        .accessibilityHint("Drag to move through the list by section")
        // Adjustable rather than a row of buttons: VoiceOver users get one rotor-friendly control
        // that steps through the sections, instead of twenty-seven stops between the list and
        // whatever is after it.
        .accessibilityAdjustableAction { direction in
            let current = titles.firstIndex(of: scrubbing ?? titles[0]) ?? 0
            let next = direction == .increment
                ? min(titles.count - 1, current + 1)
                : max(0, current - 1)
            scrubbing = titles[next]
            onSelect(titles[next])
        }
        .accessibilityIdentifier("sectionIndexBar")
    }

    /// A time section is called "This week"; the strip has room for one glyph.
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
}

/// The heading shown over the list while the strip is being dragged.
///
/// ### Why this exists at all
/// Scrubbing moves the list faster than it can be read. Without a label the user is dragging against
/// a blur and stopping by luck; with one they are choosing a letter and the list is a consequence.
/// It sits over the list rather than in the strip because the strip is sixteen points wide and this
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
