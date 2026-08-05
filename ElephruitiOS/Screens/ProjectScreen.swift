import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// A project: how far along it is, what is left, and what has been written about it.
///
/// The Mac's project workspace is a board, a timeline, a table and a brief in four switchable
/// views. A phone gets the one view the other three are summaries of — the work, grouped by the
/// project's own workflow stages when it has them and by nothing when it does not — because a
/// board with four columns at 400 points is a list with extra steps, and a timeline is a
/// picture you cannot read at this width.
///
/// The stages come from `ProjectWorkspaceService`, so a project whose owner arranged five
/// stages on the Mac sees those five stages here, in that order, under those names.
struct ProjectScreen: View {
    @Environment(\.services) private var services
    @Environment(MobileShellModel.self) private var shell

    let projectID: UUID

    @State private var project: Item?
    @State private var stages: [WorkflowStage] = []
    @State private var work: [Item] = []
    @State private var notes: [Item] = []
    @State private var loadError: String?

    var body: some View {
        List {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.Colors.warning)
            }

            if let project {
                headerSection(project)
                workSections
                notesSection
            } else if loadError == nil {
                EmptyStateView(
                    symbolName: "folder",
                    headline: "Project not found",
                    message: "It may have been deleted or moved to the Trash."
                )
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(project?.displayTitle ?? "Project")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reloadKey) { reload() }
        .accessibilityIdentifier("project.screen")
    }

    private var reloadKey: String {
        "\(services?.changeToken ?? 0)-\(projectID.uuidString)"
    }

    // MARK: - Sections

    private func headerSection(_ project: Item) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack(spacing: Theme.Spacing.medium) {
                    Image(systemName: project.effectiveSymbolName)
                        .font(.title2)
                        .foregroundStyle(Theme.Palette.color(named: project.colorName))

                    Text(project.displayTitle)
                        .font(Theme.Text.title)

                    Spacer(minLength: 0)
                }

                // The one number a project is asked for most, said as a bar and as words —
                // the bar for the glance, the words for the answer.
                ProgressView(value: completionFraction)
                    .tint(Theme.Colors.completed)

                Text(progressSummary)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)

                if let dueAt = project.dueAt, let clock = services?.dateProvider {
                    Label(
                        "Deadline \(RelativeDay.text(for: dueAt, using: clock))",
                        systemImage: "calendar.badge.exclamationmark"
                    )
                    .font(Theme.Text.metadata)
                    .foregroundStyle(DateUrgency.color(for: dueAt, using: clock))
                }

                if !project.tagSlugs.isEmpty {
                    TagChipRow(slugs: project.tagSlugs, limit: 6)
                }
            }
            .padding(.vertical, Theme.Spacing.tight)
            .accessibilityElement(children: .combine)
        }
    }

    /// The work, under the project's own stage names when it has them.
    ///
    /// Items whose stage was deleted, or which never had one, are not dropped — they collect
    /// under "Unstaged", because a project view that silently omits work is worse than one
    /// that admits it does not know where a piece belongs.
    @ViewBuilder
    private var workSections: some View {
        if work.isEmpty {
            Section {
                Text("Nothing filed under this project yet.")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
        } else if stages.isEmpty {
            Section("Work") {
                ForEach(work) { item in
                    workRow(item)
                }
            }
        } else {
            ForEach(stages, id: \.id) { stage in
                let staged = work.filter { $0.workflowStageID == stage.id }
                if !staged.isEmpty {
                    Section(stage.name) {
                        ForEach(staged) { item in
                            workRow(item)
                        }
                    }
                }
            }

            let stageIDs = Set(stages.map(\.id))
            let unstaged = work.filter { item in
                item.workflowStageID.map { !stageIDs.contains($0) } ?? true
            }
            if !unstaged.isEmpty {
                Section("Unstaged") {
                    ForEach(unstaged) { item in
                        workRow(item)
                    }
                }
            }
        }
    }

    private func workRow(_ item: Item) -> some View {
        MobileItemRow(
            item: item,
            // The section already names the project; a row repeating it is the list
            // stuttering — the same rule the row anatomy states.
            showsParent: false,
            onToggleCompletion: item.kind.supportsStatus ? { toggleCompletion(of: item) } : nil
        )
        .contentShape(Rectangle())
        .onTapGesture {
            shell.push(MobileShellModel.route(for: item.kind, id: item.id))
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        if !notes.isEmpty {
            Section("Notes") {
                ForEach(notes) { note in
                    MobileItemRow(item: note, showsParent: false)
                        .contentShape(Rectangle())
                        .onTapGesture { shell.push(.item(note.id)) }
                }
            }
        }
    }

    // MARK: - Progress

    private var completionFraction: Double {
        let countable = work.filter(\.kind.supportsStatus)
        guard !countable.isEmpty else { return 0 }
        let done = countable.filter { $0.status == .completed }.count
        return Double(done) / Double(countable.count)
    }

    private var progressSummary: String {
        let countable = work.filter(\.kind.supportsStatus)
        guard !countable.isEmpty else { return "No work to track yet" }
        let done = countable.filter { $0.status == .completed }.count
        return "\(done) of \(countable.count) done"
    }

    // MARK: - Loading

    private func reload() {
        guard let services else { return }
        do {
            guard let found = try services.items.item(id: projectID) else {
                project = nil
                return
            }
            project = found
            stages = services.projectWorkspace.stages(in: found)

            let children = try services.items.items(matching: ItemQuery.children(of: projectID))
            work = children.filter { $0.kind != .note }
            notes = children.filter { $0.kind == .note }
            loadError = nil
        } catch {
            loadError = error.summary
        }
    }

    private func toggleCompletion(of item: Item) {
        guard let services else { return }
        services.perform {
            try services.items.toggleCompletion(item)
            services.noteChange(to: item)
        }
        reload()
    }
}
