import ElephruitCore
import ElephruitFeatures
import Foundation
import Testing

/// **Criterion A1-9** — Escape follows the ladder from every starting point, never focuses a hidden
/// pane, and never changes the selection.
///
/// The ladder is a pure function of ``ShellState``, so every rung and every combination of layout
/// mode and focus can be exercised without a window. That matters because the failure mode being
/// guarded against is subtle: Escape moving focus to a pane that is not on screen leaves the keyboard
/// apparently dead, and a manual test only finds it if you happen to be in the right mode.
@Suite("Escape ladder")
struct EscapeLadderTests {
    // MARK: Rung order

    @Test("An overlay is dismissed before anything else")
    func overlayWinsOverEverything() {
        // Even mid-search, in focus mode, with focus in the detail — the sheet goes first.
        let state = ShellState(
            hasOverlay: true,
            isSearchActive: true,
            focusedPane: .detail,
            layoutMode: .focus
        )
        #expect(EscapeLadder.outcome(for: state) == .dismissOverlay)
    }

    @Test("Search is left before focus moves anywhere")
    func searchOutranksFocus() {
        for pane in ShellPane.allCases {
            for mode in LayoutMode.allCases {
                let state = ShellState(isSearchActive: true, focusedPane: pane, layoutMode: mode)
                #expect(
                    EscapeLadder.outcome(for: state) == .leaveSearch,
                    "Search should be left from \(pane) in \(mode)"
                )
            }
        }
    }

    // MARK: Focus movement

    @Test("Escape from the detail focuses the list")
    func detailFallsBackToList() {
        let state = ShellState(focusedPane: .detail, layoutMode: .full)
        #expect(EscapeLadder.outcome(for: state) == .focusList)
    }

    @Test("Escape from the inspector focuses the list too")
    func inspectorFallsBackToList() {
        let state = ShellState(focusedPane: .inspector, layoutMode: .twoPane)
        #expect(EscapeLadder.outcome(for: state) == .focusList)
    }

    @Test("Escape from the list focuses the sidebar when it is showing")
    func listFallsBackToSidebar() {
        let state = ShellState(focusedPane: .list, layoutMode: .full)
        #expect(EscapeLadder.outcome(for: state) == .focusSidebar)
    }

    @Test("Escape from the sidebar does nothing")
    func sidebarIsTheOutermostRung() {
        let state = ShellState(focusedPane: .sidebar, layoutMode: .full)
        #expect(EscapeLadder.outcome(for: state) == .nothing)
    }

    // MARK: The visibility guard

    @Test("Escape never focuses a hidden pane")
    func neverFocusesSomethingInvisible() {
        // Exhaustive: every pane, every mode, search on and off.
        for pane in ShellPane.allCases {
            for mode in LayoutMode.allCases {
                for searching in [true, false] {
                    let state = ShellState(
                        isSearchActive: searching,
                        focusedPane: pane,
                        layoutMode: mode
                    )
                    let outcome = EscapeLadder.outcome(for: state)

                    guard let destination = EscapeLadder.destination(for: outcome) else { continue }
                    #expect(
                        mode.isVisible(destination),
                        "Escape from \(pane) in \(mode) would focus the hidden \(destination)"
                    )
                }
            }
        }
    }

    @Test("In focus mode the detail escapes by leaving the mode, not to a hidden list")
    func focusModeLeavesTheModeFirst() {
        let state = ShellState(focusedPane: .detail, layoutMode: .focus)
        // The list is not on screen, so leaving the mode is what reveals it.
        #expect(EscapeLadder.outcome(for: state) == .leaveFocusMode)
    }

    @Test("With the sidebar hidden, escaping the list does nothing rather than reaching for it")
    func twoPaneStopsAtTheList() {
        let state = ShellState(focusedPane: .list, layoutMode: .twoPane)
        #expect(EscapeLadder.outcome(for: state) == .nothing)
    }

    @Test("Every state produces exactly one outcome, and no state is unhandled")
    func totality() {
        for pane in ShellPane.allCases {
            for mode in LayoutMode.allCases {
                for searching in [true, false] {
                    for overlay in [true, false] {
                        let state = ShellState(
                            hasOverlay: overlay,
                            isSearchActive: searching,
                            focusedPane: pane,
                            layoutMode: mode
                        )
                        // Reaching here without trapping is the assertion; the ladder is total.
                        _ = EscapeLadder.outcome(for: state)
                    }
                }
            }
        }
    }
}

@Suite("Layout modes")
struct LayoutModeTests {
    @Test("Each mode shows what it says it shows")
    func visibilityMatchesTheMode() {
        #expect(LayoutMode.full.showsSidebar)
        #expect(LayoutMode.full.showsList)

        #expect(LayoutMode.twoPane.showsSidebar == false)
        #expect(LayoutMode.twoPane.showsList)

        #expect(LayoutMode.focus.showsSidebar == false)
        #expect(LayoutMode.focus.showsList == false)

        // The detail is the one pane always on screen — it is what the window is for.
        for mode in LayoutMode.allCases {
            #expect(mode.isVisible(.detail))
        }
    }
}

@Suite("Pane traversal")
struct PaneTraversalTests {
    @Test("Tab visits only the panes that are on screen")
    func traversalSkipsHiddenPanes() {
        #expect(
            PaneTraversal.visiblePanes(layoutMode: .full, isInspectorVisible: false)
                == [.sidebar, .list, .detail]
        )
        #expect(
            PaneTraversal.visiblePanes(layoutMode: .twoPane, isInspectorVisible: true)
                == [.list, .detail, .inspector]
        )
        #expect(
            PaneTraversal.visiblePanes(layoutMode: .focus, isInspectorVisible: false) == [.detail]
        )
    }

    @Test("Traversal wraps around in both directions")
    func traversalWraps() {
        let next = PaneTraversal.next(after: .detail, layoutMode: .full, isInspectorVisible: false)
        #expect(next == .sidebar)

        let previous = PaneTraversal.next(
            after: .sidebar,
            layoutMode: .full,
            isInspectorVisible: false,
            reversed: true
        )
        #expect(previous == .detail)
    }

    @Test("Focus held on a pane that has since been hidden lands somewhere visible")
    func recoversFromAHiddenFocus() {
        // The sidebar was focused, then the mode changed to hide it.
        let landing = PaneTraversal.next(after: .sidebar, layoutMode: .focus, isInspectorVisible: false)
        #expect(landing == .detail)
    }

    @Test("Traversal never returns a hidden pane")
    func traversalNeverReturnsHidden() {
        for pane in ShellPane.allCases {
            for mode in LayoutMode.allCases {
                for inspector in [true, false] {
                    for reversed in [true, false] {
                        let next = PaneTraversal.next(
                            after: pane,
                            layoutMode: mode,
                            isInspectorVisible: inspector,
                            reversed: reversed
                        )
                        let visible = PaneTraversal.visiblePanes(
                            layoutMode: mode,
                            isInspectorVisible: inspector
                        )
                        #expect(visible.contains(next), "\(next) is not visible in \(mode)")
                    }
                }
            }
        }
    }
}
