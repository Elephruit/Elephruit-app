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

    /// The widest this column is ever allowed to be, or infinity for an unbounded one.
    ///
    /// What the shell checks a *laid-out* width against. `widths(windowWidth:…)` says what each
    /// column should get; this says what no column may exceed however the split view got there —
    /// which matters because AppKit restores its remembered divider asynchronously, without
    /// consulting the constraints, and the only reliable answer is to notice and re-pin.
    public func declaredCeiling(of column: Column) -> CGFloat {
        bounds(of: column).maximum ?? .greatestFiniteMagnitude
    }

    /// The narrowest this column is ever allowed to be.
    ///
    /// The sidebar's is passed in rather than declared here: it is primary navigation, it is the
    /// same in every module, and it is derived from the titles it has to fit — see ``SidebarMetrics``.
    public func minimumWidth(of column: Column, sidebarWidth: CGFloat) -> CGFloat {
        switch column {
        case .sidebar: sidebarWidth
        case .primary: primary.minimum
        case .detail: detail.width.minimum
        case .inspector: inspector.width.minimum
        }
    }

    /// Every column's width for one window, decided together.
    ///
    /// `nil` means the column is not on screen, which is a different statement from zero and the
    /// distinction the shell kept losing: a column squeezed to nothing still takes a divider, still
    /// takes its insets, and still draws its empty state one character to a line.
    public struct Widths: Sendable, Hashable {
        public var sidebar: CGFloat?
        public var primary: CGFloat
        public var detail: CGFloat?
        public var inspector: CGFloat?

        /// The columns that are actually on screen, narrowest first — for assertions and for
        /// anything that needs to reason about the set rather than the members.
        public var present: [(column: Column, width: CGFloat)] {
            var found: [(Column, CGFloat)] = [(.primary, primary)]
            if let sidebar { found.append((.sidebar, sidebar)) }
            if let detail { found.append((.detail, detail)) }
            if let inspector { found.append((.inspector, inspector)) }
            return found.sorted { $0.1 < $1.1 }.map { (column: $0.0, width: $0.1) }
        }

        public var total: CGFloat {
            present.reduce(into: CGFloat.zero) { $0 += $1.width }
        }
    }

    /// What every column should be, for one window, in one module.
    ///
    /// ### Why the whole set is decided at once
    /// Because a column's width is not a property of that column. It is what is left after the
    /// others have had what they need, and every part of this that was decided pane-by-pane got it
    /// wrong: each pane checked the *window* against its own threshold, each pane resolved its
    /// stored width against the *window*, and four panes that each cleared their own bar added up to
    /// more window than there was. One function, one set of numbers, and the arithmetic is the same
    /// arithmetic for every module.
    ///
    /// Pure, so "what does Notes look like in a 900-point window with the inspector open" is a value
    /// a test can assert rather than a screenshot somebody has to take.
    public func widths(
        windowWidth: CGFloat,
        sidebarWidth: CGFloat?,
        showsList: Bool = true,
        userWantsInspector: Bool,
        hasSelection: Bool,
        stored: [Column: CGFloat] = [:]
    ) -> Widths {
        let sidebarFootprint = sidebarWidth ?? 0

        var visible = columns(fittingWindowOfWidth: windowWidth, sidebarWidth: sidebarFootprint)
        if sidebarWidth == nil { visible.remove(.sidebar) }
        if !showsList { visible.remove(.primary) }

        // The inspector answers to its module's policy as well as to the arithmetic. Both must say
        // yes: a window wide enough for one does not mean this module wants one here.
        let inspectorFits = visible.contains(.inspector)
            && inspector.isVisible(
                userWants: userWantsInspector,
                hasSelection: hasSelection,
                windowWidth: windowWidth
            )
        if !inspectorFits { visible.remove(.inspector) }

        // What each column would like, already inside its own declared range. An unbounded column —
        // a canvas — asks for whatever is left rather than for a number, so it is settled after the
        // others have said what they want.
        var wanted: [Column: CGFloat] = [:]
        for column in visible.subtracting([.sidebar]) {
            let paneBounds = bounds(of: column)
            guard paneBounds.maximum != nil else { continue }
            wanted[column] = paneBounds.resolved(stored: stored[column], available: windowWidth)
        }

        var spoken = sidebarFootprint + wanted.values.reduce(0, +)

        for column in visible.subtracting([.sidebar]) where bounds(of: column).maximum == nil {
            let floorWidth = minimumWidth(of: column, sidebarWidth: sidebarFootprint)
            wanted[column] = Swift.max(floorWidth, windowWidth - spoken)
            spoken += wanted[column] ?? floorWidth
        }

        // Everybody gives up the same *proportion of what they could spare*, rather than the
        // trailing column giving up everything. A column's slack is the distance between what it
        // wants and what it needs, so nothing can be pushed below its own minimum however tight the
        // window gets — and when it is tighter than every minimum put together, the column set has
        // already had a column taken out of it by `columns(fittingWindowOfWidth:)`.
        let over = spoken - windowWidth
        if over > 0 {
            let slack = wanted.reduce(into: CGFloat.zero) { total, entry in
                total += entry.value - minimumWidth(of: entry.key, sidebarWidth: sidebarFootprint)
            }

            if slack > 0 {
                let toGiveUp = Swift.min(over, slack)
                for (column, width) in wanted {
                    let floorWidth = minimumWidth(of: column, sidebarWidth: sidebarFootprint)
                    let share = (width - floorWidth) / slack
                    wanted[column] = (width - toGiveUp * share).rounded(.down)
                }
            } else {
                for column in wanted.keys {
                    wanted[column] = minimumWidth(of: column, sidebarWidth: sidebarFootprint)
                }
            }
        } else if over < 0 {
            // Room to spare, shared out in the order the columns can use it.
            //
            // ### Why the list gets the first share now
            // It used to get none: every spare point went to the detail column, on the reasoning
            // that "a wider list is a longer line of the same three fields". The warning is sound
            // and the conclusion was too strong. What it was written against was an *unbounded*
            // list — the 1,170-point column of titles this policy exists to prevent — and the
            // bound that prevents it is `primary.maximum`, which every module declares. Growing to
            // a declared ceiling is not the habit being warned about; it is the ceiling doing its
            // job.
            //
            // Measured, the old rule cost more than it saved. In a 1710-point window Today laid the
            // list out at 340 and gave 1,240 to a detail pane showing "Nothing selected", so titles
            // truncated to "Send Maya the dog trai…" with two thirds of the window empty beside
            // them. And the width being protected was largely notional: Notes declares a detail
            // maximum of 960 while the editor inside it caps its measure at
            // `Theme.Size.editorMaxWidth` — 720 — so everything past that was margin either way.
            //
            // So: the list fills to its own ceiling first, and the reading surface takes what is
            // left. Neither can exceed what its module declared, and a module that wants a narrow
            // list still gets one by saying so.
            var spare = -over

            if visible.contains(.detail), let current = wanted[.primary] {
                let ceiling = bounds(of: .primary).maximum ?? current
                let growth = Swift.max(0, Swift.min(spare, ceiling - current))
                wanted[.primary] = current + growth
                spare -= growth
            }

            // Whatever is still going spare lands on the reading surface. Deliberately *not* capped
            // at its declared maximum: something has to absorb the remainder, a column short of the
            // window leaves a strip of nothing beside a divider, and the detail pane is the one
            // surface that already constrains its own content rather than stretching it.
            let elastic: Column = visible.contains(.detail) ? .detail : .primary
            if let current = wanted[elastic] {
                wanted[elastic] = current + spare
            }
        }

        return Widths(
            sidebar: visible.contains(.sidebar) ? sidebarFootprint : nil,
            primary: wanted[.primary] ?? 0,
            detail: visible.contains(.detail) ? wanted[.detail] : nil,
            inspector: visible.contains(.inspector) ? wanted[.inspector] : nil
        )
    }

    /// The declared range for one column.
    private func bounds(of column: Column) -> PaneWidth {
        switch column {
        case .sidebar, .primary: primary
        case .detail: detail.width
        case .inspector: inspector.width
        }
    }

    /// How much width one column may actually take, given the columns beside it.
    ///
    /// ### Why a stored width is not resolved against the window
    /// Because a column does not have the window; it has what the other columns can spare. Resolving
    /// against the window's own width — which is what this replaces — means a 1,100-point list is a
    /// perfectly reasonable request in a 1,400-point window, and the editor beside it gets whatever
    /// is left, which was 118 points. Every column is entitled to its minimum before any column is
    /// entitled to its preference, so that is what comes off the top.
    public func room(
        for column: Column,
        inWindowOfWidth width: CGFloat,
        sidebarWidth: CGFloat,
        showing visible: Set<Column>
    ) -> CGFloat {
        let spokenFor = visible
            .subtracting([column])
            .reduce(into: CGFloat.zero) { total, other in
                total += minimumWidth(of: other, sidebarWidth: sidebarWidth)
            }

        return max(minimumWidth(of: column, sidebarWidth: sidebarWidth), width - spokenFor)
    }
}
