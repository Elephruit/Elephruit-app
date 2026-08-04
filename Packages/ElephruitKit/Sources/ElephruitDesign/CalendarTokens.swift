import Foundation
import SwiftUI

// MARK: - Report series

/// What colour a series in a report is drawn in.
///
/// ### Why a rule rather than a colour per chart
/// Because the same project appears in the daily chart, in the breakdown under it, and on a chip in
/// the tracker at the top of the log — and if those three disagree, the colour is decoration. The
/// rule is the one `TimeChipLabel` already follows: a thing that carries its own tint is drawn in
/// it, everywhere it appears.
///
/// What is new is the fallback. Most rows have no tint of their own — a tag, a person, a project
/// nobody has coloured — and a chart of six identical bars is not colour-coded. Those take a palette
/// entry derived from their visible identity. The mapping is deterministic rather than based on a
/// report's ranking, so the same label keeps its colour across days, periods, and report charts.
public enum ReportSeriesPalette {
    /// The palette entries used for series with no colour of their own, in order.
    ///
    /// Chosen to stay apart at a glance and to survive the two commonest colour-vision deficiencies:
    /// no red beside green, and no pairing that collapses to the same value. Red is absent
    /// altogether — in this app it means *overdue* and *destructive*, and a project that happens to
    /// rank fourth has done nothing wrong.
    ///
    /// Spelled `Theme.Palette.blue` rather than `.blue`, and not only to satisfy
    /// `SourceHygieneTests.coloursComeFromTheDesignSystem` — though it does, and the check is right
    /// to be suspicious of a bare `.blue` it cannot prove is a palette case. Written out, the line
    /// says what it is at a glance: ten entries of the app's own palette, which adapt to light,
    /// dark, Increase Contrast and a non-default accent, rather than ten SwiftUI literals that do
    /// not.
    public static let fallbacks: [Theme.Palette] = [
        Theme.Palette.blue,
        Theme.Palette.orange,
        Theme.Palette.teal,
        Theme.Palette.purple,
        Theme.Palette.yellow,
        Theme.Palette.indigo,
        Theme.Palette.mint,
        Theme.Palette.brown,
        Theme.Palette.cyan,
        Theme.Palette.pink,
    ]

    /// The palette entry for a series, exposed separately so the deterministic mapping is testable
    /// without comparing environment-resolved SwiftUI colours.
    ///
    /// - Parameters:
    ///   - colorName: the item's own stored palette name, when the row has an item and it has one.
    ///   - identity: the label a person uses to recognise the row across charts.
    ///   - isUnassigned: whether this row is an *absence* — "No project", "Untagged", "On your own".
    public static func palette(
        colorName: String?,
        identity: String,
        isUnassigned: Bool
    ) -> Theme.Palette? {
        // An absence is not a category and must not look like one. Grey says "these are the ones
        // that are not filed", which is what the row means, and it keeps the palette for the rows
        // that are actually about something.
        if isUnassigned { return Theme.Palette.graphite }

        if let colorName, let entry = Theme.Palette(rawValue: colorName) { return entry }

        guard !fallbacks.isEmpty else { return nil }
        return fallbacks[stableIndex(for: identity, count: fallbacks.count)]
    }

    /// The colour for a series, given what it carries and the identity it keeps across charts.
    public static func color(colorName: String?, identity: String, isUnassigned: Bool) -> Color {
        palette(colorName: colorName, identity: identity, isUnassigned: isUnassigned)?.color
            ?? Theme.Colors.selection
    }

    /// Swift's `hashValue` is deliberately randomised between launches. FNV-1a is small, stable,
    /// and sufficient for spreading human-readable labels over this short visual palette.
    private static func stableIndex(for identity: String, count: Int) -> Int {
        let canonical = identity
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(count))
    }

    /// Whether a report row's key is one of the sentinels the reporting rules use for "not filed".
    ///
    /// The sentinels are prefixed with a control character precisely so they cannot collide with a
    /// tag somebody typed — see `TimeReporting.slices(for:grouping:clippedTo:calendar:now:)`.
    /// Reading the prefix rather than listing the sentinels means a new one is handled on the day it
    /// is added rather than the day somebody notices it is the wrong colour.
    public static func isUnassignedKey(_ key: String) -> Bool {
        key.hasPrefix("\u{1}")
    }
}

// MARK: - Calendar metrics

extension Theme {
    /// The measurements a calendar grid is built from.
    ///
    /// Separated from ``Theme/Size`` because they are answers to a different question. Those are
    /// about a list of things; these are about a *ruler*, and a ruler's numbers have to relate to
    /// each other — the hour height decides the smallest readable block, which decides the minimum
    /// duration a drag can produce.
    public enum CalendarMetrics {
        /// The width of the hour column down the left of a time grid.
        ///
        /// Wide enough for "12:00 AM" at the default text size. Times are the one label in this app
        /// that must never truncate: a grid whose ruler reads "12:0…" is a grid you cannot read.
        public static let hourRulerWidth: CGFloat = 56

