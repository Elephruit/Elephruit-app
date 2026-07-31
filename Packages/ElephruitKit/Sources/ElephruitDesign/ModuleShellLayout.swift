import CoreGraphics
import Foundation

/// How wide one column of the shell may be.
///
/// A value rather than three arguments at a call site, because the three numbers are only correct
/// together: a minimum above the maximum, or an ideal outside the range, are the two ways a column
/// ends up at a width nobody chose, and neither is visible until the window happens to be a
/// particular size.
public struct PaneWidth: Sendable, Hashable {
    public var minimum: CGFloat
    public var ideal: CGFloat

    /// `nil` for a column that may take whatever is left — the canvas of a module built around one.
    public var maximum: CGFloat?

    public init(minimum: CGFloat, ideal: CGFloat, maximum: CGFloat? = nil) {
        // Normalised on the way in rather than trusted. This type exists to be the one place the
        // three numbers are known to agree, and a policy table is exactly where a typo hides.
        let floor = Swift.max(0, minimum)
        let ceiling = maximum.map { Swift.max($0, floor) }

        self.minimum = floor
        self.maximum = ceiling
        self.ideal = Swift.min(Swift.max(ideal, floor), ceiling ?? .greatestFiniteMagnitude)
    }

    /// A column pinned to one width, which is how a module says *not resizable*.
    public static func fixed(_ width: CGFloat) -> PaneWidth {
        PaneWidth(minimum: width, ideal: width, maximum: width)
    }

    public var isFixed: Bool { maximum == minimum }

    /// The width to use, given what the user last dragged this column to and what the window can
    /// spare.
    ///
    /// ### Why the stored width is never trusted
    /// It was written by a window that no longer exists. It may have come from a 6K display, from a
    /// build whose minimum for this column was lower, or from a policy that has since changed — and
    /// a 900-point person pane restored into a 1000-point window leaves the list and the sidebar
    /// fighting over a hundred points. Restoring is a request, not an instruction; this is where it
    /// is answered.
    ///
    /// `available` wins over ``maximum`` but never over ``minimum``. A column narrower than its
    /// minimum is unusable, and the honest response to a window too small to hold every column is to
    /// drop a column — which is the shell's decision, not this one's.
    public func resolved(stored: CGFloat?, available: CGFloat) -> CGFloat {
        let requested = stored ?? ideal
        let bounded = Swift.min(Swift.max(requested, minimum), maximum ?? .greatestFiniteMagnitude)
        guard available > 0 else { return bounded }
        return Swift.max(minimum, Swift.min(bounded, available))
    }
}

/// What a module wants of the pane on its trailing edge.
///
/// ### Why this is a policy rather than numbers in a view
/// Because the numbers were in the views, and the shell had exactly one set of them: a detail column
/// of `min: 420, ideal: 720` and an inspector of `min: 240, ideal: 300`, applied to every
/// destination in the app. That is right for a person's profile and wrong for a calendar, where the
/// same 720 points is an empty box captioned "Nothing selected" sitting where the month should be —
/// and because AppKit's split view keeps its divider where the user last put it, widening the pane
/// to read a profile *moved the calendar's divider too*. One number cannot be right for a module
/// built around a canvas and a module built around a document. Each module says what it wants, the
/// shell applies it on arrival, and neither can reach the other's.
public struct DetailPanePolicy: Sendable, Hashable {
    /// Whether the module has this pane at all. A module built around a canvas has nothing to put in
    /// a detail column, and the honest expression of that is not a narrow empty one.
    public var isAvailable: Bool

    /// Whether choosing something opens the pane.
    public var opensAfterSelection: Bool

    /// Whether the pane goes away when nothing is selected, rather than reserving space for an
    /// explanation of why it is empty.
    public var hidesWhenNothingSelected: Bool

    public var isResizable: Bool

    public var width: PaneWidth

