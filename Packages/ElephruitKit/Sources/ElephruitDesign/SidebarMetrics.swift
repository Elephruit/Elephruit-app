import AppKit
import SwiftUI

/// The sidebar's measurements.
///
/// These are **defaults and rules, not constants**. The published numbers describe how the sidebar
/// looks at the standard text size on a standard display; what actually governs it is the derivation
/// in ``SidebarMetrics/minimumWidth(fittingTitles:font:)``.
///
/// The rule that matters: **primary navigation is never truncated.** An ambiguous "Proj…" costs more
/// than a wider sidebar does, so when a longer label cannot fit — after localisation, or at an
/// accessibility text size — the sidebar's minimum width grows and the window yields. Finder and Mail
/// behave the same way.
///
/// An icon-only rail at extreme narrowness was considered and rejected: a derived minimum is simpler,
/// more predictable, and does not introduce a second visual mode to design and test.
public enum SidebarMetrics {
    // MARK: Widths

    /// What the sidebar opens at, absent a restored width.
    public static let defaultWidth: CGFloat = 240

    /// The narrowest the sidebar is ever allowed to be, before content is considered.
    ///
    /// A floor, not the minimum — ``minimumWidth(fittingTitles:font:)`` may return more.
    public static let floorWidth: CGFloat = 180

    public static let maximumWidth: CGFloat = 300

    // MARK: Row geometry

    /// Row height at the standard text size. Scaled by `@ScaledMetric` at the call site, so it grows
    /// with the system text-size setting and with the control-size preference.
    public static let baseRowHeight: CGFloat = 26

    public static let leadingInset: CGFloat = 10
    public static let trailingInset: CGFloat = 10

    /// A fixed glyph column, so titles align down the list even when their symbols differ in width.
    public static let iconColumn: CGFloat = 16
    public static let iconGap: CGFloat = 8

    /// Space held for a count, so a badge appearing never reflows the label.
    public static let countReserve: CGFloat = 26

    /// Selection and hover inset from the row's edges.
    public static let selectionInset: CGFloat = 4
    public static let selectionRadius: CGFloat = 6

    /// Everything in a row that is not the label itself.
    public static var chromeWidth: CGFloat {
        leadingInset + iconColumn + iconGap + countReserve + trailingInset
    }

    // MARK: Derivation

    /// The narrowest width at which every one of `titles` still fits without truncating.
    ///
    /// Pure, and therefore testable without a window: given longer titles or a larger font, it must
    /// return more. That test is what stops the "primary navigation never truncates" rule from
    /// quietly becoming untrue after a localisation pass.
    public static func minimumWidth(fittingTitles titles: [String], font: NSFont) -> CGFloat {
        let widest = titles.reduce(into: CGFloat.zero) { widest, title in
            let width = (title as NSString).size(withAttributes: [.font: font]).width
            widest = max(widest, width)
        }

        return max(floorWidth, ceil(widest + chromeWidth))
    }

    /// The same derivation against the current system text size.
    public static func minimumWidth(fittingTitles titles: [String]) -> CGFloat {
        minimumWidth(fittingTitles: titles, font: .preferredFont(forTextStyle: .body))
    }

    /// The ideal width: the default, unless content demands more.
    public static func idealWidth(fittingTitles titles: [String]) -> CGFloat {
        max(defaultWidth, minimumWidth(fittingTitles: titles))
    }

    /// All three widths at once, against the current system text size.
    ///
    /// ### Why this is memoised and the derivation above is not
    /// Measuring twenty-five titles costs about 125µs, because `size(withAttributes:)` lays each one
    /// out for real. That is a fair price for an answer that changes only when the titles or the
    /// system text size do — and a ruinous one to pay twice on every evaluation of the window's body,
    /// which is what asking for the minimum and the ideal separately amounted to. The shell's body
    /// runs on every frame of a sidebar collapse; 250µs of text layout per frame is a quarter of the
    /// budget spent re-deriving a number that had not moved.
    ///
    /// The cache is keyed by the titles *and* the font, so a localisation pass or a change of text
    /// size produces a different key and a fresh measurement rather than a stale answer. The pure
    /// derivation above is left exactly as it was: it is what the tests hold the rule to, and a rule
    /// verified through a cache is a rule verified through an implementation detail.
    ///
    /// On the main actor because that is where windows are laid out and because it is the cheapest
    /// honest way to have shared mutable state — a lock would work and would be a lock protecting
    /// something only one thread was ever going to touch.
    @MainActor
    public static func widths(fittingTitles titles: [String]) -> SidebarWidths {
        let font = NSFont.preferredFont(forTextStyle: .body)
        let key = CacheKey(titles: titles, fontName: font.fontName, pointSize: font.pointSize)

        if let cached = cachedWidths[key] { return cached }

        let minimum = minimumWidth(fittingTitles: titles, font: font)
        let widths = SidebarWidths(
            minimum: minimum,
            ideal: max(defaultWidth, minimum),
            maximum: maximumWidth
        )
        cachedWidths[key] = widths
        return widths
    }

    private struct CacheKey: Hashable {
        var titles: [String]
        var fontName: String
        var pointSize: CGFloat
    }

    /// Bounded by the number of distinct title sets the app asks about, which is one, times the
    /// number of text sizes it is asked at during a session, which is rarely more than one.
    @MainActor private static var cachedWidths: [CacheKey: SidebarWidths] = [:]
}

/// The sidebar's three widths, derived together.
///
/// One value rather than three calls, because the three are only correct together and because
/// deriving them is the expensive part — see ``SidebarMetrics/widths(fittingTitles:)``.
public struct SidebarWidths: Sendable, Hashable {
    public var minimum: CGFloat
    public var ideal: CGFloat
    public var maximum: CGFloat

    public init(minimum: CGFloat, ideal: CGFloat, maximum: CGFloat) {
        self.minimum = minimum
        self.ideal = ideal
        self.maximum = maximum
    }
}
