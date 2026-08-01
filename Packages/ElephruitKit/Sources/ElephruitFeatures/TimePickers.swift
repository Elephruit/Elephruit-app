import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// One chip in the tracker's filing row.
///
/// A shared label rather than five hand-built ones, because the row's whole job is to be read at a
/// glance as a *set*: five chips drawn at five weights is a row you have to parse rather than scan.
///
/// ### Why an empty chip is still labelled
/// Because the first version was not, and a row of five small grey glyphs is not a set of things you
/// can attach — it is five dots. Nobody clicks a dot to find out what it is. A filled chip shows its
/// value, because by then the word is redundant and the value is the thing being read.
struct TimeChipLabel: View {
    let symbolName: String

    /// The value, shown only once there is one.
    var title: String?

    var isFilled: Bool

    /// The subject's own colour, when it has one — a project's tint, carried through from the
    /// library so the same work is the same colour everywhere it appears.
    var tint: Color?

    /// How much room the text may take before it truncates. Bounded so that one long project name
    /// cannot push the clock off the row.
    var maximumWidth: CGFloat = 150

    var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            if isFilled, let tint {
                // A dot rather than a tinted glyph: the colour identifies the *project*, and putting
                // it on the icon would make the icon mean two things at once.
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
            } else {
                Image(systemName: symbolName)
                    .font(Theme.Text.rowSubtitle)
            }

            if isFilled, let title, !title.isEmpty {
                Text(title)
                    .font(Theme.Text.rowSubtitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: maximumWidth, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(minWidth: 26, minHeight: 26)
        .padding(.horizontal, isFilled ? Theme.Spacing.small : 0)
        .foregroundStyle(isFilled ? (tint ?? Theme.Colors.selection) : Theme.Colors.secondaryText)
        .background {
            // Only a chosen value earns a background. An empty one is a plain glyph in a toolbar of
            // glyphs, which is what it is — five filled capsules saying nothing was five things
            // shouting for attention before any of them had anything to say.
            if isFilled {
                Capsule().fill((tint ?? Theme.Colors.selection).opacity(0.12))
            }
        }
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
                symbolName: "doc.text",
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
    @State private var projects: [ProjectChoice] = []
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        Button {
            loadProjects()
            isPresented = true
        } label: {
            TimeChipLabel(
                symbolName: "folder",
                title: project?.title,
                isFilled: project != nil,
                tint: chosenTint
            )
        }
        .buttonStyle(.plain)
        .help(project.map { "Billed to “\($0.title)”" } ?? "Bill this time to a project")
        .accessibilityLabel("Project")
        .accessibilityValue(project?.title ?? "derived from the subject")
        .accessibilityIdentifier(AccessibilityID.Time.projectPicker)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
    }

    /// Search at the top, the list in the middle, the way out at the bottom.
    ///
    /// The shape every picker in this module now shares. A list you have to leave in order to make
    /// the thing you were looking for is a list that sends you round the houses; a *Create* pinned
    /// to the bottom is always in the same place whether the list is empty or fifty long.
    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search projects and areas…", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .padding(Theme.Spacing.small)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ProjectChoiceRow(
                        title: "No project",
                        detail: "Use whatever the subject belongs to",
                        tint: nil,
                        isChosen: project == nil
                    ) {
                        onPick(nil)
                        isPresented = false
                    }

                    ForEach(groups, id: \.name) { group in
                        if !group.name.isEmpty {
                            Text(group.name.uppercased())
                                .font(Theme.Text.sectionHeader)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                                .kerning(0.4)
                                .padding(.horizontal, Theme.Spacing.small)
                                .padding(.top, Theme.Spacing.small)
                        }

                        ForEach(group.projects) { candidate in
                            ProjectChoiceRow(
                                title: candidate.title,
                                detail: nil,
                                tint: candidate.tint,
                                isChosen: project?.id == candidate.id
                            ) {
                                onPick(SubjectReference(id: candidate.id, title: candidate.title))
                                isPresented = false
                            }
                        }
                    }

