import SwiftUI

/// One action, drawn as an icon *and* a word.
///
/// ### Why the word is not optional
/// A row of small grey glyphs is a quiz. The person who drew it knows that the waveform beside the
/// telephone is FaceTime Audio and that the speech bubble is *record a conversation* rather than
/// *send a message*; nobody else does, and the tooltip that would tell them costs a second of
/// hovering per button. Pairing the symbol with the verb costs about forty points of width and
/// removes the quiz entirely.
///
/// ### Why every button in a group looks the same
/// Because the alternative is a row where one button shouts. Hierarchy here is carried by *order*
/// and by which actions survive into the visible row at all — see ``AdaptiveActionBar`` — not by
/// making the first one bigger or brighter. That keeps the row calm at every width and stops the
/// design from needing a second, louder treatment the moment two actions are both important.
public struct LabeledActionButton: View {
    private let action: ActionItem
    private let showsTitle: Bool

    public init(_ action: ActionItem, showsTitle: Bool = true) {
        self.action = action
        self.showsTitle = showsTitle
    }

    public var body: some View {
        Button(role: action.role, action: action.perform) {
            Group {
                if showsTitle {
                    Label(action.title, systemImage: action.symbolName)
                        .labelStyle(.titleAndIcon)
                } else {
                    Label(action.title, systemImage: action.symbolName)
                        .labelStyle(.iconOnly)
                }
            }
            .font(Theme.Text.rowSubtitle)
            // A fixed height rather than whatever each label happens to need, so a row of these has
            // one baseline and one hit target size regardless of which symbols are in it.
            .frame(height: 15)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(!action.isEnabled)
        .help(action.tooltip ?? action.title)
        // The name is the verb even when the word is not drawn, so an icon-only fallback is still
        // usable with the keyboard and with VoiceOver.
        .accessibilityLabel(action.title)
        .accessibilityHint(action.accessibilityHint ?? "")
        .accessibilityIdentifier("action.\(action.id)")
    }
}

/// A row of actions that gives up its labels, and then its buttons, in a stated order.
///
/// ### The problem this solves
/// A detail pane is a column whose width the user owns. The same row of actions has to work at 400
/// points and at 900, and the three usual answers are all bad: truncating cuts the words off the
/// most important button as readily as the least; a horizontal scroller hides actions behind a
/// gesture nobody discovers; and drawing everything icon-only at all widths solves the narrow case
/// by making the wide case worse.
///
/// ### What it does instead
/// It offers the layout engine a series of complete, non-clipping arrangements, most generous first,
/// and takes the first that fits. Everything labelled; then the least important action moves into a
/// **More** menu, and the next, and the next; and only when even two labelled buttons will not fit
/// does it fall back to icons — which keep their tooltips and their accessible names, so the
/// fallback is a smaller row rather than a worse one.
///
/// Nothing is ever hidden without somewhere to reach it: whatever leaves the row is in the menu, and
/// the menu appears exactly when it has something in it.
public struct AdaptiveActionBar: View {
    private let actions: [ActionItem]
    private let overflowTitle: String

    /// How many labelled buttons must survive before icons are considered.
    ///
    /// Two, so the fallback is reached only when the pane is genuinely too narrow for a pair of
    /// words rather than whenever the row would prefer more room.
    private let minimumLabelled: Int