    /// Below this window width the pane gives way, because the module's primary column matters more.
    ///
    /// Per module for the same reason the widths are: a calendar with no canvas is not a calendar,
    /// and a person's profile with no profile is a list of names.
    public var compactWindowWidth: CGFloat

    public init(
        isAvailable: Bool = true,
        opensAfterSelection: Bool = true,
        hidesWhenNothingSelected: Bool = false,
        isResizable: Bool = true,
        width: PaneWidth,
        compactWindowWidth: CGFloat = 900
    ) {
        self.isAvailable = isAvailable
        self.opensAfterSelection = opensAfterSelection
        self.hidesWhenNothingSelected = hidesWhenNothingSelected
        self.isResizable = isResizable
        self.width = width
        self.compactWindowWidth = compactWindowWidth
    }

    /// A module with no such pane.
    public static let unavailable = DetailPanePolicy(
        isAvailable: false,
        opensAfterSelection: false,
        hidesWhenNothingSelected: true,
        isResizable: false,
        width: .fixed(0),
        compactWindowWidth: 0
    )

    /// Whether the pane should be on screen right now.
    ///
    /// Pure, and deliberately given every input rather than reading any of them, so that "the
    /// inspector vanished when I made the window narrow" is a sentence with a test behind it.
    public func isVisible(
        userWants: Bool,
        hasSelection: Bool,
        windowWidth: CGFloat
    ) -> Bool {
        guard isAvailable else { return false }
        guard windowWidth >= compactWindowWidth else { return false }
        if hidesWhenNothingSelected, !hasSelection { return false }
        return userWants
    }

    /// Whether selecting something should open a pane the user had closed.
    ///
    /// Only when the module said so *and* the pane is one that hides itself when empty. Opening a
    /// pane somebody deliberately closed is the interface overruling them; opening one that closed
    /// itself because there was nothing to show is the interface finishing what it started.
    public func shouldOpenAfterSelection() -> Bool {
        isAvailable && opensAfterSelection && hidesWhenNothingSelected
    }
}

/// Every width decision one module makes about the shell.
///
/// The sidebar is deliberately absent: it is primary navigation and it is the same in every module,
/// so a module that could resize it would be a module reaching outside itself.
public struct ModuleShellLayout: Sendable, Hashable {
    /// The middle column — a module's list, or its canvas when the module is built around one.
    public var primary: PaneWidth

    /// The third column: the selected thing, at length.
    public var detail: DetailPanePolicy

    /// The trailing inspector: what is true *about* the selected thing.
    public var inspector: DetailPanePolicy

    public init(primary: PaneWidth, detail: DetailPanePolicy, inspector: DetailPanePolicy) {
        self.primary = primary
        self.detail = detail
        self.inspector = inspector
    }
}

// MARK: - Which columns survive a narrow window

extension ModuleShellLayout {
    /// A column of the shell, named so a policy can rank them.
    public enum Column: String, Sendable, Hashable, CaseIterable {
        case sidebar
        case primary
        case detail
        case inspector
    }

    /// The columns that fit, in the order this module would give them up.
    ///
    /// Dropped from the trailing edge inwards — inspector, then detail — because both are *about*
    /// something in the primary column, and a module reduced to the thing its content is about has
    /// lost the content. The primary column and the sidebar are never dropped here; the shell's own
    /// two-pane and focus modes are how those go.
    public func columns(fittingWindowOfWidth width: CGFloat, sidebarWidth: CGFloat) -> Set<Column> {
        var kept: Set<Column> = [.sidebar, .primary]
        var remaining = width - sidebarWidth - primary.minimum

        if detail.isAvailable, width >= detail.compactWindowWidth, remaining >= detail.width.minimum {
            kept.insert(.detail)
            remaining -= detail.width.minimum
        }

        if inspector.isAvailable, width >= inspector.compactWindowWidth, remaining >= inspector.width.minimum {
            kept.insert(.inspector)
        }

        return kept
    }
}
