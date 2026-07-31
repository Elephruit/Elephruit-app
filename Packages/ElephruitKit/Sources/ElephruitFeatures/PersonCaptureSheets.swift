import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

enum PersonNoteCategory: String, CaseIterable, Sendable, Hashable {
    case general
    case personal
    case work
    case idea

    var displayName: String { rawValue.capitalized }

    var symbolName: String {
        switch self {
        case .general: "note.text"
        case .personal: "heart.fill"
        case .work: "briefcase.fill"
        case .idea: "lightbulb.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .blue
        case .personal: Theme.Colors.personalDetail
        case .work: Theme.Colors.workDetail
        case .idea: .orange
        }
    }

    /// General needs no tag; the other choices become useful everywhere search and filters read tags.
    var tagSlug: String? { self == .general ? nil : rawValue }
}

struct PersonNoteDraft: Sendable, Equatable {
    var category: PersonNoteCategory = .general
    var title = ""
    var body = ""

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func resolvedTitle(personName: String) -> String {
        let explicit = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }

        let firstLine = body.split(whereSeparator: \.isNewline).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !firstLine.isEmpty { return String(firstLine.prefix(80)) }
        return "Note about \(personName)"
    }

    var cleanedBody: String { body.trimmingCharacters(in: .whitespacesAndNewlines) }
    var tagSlugs: [String] { category.tagSlug.map { [$0] } ?? [] }
}

struct PersonNoteSheet: View {
    let personName: String
    let onSave: (PersonNoteDraft) -> Void
    let onCancel: () -> Void

    @State private var draft = PersonNoteDraft()
    @FocusState private var focusedField: Field?

    private enum Field { case title, body }

    var body: some View {
        VStack(spacing: 0) {
            captureHeader
            Divider()

            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                categorySelector

                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text("Title")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)

                    TextField("", text: $draft.title)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .font(.system(.title3, weight: .medium))
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, Theme.Spacing.medium)
                        .frame(height: 42)
                        .background(fieldBackground)
                        .focused($focusedField, equals: .title)
                        .accessibilityLabel("Note title")
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text("Note")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)

                    TextEditor(text: $draft.body)
                        .font(Theme.Text.editorBody)
                        .scrollContentBackground(.hidden)
                        .padding(Theme.Spacing.small)
                        .frame(minHeight: 190)
                        .background(fieldBackground)
                        .overlay(alignment: .topLeading) {
                            if draft.body.isEmpty {
                                Text("What do you want to remember?")
                                    .font(Theme.Text.editorBody)
                                    .foregroundStyle(Theme.Colors.placeholderText)
                                    .padding(.horizontal, Theme.Spacing.large)
                                    .padding(.vertical, Theme.Spacing.medium)
                                    .allowsHitTesting(false)
                            }
                        }
                        .focused($focusedField, equals: .body)
                        .accessibilityLabel("Note")
                }
            }
            .padding(Theme.Spacing.section)

            Divider()
            actionBar
        }
        .frame(width: 620)
        .background(Theme.Colors.windowBackground)
        .onAppear { focusedField = .title }
    }

    private var captureHeader: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(draft.category.tint)
                .frame(width: 44, height: 44)
                .background(draft.category.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text("Add a note")
                    .font(Theme.Text.title)
                Text("About \(personName)")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.vertical, Theme.Spacing.large)
    }

    private var categorySelector: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Type")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)

            HStack(spacing: Theme.Spacing.small) {
                ForEach(PersonNoteCategory.allCases, id: \.self) { category in
                    Button {
                        withAnimation(Theme.Motion.appearance) { draft.category = category }
                    } label: {
                        Label(category.displayName, systemImage: category.symbolName)
                            .font(Theme.Text.chip)
                            .padding(.horizontal, Theme.Spacing.medium)
                            .frame(height: 30)
                            .foregroundStyle(draft.category == category ? category.tint : Theme.Colors.secondaryText)
                            .background(
                                Capsule().fill(
                                    draft.category == category ? category.tint.opacity(0.14) : Theme.Colors.subtleFill
                                )
                            )
                            .overlay {
                                Capsule().strokeBorder(
                                    draft.category == category ? category.tint.opacity(0.45) : Color.clear
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(draft.category == category ? .isSelected : [])
                }
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Label("Saved to \(personName)'s history", systemImage: "person.crop.circle.badge.checkmark")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)

            Spacer()

            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)

            Button("Save Note") { onSave(draft) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(draft.isEmpty)
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.vertical, Theme.Spacing.medium)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            .fill(Theme.Colors.contentBackground)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(Theme.Colors.separator)
            }
    }
}

