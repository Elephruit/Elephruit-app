import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import SwiftUI

/// The list column of a three-column root: the root's own screen, with drill-down.
///
/// A real `NavigationSplitView` column rather than a hand-laid pane, because each column must own
/// its navigation bar — a title, a search field, an add button. Two stacks laid side by side in an
/// `HStack` proved that the system draws their bars at window level and they land on each other;
/// the split view is the arrangement that knows better.
struct PadContentColumn: View {
    @Environment(PadShellModel.self) private var pad

    var body: some View {
        NavigationStack(
            path: Binding(
                get: { pad.contentPath },
                set: { newPath in
                    // A push arriving through the stack's own binding — a `NavigationLink(value:)`
                    // — is routed rather than appended, so a link and a `shell.push` land in the
                    // same place. Anything else is a pop, which the stack owns.
                    if newPath.count == pad.contentPath.count + 1, let added = newPath.last {
                        pad.route(added)
                    } else {
                        pad.contentPath = newPath
                    }
                }
            )
        ) {
            PadRootScreen(root: pad.root)
                .navigationDestination(for: MobileRoute.self) { route in
                    MobileRouteView(route: route)
                }
        }
        // Which record the reading pane holds, so the list can mark its row.
        .environment(\.padSelectedItemID, selectedItemID)
    }

    private var selectedItemID: UUID? {
        switch pad.detailPath.first {
        case .item(let id), .person(let id), .project(let id): id
        default: nil
        }
    }
}

/// The reading pane: the selected record at length, deepening within itself.
struct PadDetailColumn: View {
    @Environment(PadShellModel.self) private var pad

    var body: some View {
        if pad.detailPath.first != nil {
            PadDetailStack()
        } else {
            ContentUnavailableView {
                Label("Nothing Selected", systemImage: pad.root.emptyDetailSymbolName)
            } description: {
                Text(pad.root.emptyDetailDescription)
            }
            .background(Theme.Colors.windowBackground)
        }
    }
}

/// A canvas root's whole stage: the day, a project, the calendar, time, settings.
///
/// One surface across the width — plus, for the calendar, a trailing pane that exists only while
/// an event is selected: a calendar with nothing chosen should be a calendar, not a calendar and a
/// caption saying nothing is chosen.
struct PadCanvasStage: View {
    @Environment(PadShellModel.self) private var pad

    /// Below this, an inspector would leave the canvas too narrow to be the reason you chose a
    /// canvas — so the record opens over the canvas as a push instead.
    private static let minimumCanvasBesideInspector: CGFloat = 500

    @State private var stageWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            contentColumn
                .frame(maxWidth: pad.root.canvasMeasure ?? .infinity)
                .frame(maxWidth: .infinity)

            if showsInspector, let inspectorWidth = pad.root.canvasInspectorWidth {
                Divider()
                PadDetailStack(showsCloseButton: true)
                    .frame(width: inspectorWidth)
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            stageWidth = width
            pad.isDetailPaneAvailable = hasRoomForInspector(at: width)
        }
    }

    private var showsInspector: Bool {
        !pad.detailPath.isEmpty && hasRoomForInspector(at: stageWidth)
    }

    private func hasRoomForInspector(at width: CGFloat) -> Bool {
        guard let inspectorWidth = pad.root.canvasInspectorWidth else { return false }
        return width >= inspectorWidth + Self.minimumCanvasBesideInspector
    }

    private var contentColumn: some View {
        NavigationStack(
            path: Binding(
                get: { pad.contentPath },
                set: { newPath in
                    if newPath.count == pad.contentPath.count + 1, let added = newPath.last {
                        pad.route(added)
                    } else {
                        pad.contentPath = newPath
                    }
                }
            )
        ) {
            PadRootScreen(root: pad.root)
                .navigationDestination(for: MobileRoute.self) { route in
                    MobileRouteView(route: route)
                }
        }
    }
}

/// One sidebar root's own screen.
///
/// The third dispatch table, and deliberately the only one that knows about roots: `MobileRouteView`
/// turns a drill-down into a screen and `MobileDestinationView` turns a drawer row into one. A root
/// that has a route of its own defers to the route table rather than restating it, so a place
/// cannot look like two different screens depending on how it was reached.
struct PadRootScreen: View {
    let root: PadRoot

    var body: some View {
        switch root {
        case .today:
            TodayScreen()
        case .search:
            SearchScreen()
        case .reminders:
            RemindersScreen()
        case .project(let id):
            // The workspace, not the phone's page — the stage is wide enough for the real answer.
            PadProjectScreen(projectID: id)
        case .calendar:
            // The month and agenda the phone draws, plus the time grid its width could not hold.
            PadCalendarScreen()
        default:
            if let route = root.route {
                MobileRouteView(route: route)
            }
        }
    }
}

