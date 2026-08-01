import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// One chip in the tracker's filing row.
///
/// A shared label rather than five hand-built ones, because the row's whole job is to be read at a
/// glance as a *set*: five chips drawn at five weights is a row you have to parse rather than scan.
/// Empty chips are an outline and a symbol; filled ones carry the accent and the value.
struct TimeChipLabel: View {
    let symbolName: String

    /// The value, or `nil` when nothing is chosen and the chip is just an invitation.
    var title: String?

    var isFilled: Bool

    /// How much room the text may take before it truncates. Bounded so that one long project name
    /// cannot push the tags off the line.
    var maximumWidth: CGFloat = 130

    var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Image(systemName: symbolName)
                .font(Theme.Text.metadata)

            if let title, !title.isEmpty {
                Text(title)
                    .font(Theme.Text.metadata)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: maximumWidth, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 3)
        .foregroundStyle(isFilled ? Theme.Colors.selection : Theme.Colors.secondaryText)
        .background(
            Capsule().fill(isFilled ? Theme.Colors.selection.opacity(0.12) : Theme.Colors.subtleFill)
        )
        .contentShape(.capsule)
    }
}

// MARK: - Subject

/// What the time is against.
///
/// A popover rather than an always-open field: it sits beside four other chips, and a search field
/// wide enough to be useful would crowd out the description — which is the field that has to be
/// inviting, because it is the one that gets typed into every time.
struct TimeSubjectPicker: View {
    @Environment(\.services) private var services

    let subject: SubjectReference?
    let onPick: (SubjectReference?) -> Void

    /// `nil` on surfaces with nowhere to navigate to, like a row inside a sheet.
    var onOpen: ((UUID) -> Void)?

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            TimeChipLabel(
                symbolName: subject == nil ? "folder.badge.plus" : "folder.fill",
                title: subject?.title,
                isFilled: subject != nil
            )
        }
        .buttonStyle(.plain)
        .help(subject.map { "Against “\($0.title)”" } ?? "Choose what this time is against")
        .accessibilityLabel("Subject")
        .accessibilityValue(subject?.title ?? "none")
        .accessibilityIdentifier(AccessibilityID.Time.subjectPicker)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ItemSearchPopover(
                prompt: "Search tasks, projects, notes…",
                emptyHint: "Type two letters to search.",
                current: subject,
                clearTitle: subject.map { "Clear “\($0.title)”" },
                openTitle: onOpen == nil ? nil : subject.map { "Open “\($0.title)”" },
                onOpen: { id in
                    onOpen?(id)
                    isPresented = false
                },
                onPick: { picked in
                    onPick(picked)
                    isPresented = false
                }
            )
        }
    }
}

// MARK: - Project

/// The project the time is billed to.
///
/// Separate from the subject, and usually left alone. Time against a task already rolls up to that
/// task's project; this is for the hour on a note, a meeting, or nothing at all that nonetheless
/// belongs to one — and it is the only way to say so without inventing a task to hang it on.
struct TimeProjectPicker: View {
    @Environment(\.services) private var services

    let project: SubjectReference?
    let onPick: (SubjectReference?) -> Void

    @State private var isPresented = false
    @State private var projects: [SubjectReference] = []