struct PersonInteractionDraft: Sendable, Equatable {
    var kind: PersonInteractionKind = .inPerson
    var participantIDs: Set<UUID> = []
    var summary = ""
    var discussion = ""
    var followUps = ""
    var commitments = ""
    var occurredAt = Date()

    var cleanedSummary: String { summary.trimmingCharacters(in: .whitespacesAndNewlines) }
    var cleanedDiscussion: String { discussion.trimmingCharacters(in: .whitespacesAndNewlines) }
    var followUpItems: [String] { Self.items(in: followUps) }
    var commitmentItems: [String] { Self.items(in: commitments) }
    var isValid: Bool { !cleanedSummary.isEmpty }

    private static func items(in text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

struct LogInteractionSheet: View {
    let person: Item
    let onSave: (PersonInteractionDraft) -> Void
    let onCancel: () -> Void

    @Environment(\.services) private var services
    @State private var draft: PersonInteractionDraft
    @State private var availablePeople: [Item]
    @State private var isChoosingPeople = false
    @State private var peopleSearch = ""
    @FocusState private var focusedField: Field?

    private enum Field { case summary, discussion, followUps, commitments }

    init(
        person: Item,
        onSave: @escaping (PersonInteractionDraft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.person = person
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: PersonInteractionDraft(participantIDs: [person.id]))
        _availablePeople = State(initialValue: [person])
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                    kindSelector
                    attendeeSelector
                    summaryAndDate
                    discussionField

                    actionList(
                        title: "Tasks",
                        detail: "Next steps from this interaction",
                        symbol: "checkmark.circle.fill",
                        tint: .blue,
                        text: $draft.followUps,
                        field: .followUps,
                        prompt: "One task per line"
                    )
                }
                .padding(Theme.Spacing.section)
            }

            Divider()
            footer
        }
        .frame(width: 700)
        .frame(minHeight: 620)
        .background(Theme.Colors.windowBackground)
        .onAppear {
            draft.occurredAt = services?.dateProvider.now ?? Date()
            loadPeople()
            focusedField = .summary
        }
        .accessibilityIdentifier(AccessibilityID.People.interactionSheet)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: draft.kind.symbolName)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.purple)
                .frame(width: 44, height: 44)
                .background(Color.purple.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text("Log an interaction")
                    .font(Theme.Text.title)
                Text(attendeeSummary)
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.vertical, Theme.Spacing.large)
    }

    private var kindSelector: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("How did you connect?")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)

            HStack(spacing: Theme.Spacing.small) {
                ForEach(PersonInteractionKind.allCases, id: \.self) { kind in
                    Button {
                        withAnimation(Theme.Motion.appearance) { draft.kind = kind }
                    } label: {
                        Label(kind.displayName, systemImage: kind.symbolName)
                            .font(Theme.Text.chip)
                            .padding(.horizontal, Theme.Spacing.small)
                            .frame(height: 30)
                            .foregroundStyle(draft.kind == kind ? Color.purple : Theme.Colors.secondaryText)
                            .background(
                                Capsule().fill(
                                    draft.kind == kind ? Color.purple.opacity(0.14) : Theme.Colors.subtleFill
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(draft.kind == kind ? .isSelected : [])
                }
            }
        }
    }

    private var attendeeSelector: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                Text("Who was there?")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                Spacer()
                Text("\(draft.participantIDs.count) \(draft.participantIDs.count == 1 ? "person" : "people")")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.small) {
                    ForEach(selectedAttendees) { attendee in
                        HStack(spacing: 6) {
                            PersonAvatar(name: attendee.displayTitle, colorName: attendee.colorName, size: 22)
                            Text(attendee.displayTitle)
                                .font(Theme.Text.chip)
                            if attendee.id != person.id {
                                Button {
                                    draft.participantIDs.remove(attendee.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(Theme.Colors.tertiaryText)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(attendee.displayTitle)")
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 32)
                        .background(Color.purple.opacity(0.1), in: Capsule())
                    }

                    Button {
                        isChoosingPeople = true
                    } label: {
                        Label("Add people", systemImage: "person.badge.plus")
                            .font(Theme.Text.chip)
                            .padding(.horizontal, Theme.Spacing.small)
                            .frame(height: 32)
                            .background(Theme.Colors.subtleFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $isChoosingPeople, arrowEdge: .bottom) {
                        peoplePicker
                    }
                }
            }
        }
    }

    private var peoplePicker: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.Colors.secondaryText)
                TextField("Search people", text: $peopleSearch)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .frame(height: 38)
            .background(Theme.Colors.subtleFill, in: RoundedRectangle(cornerRadius: 10))
            .padding(Theme.Spacing.medium)

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredPeople) { candidate in
                        Button {
                            toggle(candidate)
                        } label: {
                            HStack(spacing: Theme.Spacing.small) {
                                PersonAvatar(name: candidate.displayTitle, colorName: candidate.colorName, size: 28)
                                Text(candidate.displayTitle)
                                    .foregroundStyle(Theme.Colors.primaryText)
                                    .lineLimit(1)
                                Spacer()
                                if draft.participantIDs.contains(candidate.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.purple)
                                }
                            }
                            .padding(.horizontal, Theme.Spacing.medium)
                            .frame(height: 40)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(candidate.id == person.id)
                    }
                }
                .padding(.vertical, Theme.Spacing.small)
            }

            Divider()
            HStack {
                Text("Select everyone who took part")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Spacer()
                Button("Done") { isChoosingPeople = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Spacing.medium)
        }
        .frame(width: 330, height: 390)
        .background(Theme.Colors.windowBackground)
    }

    private var summaryAndDate: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text("What was it about?")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)

                TextField("", text: $draft.summary)
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.system(.title3, weight: .medium))
                    .padding(.horizontal, Theme.Spacing.medium)
                    .frame(height: 42)
                    .background(captureFieldBackground)
                    .focused($focusedField, equals: .summary)
                    .accessibilityLabel("Interaction summary")
            }

            HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.purple)
                    .frame(width: 34, height: 34)
                    .background(Color.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 2) {
                    Text("When")
                        .font(.system(.callout, weight: .semibold))
                    Text("Date and time of the interaction")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }

                Spacer()

                DatePicker("Date", selection: $draft.occurredAt, displayedComponents: .date)
                    .datePickerStyle(.compact)
                DatePicker("Time", selection: $draft.occurredAt, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.compact)
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .frame(height: 58)
            .background(Color.purple.opacity(0.055), in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .strokeBorder(Color.purple.opacity(0.16))
            }
        }
    }

    private var discussionField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text("What did you discuss?")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)

            captureTextEditor(
                text: $draft.discussion,
                field: .discussion,
                prompt: "Key points, context, decisions, or anything worth remembering…",
                minHeight: 130
            )
        }
    }

    private func actionList(
        title: String,
        detail: String,
        symbol: String,
        tint: Color,
        text: Binding<String>,
        field: Field,
        prompt: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(.callout, weight: .semibold))
                    Text(detail)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }

            captureTextEditor(text: text, field: field, prompt: prompt, minHeight: 90)
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.large))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.large)
                .strokeBorder(tint.opacity(0.18))
        }
    }

    private func captureTextEditor(
        text: Binding<String>,
        field: Field,
        prompt: String,
        minHeight: CGFloat
    ) -> some View {
        TextEditor(text: text)
            .font(Theme.Text.editorBody)
            .scrollContentBackground(.hidden)
            .padding(Theme.Spacing.small)
            .frame(minHeight: minHeight)
            .background(captureFieldBackground)
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(prompt)
                        .font(Theme.Text.editorBody)
                        .foregroundStyle(Theme.Colors.placeholderText)
                        .padding(.horizontal, Theme.Spacing.large)
                        .padding(.vertical, Theme.Spacing.medium)
                        .allowsHitTesting(false)
                }
            }
            .focused($focusedField, equals: field)
    }

    private var footer: some View {
        HStack {
            Text("The interaction and its tasks are linked to every attendee.")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)

            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Log Interaction") { onSave(draft) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.isValid)
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.vertical, Theme.Spacing.medium)
    }

    private var selectedAttendees: [Item] {
        availablePeople.filter { draft.participantIDs.contains($0.id) }
    }

    private var filteredPeople: [Item] {
        let query = peopleSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return availablePeople }
        return availablePeople.filter { $0.displayTitle.localizedCaseInsensitiveContains(query) }
    }

    private var attendeeSummary: String {
        let additional = max(0, draft.participantIDs.count - 1)
        return additional == 0
            ? "With \(person.displayTitle)"
            : "With \(person.displayTitle) and \(additional) \(additional == 1 ? "other" : "others")"
    }

    private func toggle(_ candidate: Item) {
        guard candidate.id != person.id else { return }
        if draft.participantIDs.contains(candidate.id) {
            draft.participantIDs.remove(candidate.id)
        } else {
            draft.participantIDs.insert(candidate.id)
        }
    }

    private func loadPeople() {
        guard let services else { return }
        let people = (try? services.persons.allPeople(includingPlaceholders: false)) ?? []
        availablePeople = people.contains(where: { $0.id == person.id }) ? people : [person] + people
    }

    private var captureFieldBackground: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            .fill(Theme.Colors.contentBackground)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(Theme.Colors.separator)
            }
    }
}
