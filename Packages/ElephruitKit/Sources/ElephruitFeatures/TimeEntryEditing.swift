import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// What an inline edit changes.
struct TimeEntryEdit {
    var description: String
    var startedAt: Date
    var endedAt: Date?
    var isBillable: Bool
}

/// One tracked entry, editable in place.
///
/// In place rather than in a sheet, because correcting time is the most common thing anyone does
/// with it — you stopped the timer twenty minutes late, or forgot to start it. A sheet for a
/// two-minute correction turns a habit into a chore.
struct TimeEntryRow: View {
    let entry: TimeEntrySnapshot
    let isEditing: Bool
    let onResume: () -> Void
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onCommit: (TimeEntryEdit) -> Void
    let onCancelEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.services) private var services

    @State private var draftDescription = ""
    @State private var draftStart = Date()
    @State private var draftEnd = Date()
    @State private var draftBillable = false

    var body: some View {
        Group {
            if isEditing {
                editor
            } else {
                summary
            }
        }
        .contextMenu {
            Button("Continue", systemImage: "play.circle", action: onResume)
            Button("Edit", systemImage: "pencil", action: beginEditing)
            if entry.itemID != nil {
                Button("Open Item", systemImage: "arrow.forward.square", action: onOpen)
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .accessibilityIdentifier(AccessibilityID.Time.entryRow(id: entry.id.uuidString))
    }

    // MARK: Reading

    private var summary: some View {
        HStack(spacing: Theme.Spacing.small) {
            if entry.isRunning {
                Image(systemName: "record.circle")
                    .foregroundStyle(Theme.Colors.destructive)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                HStack(spacing: Theme.Spacing.small) {
                    Text(entry.displayTitle)
                        .font(Theme.Text.rowTitle)
                        .lineLimit(1)

                    if entry.itemTitle != nil, !entry.entryDescription.isEmpty {
                        Text(entry.entryDescription)
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: Theme.Spacing.small) {
                    Text(timeRange)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .monospacedDigit()

                    if let project = entry.projectTitle {
                        Text(project)
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }

                    if entry.source != .timer {
                        Text(entry.source.displayName)
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }
            }

            Spacer(minLength: Theme.Spacing.small)

            if !entry.tagSlugs.isEmpty {
                TagChipRow(slugs: entry.tagSlugs, limit: 2)
            }

            if entry.isBillable {
                Image(systemName: "dollarsign.circle")
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .accessibilityLabel("Billable")
            }

            Text(TimeFormatting.short(entry.duration(at: services?.dateProvider.now ?? Date())))
                .font(Theme.Text.rowTitle)
                .monospacedDigit()

            Button(action: onResume) {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.secondaryText)
            .help("Continue this")
            .accessibilityLabel("Continue")
        }
        .frame(minHeight: Theme.Size.rowHeight)
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: beginEditing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
    }

    private var timeRange: String {
        let start = entry.startedAt.formatted(date: .omitted, time: .shortened)
        guard let endedAt = entry.endedAt else { return "\(start) – now" }
        return "\(start) – \(endedAt.formatted(date: .omitted, time: .shortened))"
    }

    private var accessibilityDescription: String {
        var parts = [entry.displayTitle, TimeFormatting.spelled(entry.duration()), timeRange]
        if entry.isBillable { parts.append("billable") }
        if entry.isRunning { parts.append("running") }
        return parts.joined(separator: ", ")
    }

    // MARK: Editing

    private var editor: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            TextField("Description", text: $draftDescription)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)

            HStack(spacing: Theme.Spacing.medium) {
                DatePicker("From", selection: $draftStart, displayedComponents: [.hourAndMinute, .date])
                    .datePickerStyle(.compact)
                    .labelsHidden()

                if entry.endedAt != nil {
                    Text("to")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)

                    DatePicker("To", selection: $draftEnd, displayedComponents: [.hourAndMinute, .date])
                        .datePickerStyle(.compact)
                        .labelsHidden()
                } else {
                    Text("still running")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }

                Toggle("Billable", isOn: $draftBillable)
                    .toggleStyle(.checkbox)

                Spacer()

                Button("Cancel", action: onCancelEdit)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(.vertical, Theme.Spacing.small)
        .onAppear(perform: loadDraft)
    }

    /// An end before its start is the one edit that would corrupt every report, so Save refuses it
    /// rather than the repository silently correcting it after the fact.
    private var isValid: Bool {
        entry.endedAt == nil || draftEnd > draftStart
    }

    private func beginEditing() {
        loadDraft()
        onEdit()
    }

    private func loadDraft() {
        draftDescription = entry.entryDescription
        draftStart = entry.startedAt
        draftEnd = entry.endedAt ?? entry.startedAt
        draftBillable = entry.isBillable
    }

    private func commit() {
        guard isValid else { return }
        onCommit(TimeEntryEdit(
            description: draftDescription,
            startedAt: draftStart,
            endedAt: entry.endedAt == nil ? nil : draftEnd,
            isBillable: draftBillable
        ))
    }
}

// MARK: - Manual entry

/// Time typed in rather than timed.
struct ManualTimeEntryDraft {
    var description: String
    var startedAt: Date
    var endedAt: Date
    var itemID: UUID?
    var tagSlugs: [String]
    var isBillable: Bool
}

/// Adding time after the fact.
///
/// Necessary rather than a convenience: nobody remembers to start a timer every time, and a tracker
/// that only accepts time it watched happen gets abandoned the first afternoon someone forgets.
struct ManualTimeEntrySheet: View {
    let onSave: (ManualTimeEntryDraft) -> Void
    let onCancel: () -> Void

    @Environment(\.services) private var services

    @State private var description = ""
    @State private var startedAt = Date()
    @State private var endedAt = Date()
    @State private var subject: (id: UUID, title: String)?
    @State private var subjectQuery = ""
    @State private var suggestions: [(id: UUID, title: String)] = []
    @State private var isBillable = false
    @FocusState private var isDescriptionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Add Time")
                .font(Theme.Text.title)

            TextField("What were you doing?", text: $description)
                .textFieldStyle(.roundedBorder)
                .focused($isDescriptionFocused)

            subjectField

            HStack(spacing: Theme.Spacing.medium) {
                DatePicker("From", selection: $startedAt)
                    .datePickerStyle(.compact)
                DatePicker("To", selection: $endedAt)
                    .datePickerStyle(.compact)
            }

            HStack {
                Toggle("Billable", isOn: $isBillable)
                    .toggleStyle(.checkbox)

                Spacer()

                Text(durationDescription)
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(isValid ? Theme.Colors.secondaryText : Theme.Colors.destructive)
                    .monospacedDigit()
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 460)
        .onAppear(perform: prepare)
        .accessibilityIdentifier(AccessibilityID.Time.manualEntrySheet)
    }

    private var subjectField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            if let subject {
                HStack(spacing: Theme.Spacing.small) {
                    Text(subject.title)
                        .font(Theme.Text.rowSubtitle)
                    Button("Change") { self.subject = nil }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            } else {
                TextField("Against what? (optional)", text: $subjectQuery)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: subjectQuery) { _, query in updateSuggestions(for: query) }

                if !suggestions.isEmpty {
                    ForEach(suggestions, id: \.id) { suggestion in
                        Button(suggestion.title) {
                            subject = suggestion
                            subjectQuery = ""
                            suggestions = []
                        }
                        .buttonStyle(.link)
                        .font(Theme.Text.rowSubtitle)
                    }
                }
            }
        }
    }

    private var isValid: Bool { endedAt > startedAt }

    private var durationDescription: String {
        guard isValid else { return "The end has to come after the start" }
        return TimeFormatting.spelled(endedAt.timeIntervalSince(startedAt))
    }

    private func prepare() {
        guard let services else { return }
        // Defaults to the hour just gone, which is nearly always what someone is recording.
        endedAt = services.dateProvider.now
        startedAt = endedAt.addingTimeInterval(-3_600)
        isDescriptionFocused = true
    }

    private func updateSuggestions(for query: String) {
        guard let services, query.count >= 2 else {
            suggestions = []
            return
        }
        Task {
            let found = await services.search.titleSuggestions(prefix: query, limit: 5)
            guard subjectQuery == query else { return }
            suggestions = found
        }
    }

    private func save() {
        guard isValid else { return }
        onSave(ManualTimeEntryDraft(
            description: description,
            startedAt: startedAt,
            endedAt: endedAt,
            itemID: subject?.id,
            tagSlugs: [],
            isBillable: isBillable
        ))
    }
}