/// The stack behind whichever pane is showing the selected record.
///
/// One type for both the three-column reading pane and the canvas's inspector, because they are
/// the same idea at two widths: a record opened *from* the pane deepens the pane rather than
/// replacing it — a person's colleague is a step further into the same reading, not a new subject.
private struct PadDetailStack: View {
    @Environment(PadShellModel.self) private var pad

    var showsCloseButton = false

    /// The pane's own shell, so a `shell.push` inside the pane deepens the pane. Without one the
    /// pane would inherit the stage's shell and every tap in a profile would replace the stage.
    @State private var detailShell = MobileShellModel()

    var body: some View {
        if let first = pad.detailPath.first {
            NavigationStack(
                path: Binding(
                    get: { Array(pad.detailPath.dropFirst()) },
                    set: { rest in pad.detailPath = [first] + rest }
                )
            ) {
                MobileRouteView(route: first)
                    .navigationDestination(for: MobileRoute.self) { route in
                        MobileRouteView(route: route)
                    }
                    .toolbar {
                        if showsCloseButton {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Close", systemImage: "xmark") {
                                    pad.detailPath = []
                                }
                                .accessibilityIdentifier("pad.inspector.close")
                            }
                        }
                    }
            }
            .environment(detailShell)
            .task {
                let pad = pad
                detailShell.routeRedirect = { route in
                    if let promoted = PadRoot(promoting: route) {
                        pad.select(promoted)
                    } else {
                        pad.detailPath.append(route)
                    }
                    return true
                }
            }
            // Keyed on what the pane is showing: a new subject is a new stack, not the old one
            // with its contents swapped underneath a half-finished transition.
            .id(first)
        }
    }
}

/// The stage overlays every arrangement shares: quick capture and the running timer.
struct PadStageOverlays: ViewModifier {
    @Environment(\.services) private var services
    @Environment(PadShellModel.self) private var pad

    func body(content: Content) -> some View {
        @Bindable var pad = pad

        content
            .overlay(alignment: .bottomTrailing) {
                CaptureButton { pad.isCaptureVisible = true }
            }
            .overlay(alignment: .bottom) {
                // Attached only while a timer runs, and floating rather than inset: a stage this
                // wide has room to show the timer without any column paying height for it.
                if services?.timer.running != nil {
                    TimerAccessoryView()
                        .frame(maxWidth: 420)
                        .padding(.vertical, Theme.Spacing.small)
                        .glassEffect(in: Capsule())
                        .padding(.bottom, Theme.Spacing.medium)
                }
            }
    }
}

extension EnvironmentValues {
    /// The record the iPad's reading pane holds, so a list can mark the selected row. `nil`
    /// everywhere the shell does not set it — the phone, sheets, the pane itself.
    @Entry var padSelectedItemID: UUID?
}

extension PadRoot {
    /// The widest a canvas's content is worth drawing, or `nil` to take the stage.
    ///
    /// A measure, not a maximum for its own sake: prose and lists stop being readable long before
    /// they stop fitting, and a thirteen-inch iPad in landscape is two and a half times the width
    /// a line of text wants.
    var canvasMeasure: CGFloat? {
        switch self {
        case .today: 1000
        case .settings: 760
        case .search, .savedSearch: 900
        // The reminders list is one column of short lines with a composer in it; past this it
        // becomes a field of white with text down the left edge.
        case .reminders: 760
        // The month grid and the agenda read as one column; past a thousand points the grid drifts
        // off-centre inside its own card and the agenda's lines overrun a comfortable measure.
        case .calendar: 1000
        default: nil
        }
    }

    /// The width of the trailing pane a canvas offers its selection, or `nil` for none.
    ///
    /// Only the calendar: an event has a title, a time, a place, a calendar and a guest list, and
    /// none of them is prose — 360 points reads all of it beside the month.
    var canvasInspectorWidth: CGFloat? {
        switch self {
        case .calendar: 360
        default: nil
        }
    }

    /// What an empty reading pane says it is empty of — the Mac's per-destination rule, kept: a
    /// hint that names an action belongs only where the action does what it says.
    var emptyDetailSymbolName: String {
        switch self {
        case .trash: "trash"
        case .archive: "archivebox"
        case .records: "person.crop.circle"
        case .inbox: "tray"
        default: "square.on.square.dashed"
        }
    }

    var emptyDetailDescription: String {
        switch self {
        case .trash: "Choose something to read it before putting it back — or emptying it out."
        case .archive: "Choose something you finished to read it again."
        case .records: "Choose somebody to see their profile."
        case .inbox: "Choose a capture to read it, and decide where it belongs."
        default: "Choose something from the list to open it here."
        }
    }
}
