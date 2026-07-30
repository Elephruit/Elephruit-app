import Foundation

/// How many panes a window is showing.
public enum LayoutMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// Sidebar · list · detail.
    case full

    /// List · detail. The sidebar's orienting role passes to a breadcrumb.
    case twoPane

    /// Detail only, centred at a readable measure.
    case focus

    public var displayName: String {
        switch self {
        case .full: "Sidebar, List & Editor"
        case .twoPane: "List & Editor"
        case .focus: "Editor Only"
        }
    }
}

/// A pane that can hold keyboard focus.
public enum ShellPane: String, Sendable, Hashable, Codable, CaseIterable {
    case sidebar
    case list
    case detail
    case inspector
}

extension LayoutMode {
    public var showsSidebar: Bool { self == .full }
    public var showsList: Bool { self != .focus }

    /// Whether a pane is on screen in this mode.
    ///
    /// The inspector is excluded: its visibility is an independent toggle rather than a property of
    /// the layout mode, so it is asked about separately.
    public func isVisible(_ pane: ShellPane) -> Bool {
        switch pane {
        case .sidebar: showsSidebar
        case .list: showsList
        case .detail: true
        case .inspector: true
        }
    }
}

/// What Escape should do next.
public enum EscapeOutcome: Sendable, Hashable {
    case dismissOverlay
    case leaveSearch
    case focusList
    case leaveFocusMode
    case focusSidebar
    case nothing
}

/// Everything the Escape decision depends on.
///
/// A value type so the ladder is a pure function of it, and therefore testable from every starting
/// point without a window.
public struct ShellState: Sendable, Hashable {
    public var hasOverlay: Bool
    public var isSearchActive: Bool
    public var focusedPane: ShellPane
    public var layoutMode: LayoutMode

    public init(
        hasOverlay: Bool = false,
        isSearchActive: Bool = false,
        focusedPane: ShellPane = .list,
        layoutMode: LayoutMode = .full
    ) {
        self.hasOverlay = hasOverlay
        self.isSearchActive = isSearchActive
        self.focusedPane = focusedPane
        self.layoutMode = layoutMode
    }
}

/// Escape, as one rule rather than a handler on every view.
///
/// The rule: **Escape moves one rung outward.** It never destroys work, never changes the selection,
/// and never focuses a pane that is not on screen.
///
/// ```
/// 1.  An open sheet, palette, popover, or menu   → dismiss it, and stop
/// 2.  Search                                     → leave search, restore the previous list
///                                                   and selection, keep the query internally
/// 3.  Detail or inspector                        → focus the list
/// 4.  List, in focus mode                        → leave focus mode
/// 5.  List, sidebar visible                      → focus the sidebar
/// 6.  List, sidebar hidden                       → nothing
/// 7.  Sidebar                                    → nothing
/// ```
///
/// Rung 3 carries the visibility guard that makes the whole thing safe: in focus mode the list is not
/// on screen, so Escape from the detail leaves focus mode — which is what *reveals* the list — rather
/// than moving focus somewhere invisible.
///
/// Rung 1 is modelled here for completeness even though SwiftUI dismisses sheets itself, so that the
/// ladder can be reasoned about and tested as a whole.
public enum EscapeLadder {
    public static func outcome(for state: ShellState) -> EscapeOutcome {
        if state.hasOverlay {
            return .dismissOverlay
        }

        if state.isSearchActive {
            return .leaveSearch
        }

        switch state.focusedPane {
        case .detail, .inspector:
            // Never focus a hidden pane: in focus mode, leaving the mode is what reveals the list.
            return state.layoutMode.isVisible(.list) ? .focusList : .leaveFocusMode

        case .list:
            if state.layoutMode == .focus {
                // Defensive: the list is not on screen in focus mode, so it should not hold focus.
                return .leaveFocusMode
            }
            return state.layoutMode.isVisible(.sidebar) ? .focusSidebar : .nothing

        case .sidebar:
            return .nothing
        }
    }

    /// The pane focus should move to, if the outcome moves it.
    ///
    /// Returns `nil` when the outcome is not a focus change, so a caller cannot accidentally move
    /// focus on an outcome that was about something else.
    public static func destination(for outcome: EscapeOutcome) -> ShellPane? {
        switch outcome {
        case .focusList: .list
        case .focusSidebar: .sidebar
        case .dismissOverlay, .leaveSearch, .leaveFocusMode, .nothing: nil
        }
    }
}

/// Which pane `Tab` moves to next.
///
/// Skips panes that are not on screen, so traversal never lands somewhere invisible — the same rule
/// the Escape ladder follows.
public enum PaneTraversal {
    /// The panes on screen, in reading order.
    public static func visiblePanes(layoutMode: LayoutMode, isInspectorVisible: Bool) -> [ShellPane] {
        var panes: [ShellPane] = []
        if layoutMode.showsSidebar { panes.append(.sidebar) }
        if layoutMode.showsList { panes.append(.list) }
        panes.append(.detail)
        if isInspectorVisible { panes.append(.inspector) }
        return panes
    }

    /// The next pane after `current`, wrapping around.
    public static func next(
        after current: ShellPane,
        layoutMode: LayoutMode,
        isInspectorVisible: Bool,
        reversed: Bool = false
    ) -> ShellPane {
        let panes = visiblePanes(layoutMode: layoutMode, isInspectorVisible: isInspectorVisible)
        guard !panes.isEmpty else { return .detail }

        guard let index = panes.firstIndex(of: current) else {
            // Focus was on a pane that has since been hidden; land on the first visible one.
            return panes[0]
        }

        let step = reversed ? -1 : 1
        let nextIndex = (index + step + panes.count) % panes.count
        return panes[nextIndex]
    }
}
