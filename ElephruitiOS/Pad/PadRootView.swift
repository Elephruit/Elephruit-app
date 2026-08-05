import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import SwiftUI

/// The iPad shell: a persistent global sidebar beside a stage.
///
/// Native `NavigationSplitView` columns rather than hand-laid panes, because each column must own
/// its navigation bar — a title, a search field, an add button. Two stacks laid side by side in an
/// `HStack` proved the system draws their bars at window level and they land on each other.
///
/// ### Two columns, or three
/// A list root wants the record beside the list; a canvas root wants the whole stage. But a third
/// column has to be *earned in points*, not asserted: at 1,032 — a 13-inch iPad held upright — a
/// sidebar, a list and a reading pane leave the pane 430 points, which is narrower than a phone
/// and is where a note, a profile or a project brief stops being readable. So below
/// ``threeColumnMinimum`` a list root draws two columns and its records push in the list's own
/// stack, which is the compact behaviour arriving early rather than a separate rule — see
/// `PadShellModel.isDetailPaneAvailable`, which is how the route dispatcher learns about it.
///
/// In practice that means reading panes in landscape and one column in portrait, which is also
/// what Mail, Notes and Reminders do on the same hardware.
///
/// ### The sidebar stays
/// It is resident at every regular width and never collapses itself. Opening a project does not
/// replace it — the tree the user tapped in stays exactly where it was, which is the Mac's own
/// decision kept on a platform where losing your place costs more. Only the user closes it, by the
/// toolbar button or by the same key the Mac uses, and once closed it stays closed until they say
/// otherwise.
///
/// Model ownership, restoration, and the compact handoff live one level up in `AdaptiveRootView`;
/// this view is only the arrangement.
struct PadRootView: View {
    @Environment(PadShellModel.self) private var pad

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// The window width below which a list root gives up its reading pane.
    ///
    /// A 280-point sidebar, a 320-point list, and 520 points left for the record — the narrowest a
    /// page of prose, a profile, or a project's header and work list is worth drawing at.
    private static let threeColumnMinimum: CGFloat = 1120

    @State private var windowWidth: CGFloat = 0

    var body: some View {
        @Bindable var pad = pad

        arrangement
            .modifier(PadStageOverlays())
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                windowWidth = width
            }
            .onChange(of: pad.sidebarToggleRequest) {
                columnVisibility = columnVisibility == .all ? .detailOnly : .all
            }
            .sheet(isPresented: $pad.isCaptureVisible) {
                CaptureSheet()
            }
    }

    /// Whether a list root has room for the record beside the list.
    private var showsReadingPane: Bool {
        pad.root.shape == .listDetail && windowWidth >= Self.threeColumnMinimum
    }

    @ViewBuilder
    private var arrangement: some View {
        if showsReadingPane {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
            } content: {
                PadContentColumn()
                    .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
            } detail: {
                PadDetailColumn()
            }
            .navigationSplitViewStyle(.balanced)
            .task(id: pad.root) { pad.isDetailPaneAvailable = true }
        } else if pad.root.shape == .listDetail {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
            } detail: {
                PadContentColumn()
            }
            .navigationSplitViewStyle(.balanced)
            // No pane to open into, so a record is a push — and whatever the pane was holding
            // goes with it, or the model would be remembering a selection nothing can show.
            .task(id: pad.root) {
                pad.isDetailPaneAvailable = false
                pad.detailPath = []
            }
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
            } detail: {
                PadCanvasStage()
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    private var sidebar: some View {
        PadSidebarView(
            selection: Binding(
                get: { pad.root },
                set: { pad.select($0) }
            )
        )
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
    }
}
