import SwiftUI

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
    public static let currentTime = Color(nsColor: .systemRed)

    /// The shading over hours outside the working day.
    ///
    /// Applied to the *outside*, so working hours are the plain background and the rest is dimmed.
    /// Shading the working hours instead would make the useful part of the day the visually noisy
    /// one.
    public static let outsideWorkingHours = Color(nsColor: .quaternarySystemFill)

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
        public static func fill(colorName: String?, isCancelled: Bool = false) -> Color {
            Theme.Palette.color(named: colorName).opacity(isCancelled ? 0.08 : 0.18)
        }

        /// The saturated edge and the dot in a list row.
        public static func accent(colorName: String?) -> Color {
            Theme.Palette.color(named: colorName)
        }

        /// The border, which is what separates two adjacent blocks of the same calendar.
        public static func border(colorName: String?) -> Color {
            Theme.Palette.color(named: colorName).opacity(0.35)
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