    public init(
        _ actions: [ActionItem],
        overflowTitle: String = "More",
        minimumLabelled: Int = 2
    ) {
        self.actions = actions.rankedForDisplay()
        self.overflowTitle = overflowTitle
        self.minimumLabelled = minimumLabelled
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(candidates, id: \.id) { candidate in
                row(labelled: candidate.labelled, iconOnly: candidate.iconOnly)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions")
    }

    // MARK: - The arrangements offered, in order of preference

    private struct Candidate: Identifiable {
        var id: String { "\(labelled)-\(iconOnly)" }
        /// How many actions keep their word.
        let labelled: Int
        /// How many of the remainder stay in the row as icons rather than moving to the menu.
        let iconOnly: Int
    }

    private var candidates: [Candidate] {
        var out: [Candidate] = []

        // Everything, then shed one label at a time into the menu.
        for count in stride(from: actions.count, through: minimumLabelled, by: -1) {
            out.append(Candidate(labelled: count, iconOnly: 0))
        }

        // Last resort. Icons keep their tooltips and their accessible names; what they lose is the
        // word, which is the cheapest thing in the row to lose and the only one left.
        out.append(Candidate(labelled: 1, iconOnly: min(2, max(0, actions.count - 1))))
        out.append(Candidate(labelled: 0, iconOnly: min(2, actions.count)))
        out.append(Candidate(labelled: 0, iconOnly: 0))

        return out
    }

    private func row(labelled: Int, iconOnly: Int) -> some View {
        let visible = min(labelled + iconOnly, actions.count)
        let overflow = Array(actions.dropFirst(visible))

        return HStack(spacing: Theme.Spacing.small) {
            ForEach(Array(actions.prefix(visible).enumerated()), id: \.element.id) { index, action in
                LabeledActionButton(action, showsTitle: index < labelled)
            }

            if !overflow.isEmpty {
                overflowMenu(overflow)
            }
        }
        // The row must not decide the pane's minimum width: `ViewThatFits` has already guaranteed
        // that whichever arrangement is chosen fits, and letting the row push back would make the
        // narrowest arrangement the pane's floor.
        .fixedSize(horizontal: true, vertical: false)
    }

    private func overflowMenu(_ overflow: [ActionItem]) -> some View {
        Menu {
            ForEach(overflow) { action in
                Button(role: action.role, action: action.perform) {
                    Label(action.title, systemImage: action.symbolName)
                }
                .disabled(!action.isEnabled)
                .help(action.tooltip ?? action.title)
            }
        } label: {
            Label(overflowTitle, systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .font(Theme.Text.rowSubtitle)
                .frame(height: 15)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.bordered)
        .fixedSize()
        .help("\(overflowTitle): \(overflow.map(\.title).joined(separator: ", "))")
        .accessibilityLabel(overflowTitle)
        .accessibilityHint("\(overflow.count) more actions")
        .accessibilityIdentifier("action.overflow")
    }
}

/// Chooses how many actions fit, without a window.
///
/// ``AdaptiveActionBar`` hands the arrangement decision to `ViewThatFits`, which is the right answer
/// on screen — it measures the real buttons at the real text size — and no answer at all in a test.
/// This is the same rule expressed arithmetically, so the properties that matter can be asserted:
/// that the row never clips, that the most important action is the last to lose its word, and that
/// nothing is ever dropped without landing in the menu.
public enum ActionBarFit {
    /// What a row of `count` actions looks like in `width` points.
    ///
    /// - Returns: how many keep their label, how many stay as icons, and how many move to the menu.
    public static func arrangement(
        actionCount: Int,
        labelledWidth: CGFloat,
        iconWidth: CGFloat,
        overflowWidth: CGFloat,
        spacing: CGFloat,
        available: CGFloat,
        minimumLabelled: Int = 2
    ) -> (labelled: Int, iconOnly: Int, overflow: Int) {
        guard actionCount > 0 else { return (0, 0, 0) }

        func fits(labelled: Int, iconOnly: Int) -> Bool {
            let visible = labelled + iconOnly
            let hasMenu = visible < actionCount
            let items = visible + (hasMenu ? 1 : 0)
            guard items > 0 else { return true }

            let content = CGFloat(labelled) * labelledWidth
                + CGFloat(iconOnly) * iconWidth
                + (hasMenu ? overflowWidth : 0)
            return content + spacing * CGFloat(items - 1) <= available
        }

        for count in stride(from: actionCount, through: minimumLabelled, by: -1)
        where fits(labelled: count, iconOnly: 0) {
            return (count, 0, actionCount - count)
        }

        let iconFallback = min(2, max(0, actionCount - 1))
        if fits(labelled: 1, iconOnly: iconFallback) {
            return (1, iconFallback, actionCount - 1 - iconFallback)
        }

        let iconsOnly = min(2, actionCount)
        if fits(labelled: 0, iconOnly: iconsOnly) {
            return (0, iconsOnly, actionCount - iconsOnly)
        }

        // Everything in the menu. Still reachable, still named, and still not clipped — which is the
        // one guarantee that has to hold at every width.
        return (0, 0, actionCount)
    }
}