        /// The same column when a second time zone is shown beside the first.
        public static let dualHourRulerWidth: CGFloat = 96

        /// The all-day band's row height.
        public static let allDayRowHeight: CGFloat = 22

        /// The most rows the all-day band shows before it scrolls.
        ///
        /// Three, because a week with four overlapping multi-day events is real but rare, and a band
        /// that grows without limit eats the grid it sits above.
        public static let allDayVisibleRows = 3

        /// The header above each day column in a week view.
        public static let dayHeaderHeight: CGFloat = 44

        /// The smallest block that can hold a title at the default text size.
        public static let minimumBlockHeight: CGFloat = 16

        /// How finely a drag snaps, in minutes.
        ///
        /// Fifteen rather than five: a calendar where dragging produces 09:07 is one where every
        /// event has to be corrected afterwards, and nobody schedules anything at seven past.
        public static let dragSnapMinutes = 15

        /// The grab area at the bottom edge of a block, for resizing.
        public static let resizeHandleHeight: CGFloat = 6

        /// A month cell's minimum height, which is what stops a six-row grid becoming unreadable in
        /// a short window.
        public static let monthCellMinimumHeight: CGFloat = 72

        /// The side of a square in the year view's density map.
        public static let yearCellSize: CGFloat = 11
        public static let yearCellSpacing: CGFloat = 2
    }
}

// MARK: - Calendar colours

extension Theme.Colors {
    /// The line marking the present moment.
    ///
    /// Red, and the only red in a calendar grid, so it cannot be confused with anything else. This
    /// is the one place in the app where a colour carries meaning on its own — but it is also a
    /// *line across the whole width*, which is a shape nothing else has, so it survives greyscale.
    public static let currentTime = SystemColors.red

    /// The shading over hours outside the working day.
    ///
    /// Applied to the *outside*, so working hours are the plain background and the rest is dimmed.
    /// Shading the working hours instead would make the useful part of the day the visually noisy
    /// one.
    public static let outsideWorkingHours = SystemColors.quaternaryFill

    /// The fill of a block being dragged or created.
    public static let draftEvent = Color.accentColor
}

// MARK: - Event colours

extension Theme {
    /// How an event block is coloured, from its calendar's palette name.
    ///
    /// ### Why a block is a tinted fill rather than a solid one
    /// A day of solid blocks is a wall of colour that the eye cannot read titles off, and it makes
    /// the grid — the thing that says *when* — invisible behind it. A tinted fill with a saturated
    /// leading edge keeps the calendar's identity legible at a glance while leaving the text on a
    /// background it can be read against in both appearances.
    public enum EventStyle {
        /// The block's background.
        ///
        /// Stronger than the 18% it shipped at, which photographed as fog — a week of meetings
        /// read as faint washes the grid showed through. Twenty-six percent keeps titles legible
        /// on top in both appearances while the block finally reads as a thing with presence, and
        /// the strength answers Increase Contrast like every other tinted surface.
        public static func fill(colorName: String?, isCancelled: Bool = false) -> Color {
            Theme.Colors.adaptiveAlpha(
                of: Theme.Palette.color(named: colorName),
                standard: isCancelled ? 0.08 : 0.26,
                increasedContrast: isCancelled ? 0.16 : 0.45
            )
        }

        /// The saturated edge and the dot in a list row.
        public static func accent(colorName: String?) -> Color {
            Theme.Palette.color(named: colorName)
        }

        /// The border, which is what separates two adjacent blocks of the same calendar.
        public static func border(colorName: String?) -> Color {
            Theme.Colors.adaptiveAlpha(
                of: Theme.Palette.color(named: colorName),
                standard: 0.5,
                increasedContrast: 0.8
            )
        }
    }
}

// MARK: - Glass

extension View {
    /// The treatment for a floating navigation or creation control.
    ///
    /// ### Where glass is used, and where it is not
    /// On controls that float *over* content and need to stay legible against whatever is behind
    /// them: the view switcher, the quick-entry field, the day-detail popover, the menu bar's
    /// panel. Those are the surfaces where the material is doing work — it separates the control
    /// from the calendar without a hard edge, and it moves with the content beneath it.
    ///
    /// Not on the grid, not on event blocks, not on list rows, and not on anything that already
    /// sits on an opaque background. Glass on a surface with nothing behind it is a gradient
    /// pretending to be depth, and stacked glass is the haze
    /// `SourceHygieneTests.decorationDoesNotAccumulate` exists to catch.
    ///
    /// One shadow and one material per surface. This modifier applies both, so a call site cannot
    /// accidentally add a second of either.
    public func floatingControl(cornerRadius: CGFloat = Theme.Radius.large) -> some View {
        modifier(FloatingControlModifier(cornerRadius: cornerRadius))
    }
}

private struct FloatingControlModifier: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            // Reduce Transparency is a legibility setting, and honouring it means an opaque
            // surface rather than a slightly-less-transparent one. A material at 90% is still a
            // material to somebody who turned it off.
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Theme.Colors.windowBackground)
                        .strokeBorder(Theme.Colors.separator)
                )
        } else {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }
}