                    if groups.isEmpty, !query.isEmpty {
                        Text("Nothing matches.")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .padding(Theme.Spacing.small)
                    }
                }
                .padding(.vertical, Theme.Spacing.tight)
            }
            .frame(maxHeight: 260)

            Divider()

            Text("Time against a task already counts towards that task's project. This is for the hour that belongs to one it does not sit inside.")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Theme.Spacing.small)
        }
        .frame(width: 300)
        .onAppear { isSearchFocused = true }
    }

    private var chosenTint: Color? {
        projects.first { $0.id == project?.id }?.tint
    }

    private var groups: [(name: String, projects: [ProjectChoice])] {
        let matching = query.isEmpty
            ? projects
            : projects.filter { $0.title.localizedCaseInsensitiveContains(query)
                || $0.areaName.localizedCaseInsensitiveContains(query) }

        return Dictionary(grouping: matching, by: \.areaName)
            .sorted { $0.key < $1.key }
            .map { (name: $0.key, projects: $0.value.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }) }
    }

    /// Every live project, with its area and its colour.
    ///
    /// Grouped by area because that is how somebody holds their own projects in their head — the
    /// same reason the design spec groups its project picker by client. A flat alphabetical list of thirty is
    /// a list you read; twelve under three headings is one you point at.
    private func loadProjects() {
        guard let services else { return }
        let found = (try? services.items.items(matching: .kind(.project))) ?? []
        projects = found
            .filter { $0.status != .cancelled }
            .map { item in
                ProjectChoice(
                    id: item.id,
                    title: item.displayTitle,
                    areaName: item.parent?.displayTitle ?? "",
                    tint: Theme.Palette.color(named: item.colorName)
                )
            }
    }
}

/// A project as the picker sees it.
struct ProjectChoice: Identifiable, Hashable {
    let id: UUID
    let title: String
    let areaName: String
    let tint: Color
}

/// One row of the project picker.
private struct ProjectChoiceRow: View {
    let title: String
    var detail: String?
    let tint: Color?
    let isChosen: Bool
    let onPick: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: Theme.Spacing.small) {
                Circle()
                    .fill(tint ?? Theme.Colors.tertiaryText)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(Theme.Text.rowSubtitle)
                        .lineLimit(1)

                    if let detail {
                        Text(detail)
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: Theme.Spacing.small)

                if isChosen {
                    Image(systemName: "checkmark")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.selection)
                }
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.tight)
            .contentShape(.rect)
            .background {
                if isHovering {
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill(Theme.Colors.hoverFill)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.Colors.primaryText)
        .onHover { isHovering = $0 }
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
                symbolName: "person.2",
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
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        Button {
            available = (try? services?.tags.allTags().map(\.slug)) ?? []
            isPresented = true
        } label: {
            TimeChipLabel(
                symbolName: "tag",
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

    /// The same shape as the project picker: search at the top, list in the middle, create pinned to
    /// the bottom where it is in the same place whether there are no tags or fifty.
    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Add or filter tags…", text: $newTag)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .onSubmit(addTyped)
                .padding(Theme.Spacing.small)

            Divider()

            if matching.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text(available.isEmpty ? "No tags yet." : "Nothing matches.")
                        .font(Theme.Text.rowSubtitle)

                    Text("Type a name and press Return to make one.")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .padding(Theme.Spacing.medium)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(matching, id: \.self) { slug in
                            Toggle(isOn: binding(for: slug)) {
                                Text(slug).font(Theme.Text.rowSubtitle)
                            }
                            .toggleStyle(.checkbox)
                            .padding(.horizontal, Theme.Spacing.small)
                            .padding(.vertical, 1)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.tight)
                }
                .frame(maxHeight: 220)
            }

            Divider()

            Button(action: addTyped) {
                Label(
                    typedSlug.isEmpty ? "Create tag" : "Create “\(typedSlug)”",
                    systemImage: "plus"
                )
                .font(Theme.Text.rowSubtitle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.small)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(typedSlug.isEmpty ? Theme.Colors.tertiaryText : Theme.Colors.selection)
            .disabled(typedSlug.isEmpty)
        }
        .frame(width: 260)
        .onAppear { isSearchFocused = true }
    }

    /// What the field would create, normalised — so the button names the tag that will exist rather
    /// than the text that was typed.
    private var typedSlug: String {
        TextNormalizer.slug(newTag.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var matching: [String] {
        guard !newTag.isEmpty else { return available }
        return available.filter { $0.localizedCaseInsensitiveContains(newTag) }
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