    var body: some View {
        Button {
            loadProjects()
            isPresented = true
        } label: {
            TimeChipLabel(
                symbolName: project == nil ? "square.stack.3d.up" : "square.stack.3d.up.fill",
                title: project?.title,
                isFilled: project != nil
            )
        }
        .buttonStyle(.plain)
        .help(project.map { "Billed to “\($0.title)”" } ?? "Bill this time to a project")
        .accessibilityLabel("Project")
        .accessibilityValue(project?.title ?? "derived from the subject")
        .accessibilityIdentifier(AccessibilityID.Time.projectPicker)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("Bill to a project")
                    .font(Theme.Text.sectionHeader)
                    .foregroundStyle(Theme.Colors.secondaryText)

                if project != nil {
                    Button("Use the subject's own project", systemImage: "arrow.uturn.backward") {
                        onPick(nil)
                        isPresented = false
                    }
                    .buttonStyle(.link)
                    .font(Theme.Text.metadata)
                }

                if projects.isEmpty {
                    Text("No projects yet.")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                            ForEach(projects) { candidate in
                                Button(candidate.title) {
                                    onPick(candidate)
                                    isPresented = false
                                }
                                .buttonStyle(.link)
                                .font(Theme.Text.rowSubtitle)
                                .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }

                Text("Left alone, time against a task is billed to that task's own project.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Spacing.medium)
            .frame(width: 260)
        }
    }

    /// Every open project, by name.
    ///
    /// A list rather than a search field, unlike the subject picker, because the number of live
    /// projects is small enough to read and choosing from a list is faster than remembering enough
    /// of a name to type it.
    private func loadProjects() {
        guard let services else { return }
        let found = (try? services.items.items(matching: .kind(.project))) ?? []
        projects = found
            .filter { $0.status != .cancelled }
            .map { SubjectReference(id: $0.id, title: $0.displayTitle) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

// MARK: - People

/// Who was there.
///
/// Several rather than one, because the question this answers — *how much of my week went on other
/// people* — is asked of meetings and pairing sessions, which rarely have exactly one other person
/// in them.
struct TimePeoplePicker: View {
    @Environment(\.services) private var services

    let people: [SubjectReference]
    let onChange: ([SubjectReference]) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            TimeChipLabel(
                symbolName: people.isEmpty ? "person.badge.plus" : "person.2.fill",
                title: summary,
                isFilled: !people.isEmpty
            )
        }
        .buttonStyle(.plain)
        .help(people.isEmpty ? "Say who you were with" : "With \(people.map(\.title).joined(separator: ", "))")
        .accessibilityLabel("People")
        .accessibilityValue(people.isEmpty ? "none" : people.map(\.title).joined(separator: ", "))
        .accessibilityIdentifier(AccessibilityID.Time.peoplePicker)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                if !people.isEmpty {
                    ElephruitDesign.FlowLayout(spacing: Theme.Spacing.tight, lineSpacing: Theme.Spacing.tight) {
                        ForEach(people) { person in
                            Button {
                                onChange(people.filter { $0.id != person.id })
                            } label: {
                                HStack(spacing: Theme.Spacing.hairline) {
                                    Text(person.title)
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .font(Theme.Text.metadata)
                                .padding(.horizontal, Theme.Spacing.small)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Theme.Colors.subtleFill))
                            }
                            .buttonStyle(.plain)
                            .help("Remove \(person.title)")
                        }
                    }
                }

                ItemSearchPopover(
                    prompt: "Search people…",
                    emptyHint: "Type two letters to find somebody.",
                    current: nil,
                    clearTitle: nil,
                    openTitle: nil,
                    onOpen: { _ in },
                    onPick: { picked in
                        guard let picked, !people.contains(where: { $0.id == picked.id }) else { return }
                        onChange(people + [picked])
                    },
                    // Only people. The field would otherwise offer every note whose title happens to
                    // start with the same two letters, and the repository would silently drop the
                    // one you picked — which reads as the app ignoring you.
                    kind: .person,
                    // Stays open, because adding three people to a meeting is one visit rather than
                    // three, and reopening the popover per person is the friction that stops anybody
                    // recording the second one.
                    dismissesOnPick: false
                )

                Text("Nothing about who you were with is ever written to a calendar.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Spacing.medium)
            .frame(width: 280)
        }
    }

    /// One name, or a count. Two names rarely fit and never help.
    private var summary: String? {
        switch people.count {
        case 0: nil
        case 1: people[0].title
        default: "\(people.count) people"
        }
    }
}

// MARK: - Tags

/// The tags on an entry.
///
/// A checklist of what exists plus a field that creates. Both halves earn their place: the checklist
/// is what stops a library growing `admin`, `Admin` and `adminstration`, and the field is what stops
/// the checklist being a wall you have to leave to get past.
struct TimeTagPicker: View {
    @Environment(\.services) private var services

    let slugs: [String]
    let onChange: ([String]) -> Void

    @State private var isPresented = false
    @State private var newTag = ""
    @State private var available: [String] = []

    var body: some View {
        Button {
            available = (try? services?.tags.allTags().map(\.slug)) ?? []
            isPresented = true
        } label: {
            TimeChipLabel(
                symbolName: slugs.isEmpty ? "tag" : "tag.fill",
                title: summary,
                isFilled: !slugs.isEmpty
            )
        }
        .buttonStyle(.plain)
        .help(slugs.isEmpty ? "Add tags" : "Tagged \(slugs.joined(separator: ", "))")
        .accessibilityLabel("Tags")
        .accessibilityValue(slugs.isEmpty ? "none" : slugs.joined(separator: ", "))
        .accessibilityIdentifier(AccessibilityID.Time.tagPicker)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
    }

