import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// A project on the iPad: a workspace, not a page.
///
/// The phone draws a project as one grouped list, and says why: a board with four columns at 400
/// points is a list with extra steps. The stage here is three times that, so the iPad gives the
/// Mac's answer instead — one header, one row of views, and the work drawn as the chosen view
/// wants it: a board with real columns, a grouped list, a table, the bug queue in severity bands,
/// and an overview for standing back.
///
/// The global sidebar stays exactly where it was throughout. These tabs are the *project's* own
/// navigation, and they look like it.
///
/// A piece of work opens in a sheet hosting `ItemScreen`, the one canonical editor — which is what
/// makes "a bug is editable from every presentation" a property of the architecture rather than a
/// checklist. Nine sections of editor do not read in a pane squeezed out of the board's width.
struct PadProjectScreen: View {
    @Environment(\.services) private var services

    let projectID: UUID

    @State private var project: Item?
    @State private var presentation: PadProjectPresentation = PadReviewLaunch.requestedProjectView ?? .board
    @State private var presented: PresentedWorkItem?
    @State private var entryText = ""

    var body: some View {
        Group {
            if let project {
                content(project)
            } else {
                Color.clear
            }
        }
        .task(id: reloadKey) { load() }
        .sheet(item: $presented) { presented in
            NavigationStack {
                ItemScreen(itemID: presented.id)
            }
            .presentationSizing(.page)
        }
    }

    private var reloadKey: String {
        "\(services?.changeToken ?? 0)-\(projectID.uuidString)"
    }

    private func content(_ project: Item) -> some View {
        VStack(spacing: 0) {
            PadProjectHeader(project: project)

            PadProjectTabBar(selection: $presentation)

            Divider()

            Group {
                switch presentation {
                case .overview:
                    PadProjectOverview(project: project, open: open)
                        .frame(maxWidth: 900)
                        .frame(maxWidth: .infinity)
                case .board:
                    PadProjectBoard(project: project, open: open)
                case .list:
                    PadProjectList(project: project, open: open)
                case .table:
                    PadProjectTable(project: project, open: open)
                case .bugs:
                    PadProjectBugs(project: project, open: open)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(project.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Open as Item", systemImage: "square.and.pencil") {
                        presented = PresentedWorkItem(id: project.id)
                    }
                    if project.shouldSuggestCompletion {
                        Button("Complete Project", systemImage: "checkmark.seal") {
                            perform { try $0.items.completeProject(project) }
                        }
                    }
                    Divider()
                    Button("Move to Trash", systemImage: "trash", role: .destructive) {
                        perform { try $0.items.moveToTrash(project) }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("pad.project.menu")
            }
        }
        .safeAreaInset(edge: .bottom) { quickAdd(project) }
        .accessibilityIdentifier("pad.project.screen")
    }

    /// Opens one piece of work in the canonical editor.
    private func open(_ id: UUID) {
        presented = PresentedWorkItem(id: id)
    }

    // MARK: - Quick add

    /// One field at the foot of every view, because the answer to "where do I add work" must not
    /// depend on which view you happen to be looking at. What it creates does: the bug queue files
    /// a bug, everything else files ordinary work.
    private func quickAdd(_ project: Item) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            TextField(
                presentation == .bugs ? "File a bug…" : "Add work…",
                text: $entryText
            )
            .textFieldStyle(.plain)
            .onSubmit { commitEntry(project) }
            .accessibilityIdentifier("pad.project.entry")

            if !entryText.isEmpty {
                Button {
                    commitEntry(project)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .accessibilityLabel(presentation == .bugs ? "File bug" : "Add work")
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.small)
        .background(.bar)
    }

    private func commitEntry(_ project: Item) {
        guard let services else { return }
        let text = entryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        services.perform {
            let created: Item
            if presentation == .bugs {
                created = try services.bugs.fileBug(title: text, in: project)
            } else {
                created = try services.workItems.createWorkItem(title: text, in: project)
            }
            services.noteChange(to: created)
        }
        entryText = ""
        load()
    }

    // MARK: - Data

    private func load() {
        guard let services else { return }
        project = try? services.items.item(id: projectID)

        // A project becomes a workspace by being looked at: idempotent, additive, and exactly what
        // the Mac does on open — a key and columns for a project made before any of this existed.
        if let project {
            services.perform {
                if try services.projectWorkspace.ensureWorkspace(for: project) {
                    services.noteChange(to: project)
                }
            }
        }
    }

    private func perform(_ work: (AppServices) throws -> Void) {
        guard let services, let project else { return }
        services.perform {
            try work(services)
            services.noteChange(to: project)
        }
        load()
    }
}

/// The record a sheet is open on.
struct PresentedWorkItem: Identifiable, Hashable {
    let id: UUID
}

/// The project views the iPad draws.
///
/// A subset of the Mac's seven, chosen by what a tablet genuinely holds: a board with columns, the
/// grouped list, a real table, the bug queue, and standing back. The project calendar and the
/// timeline stay honest by their absence rather than shipping squeezed.
enum PadProjectPresentation: String, CaseIterable, Hashable {
    case overview
    case board
    case list
    case table
    case bugs

    /// The Mac's per-view identity — name, glyph, and the fixed per-kind colour, so the same lens
    /// is the same colour in both apps.
    var viewKind: ProjectViewKind {
        switch self {
        case .overview: .overview
        case .board: .board
        case .list: .list
        case .table: .table
        case .bugs: .bugs
        }
    }
}

// MARK: - Header

/// One line of standing: progress in words, open bugs, the project key.
struct PadProjectHeader: View {
    @Environment(\.services) private var services

    let project: Item

    @State private var openBugCount = 0

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            let progress = project.taskProgress()
            if progress.total > 0 {
                PadProgressRing(fraction: Double(progress.completed) / Double(progress.total))
                Text("\(progress.completed) of \(progress.total) done")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
            } else {
                Text("No work yet")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            if openBugCount > 0 {
                Label("^[\(openBugCount) open bug](inflect: true)", systemImage: "ant")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.warning)
            }

            Spacer()

            if let key = project.projectKey {
                Text(key)
                    .font(Theme.Text.keyHint)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.small)
        .task(id: services?.changeToken) {
            openBugCount = services?.bugs.openBugs(in: project).count ?? 0
        }
    }
}

/// The one figure a project is asked for most, as a ring.
///
/// Drawn rather than borrowed: the platform's circular `ProgressView` is a spinner, and a linear
/// bar at this size is a grey line with a blue tip. The words beside it carry the answer; this
/// carries the glance.
struct PadProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.Colors.separator, lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(Theme.Colors.completed, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

// MARK: - Tabs

/// The project's own navigation: one row of named views, coloured per kind and never *only* by
/// colour — the name is always drawn beside the glyph.
struct PadProjectTabBar: View {
    @Binding var selection: PadProjectPresentation

    var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            ForEach(PadProjectPresentation.allCases, id: \.self) { presentation in
                tab(presentation)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.bottom, Theme.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project views")
    }

    private func tab(_ presentation: PadProjectPresentation) -> some View {
        let kind = presentation.viewKind
        let isSelected = selection == presentation
        let tint = Theme.Palette.color(named: kind.colorName)

        return Button {
            selection = presentation
        } label: {
            Label(kind.displayName, systemImage: kind.symbolName)
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(isSelected ? tint : Theme.Colors.secondaryText)
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.tight)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .fill(isSelected ? tint.opacity(0.14) : .clear)
                )
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("pad.project.view.\(presentation.rawValue)")
    }
}