    private var summary: String? {
        switch slugs.count {
        case 0: nil
        case 1: slugs[0]
        default: "\(slugs.count) tags"
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.tight) {
                TextField("New tag", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTyped)

                Button("Add", action: addTyped)
                    .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if available.isEmpty {
                Text("No tags yet.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(available, id: \.self) { slug in
                            Toggle(isOn: binding(for: slug)) {
                                Text(slug).font(Theme.Text.rowSubtitle)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(width: 240)
    }

    private func binding(for slug: String) -> Binding<Bool> {
        Binding(
            get: { slugs.contains(slug) },
            set: { isOn in
                onChange(isOn ? (slugs + [slug]).sorted() : slugs.filter { $0 != slug })
            }
        )
    }

    private func addTyped() {
        let name = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        // Normalised here rather than trusted from the field, so the checklist this reopens onto
        // shows the tag that was actually created rather than the text that was typed.
        let slug = TextNormalizer.slug(name)
        guard !slug.isEmpty, !slugs.contains(slug) else {
            newTag = ""
            return
        }

        onChange((slugs + [slug]).sorted())
        if !available.contains(slug) { available.append(slug) }
        newTag = ""
    }
}

// MARK: - Shared search

/// The search half of a picker: a field, some suggestions, and the two things you can do with what
/// is already chosen.
///
/// Shared because the subject picker and the people picker differ in exactly two ways — what kinds
/// they will accept, and whether picking closes them — and two nearly-identical popovers is two
/// places for the search to be debounced differently.
private struct ItemSearchPopover: View {
    @Environment(\.services) private var services

    let prompt: String
    let emptyHint: String
    let current: SubjectReference?
    let clearTitle: String?
    let openTitle: String?
    let onOpen: (UUID) -> Void
    let onPick: (SubjectReference?) -> Void

    /// Restricts results to one kind. `nil` accepts anything.
    var kind: ItemKind?

    var dismissesOnPick = true

    @State private var query = ""
    @State private var suggestions: [SubjectReference] = []
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            TextField(prompt, text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .onChange(of: query) { _, text in updateSuggestions(for: text) }

            if let clearTitle {
                Button(clearTitle, systemImage: "xmark.circle") { onPick(nil) }
                    .buttonStyle(.link)
                    .font(Theme.Text.metadata)
            }

            if let openTitle, let current {
                Button(openTitle, systemImage: "arrow.forward.square") { onOpen(current.id) }
                    .buttonStyle(.link)
                    .font(Theme.Text.metadata)
            }

            if suggestions.isEmpty {
                Text(query.count < 2 ? emptyHint : "Nothing matches.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    ForEach(suggestions) { suggestion in
                        Button(suggestion.title) {
                            onPick(suggestion)
                            if dismissesOnPick {
                                query = ""
                                suggestions = []
                            }
                        }
                        .buttonStyle(.link)
                        .font(Theme.Text.rowSubtitle)
                        .lineLimit(1)
                    }
                }
            }
        }
        .frame(width: dismissesOnPick ? 280 : nil)
        .padding(dismissesOnPick ? Theme.Spacing.medium : 0)
        .onAppear { isSearchFocused = true }
    }

    private func updateSuggestions(for text: String) {
        guard let services, text.count >= 2 else {
            suggestions = []
            return
        }
        Task {
            let found = await services.search.titleSuggestions(prefix: text, limit: 8)
            guard query == text else { return }

            // Filtered here rather than in the query, because `titleSuggestions` is the index's own
            // fast path and narrowing it by kind would mean a second index. Eight results is a small
            // enough haystack to sieve in memory.
            let allowed = found.compactMap { suggestion -> SubjectReference? in
                if let kind {
                    guard let item = (try? services.items.item(id: suggestion.id)) ?? nil,
                          item.kind == kind
                    else { return nil }
                }
                return SubjectReference(id: suggestion.id, title: suggestion.title)
            }
            suggestions = Array(allowed.prefix(6))
        }
    }
}
