import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// What an inline edit changes.
///
/// Split in two on purpose. The **composition** — what the work was, what it was against, its tags,
/// whether it is billable — is shared by every stretch in a group and can be edited for all of them
/// at once. The **span** belongs to one stretch and cannot: eight goes at the same task have eight
/// different pairs of clock times, and there is no sensible thing for "start at 9:04" to mean when
/// applied to all of them.
///
/// So `span` is `nil` when a group of several is being edited, and the editor hides those fields
/// rather than showing controls that would quietly do the wrong thing.
struct TimeEntryEdit {
    var composition: TimeEntryComposition
    var span: TimeEntrySpan?
}

/// Where one stretch sits on the clock.
struct TimeEntrySpan: Equatable {
    var startedAt: Date

    /// `nil` while running, in which case the start is what a typed duration moves.
    var endedAt: Date?
}

// MARK: - Day header

/// The header over one day of the log, and what that day came to.
///
/// The total belongs here rather than only in the summary above, because the question a log answers
/// is asked one day at a time — *did yesterday add up* — and an answer that requires changing the
/// period picker to find is an answer nobody looks for.
struct TimeDayHeader: View {
    let section: TimeDaySection

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(section.title)
                .font(Theme.Text.sectionHeader)

            Text(entryCountDescription)
                .font(Theme.Text.metadata)
                .rowForeground(.tertiary)

            Spacer(minLength: Theme.Spacing.small)

            if section.billable > 0 {
                Text("\(TimeFormatting.short(section.billable)) billable")
                    .font(Theme.Text.metadata)
                    .rowForeground(.tertiary)
            }

            Text(TimeFormatting.short(section.total))
                .font(Theme.Text.sectionHeader)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(section.title), \(TimeFormatting.spelled(section.total)) tracked")
        .accessibilityIdentifier(AccessibilityID.Time.daySection(key: section.dayKey))
    }

    private var entryCountDescription: String {
        section.entryCount == 1 ? "1 entry" : "\(section.entryCount) entries"
    }
}

// MARK: - Group row

/// One row of the log: either a single stretch, or several of the same work collapsed together.
///
/// The count badge is the whole affordance. A row reading `Draft the brief · 8 · 3:41` says both
/// what the day's work on the brief came to *and* that it took eight goes, which is the fact a flat
/// list buries under eight near-identical lines.
struct TimeEntryGroupRow: View {
    @Environment(\.services) private var services

    let group: TimeEntryGroup
    let isExpanded: Bool
    let isEditing: Bool

    let onToggleExpanded: () -> Void
    let onResume: () -> Void
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onCommit: (TimeEntryEdit) -> Void
    let onCancelEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Group {
            if isEditing {
                TimeEntryEditor(
                    composition: composition,
                    // A group of several has no single span to edit — see ``TimeEntryEdit``.
                    span: group.isSingle ? TimeEntrySpan(
                        startedAt: group.lead?.startedAt ?? Date(),
                        endedAt: group.lead?.endedAt
                    ) : nil,
                    entryCount: group.count,
                    onCommit: onCommit,
                    onCancel: onCancelEdit
                )
            } else {
                summary
            }
        }
        .contextMenu {
            Button("Continue", systemImage: "play.circle", action: onResume)
            Button("Edit", systemImage: "pencil", action: onEdit)
            if group.isSingle {
                Button("Duplicate", systemImage: "plus.square.on.square", action: onDuplicate)
            }
            if group.lead?.itemID != nil {
                Button("Open Item", systemImage: "arrow.forward.square", action: onOpen)
            }
            Divider()
            Button(
                group.isSingle ? "Delete" : "Delete All \(group.count)",
                systemImage: "trash",
                role: .destructive,
                action: onDelete
            )
        }
        .accessibilityIdentifier(AccessibilityID.Time.groupRow(id: group.id))
    }

    private var summary: some View {
        HStack(spacing: Theme.Spacing.small) {
            countBadge

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Theme.Spacing.small) {
                    Text(group.displayTitle)
                        .font(Theme.Text.rowTitle)
                        .lineLimit(1)

                    if let lead = group.lead, lead.itemTitle != nil, !lead.entryDescription.isEmpty {
                        Text(lead.entryDescription)
                            .font(Theme.Text.metadata)
                            .rowForeground(.secondary)
                            .lineLimit(1)
                    }
                }

                // ### Why this line is separated rather than spaced
                // It carries up to five unrelated facts — the span, the project, who was there, how
                // the entry was made, how many focus blocks it holds — and five things separated
                // only by a gap read as one run-on phrase. A middle dot is what tells the eye where
                // one fact ends, and it costs nothing when there is only one of them.
                Text(metadataLine)
                    .font(Theme.Text.metadata)
                    .rowForeground(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.small)

            if let slugs = group.lead?.tagSlugs, !slugs.isEmpty {
                TagChipRow(slugs: slugs, limit: 2)
            }

            if group.lead?.isBillable == true {
                Image(systemName: "dollarsign.circle")
                    .rowForeground(.secondary)
                    .accessibilityLabel("Billable")
            }

            Text(TimeFormatting.short(group.total))
                .font(Theme.Text.rowTitle)
                .monospacedDigit()
                // Fixed, so the durations form a column: a list of times that starts at a different
                // x on every row cannot be added up by eye, which is the only reason to read one.
                .frame(width: 52, alignment: .trailing)

            Button(action: onResume) {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.plain)
            .rowForeground(.secondary)
            .help("Continue this")
            .accessibilityLabel("Continue")
        }
        .frame(minHeight: Theme.Size.rowHeightExpanded)
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: onEdit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
    }

    /// The second line: everything true of the row that is not its title.
    private var metadataLine: String {
        var parts = [spanDescription]

        if let project = group.lead?.projectTitle { parts.append(project) }

        if let people = group.lead?.people, !people.isEmpty {
            parts.append(people.count <= 2
                ? "with \(people.map(\.name).joined(separator: " and "))"
                : "with \(people.count) people")
        }

        if let rounds = group.lead?.focusRounds, rounds > 0 {
            parts.append(rounds == 1 ? "1 focus block" : "\(rounds) focus blocks")
        }

        if let source = group.lead?.source, source != .timer, group.isSingle {
            parts.append(source.displayName)
        }

        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The count, or the running dot, or nothing.
    ///
    /// Three states in one fixed-width slot so every row's text starts at the same x — a list whose
    /// titles are indented by whether they happen to be grouped is a list that cannot be scanned
    /// down. Wider than `Theme.Size.rowGlyph`, which sizes a symbol: this has to hold a two-digit
    /// count in a pill without the pill being clipped, and a day with ten goes at one task is
    /// exactly the day this row exists for.
    @ViewBuilder
    private var countBadge: some View {
        let slot: CGFloat = 24

        if group.isRunning {
            Image(systemName: "record.circle")
                .foregroundStyle(Theme.Colors.destructive)
                .frame(width: slot)
                .accessibilityHidden(true)
        } else if group.isSingle {
            Color.clear
                .frame(width: slot, height: 1)
        } else {
            Button(action: onToggleExpanded) {
                Text("\(group.count)")
                    .font(Theme.Text.chip)
                    .monospacedDigit()
                    .padding(.horizontal, Theme.Spacing.tight)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            .fill(Theme.Colors.subtleFill)
                    )
            }
            .buttonStyle(.plain)
            .frame(width: slot)
            .help(isExpanded ? "Collapse these \(group.count) entries" : "Show these \(group.count) entries")
            .accessibilityLabel("\(group.count) entries")
            .accessibilityHint(isExpanded ? "Collapses them" : "Shows them")
        }
    }

    private var spanDescription: String {
        guard let startedAt = group.startedAt else { return "" }
        let start = startedAt.formatted(date: .omitted, time: .shortened)
        guard let endedAt = group.endedAt else { return "\(start) – now" }
        return "\(start) – \(endedAt.formatted(date: .omitted, time: .shortened))"
    }

    private var composition: TimeEntryComposition {
        guard let lead = group.lead else { return TimeEntryComposition() }
        return TimeEntryComposition(lead)
    }

    private var accessibilityDescription: String {
        var parts = [group.displayTitle, TimeFormatting.spelled(group.total), spanDescription]
        if !group.isSingle { parts.append("\(group.count) entries") }
        if group.lead?.isBillable == true { parts.append("billable") }
        if group.isRunning { parts.append("running") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Entry row

/// One stretch inside an expanded group.
///
/// Indented and quieter than the group row, and carrying only what differs between the stretches —
/// when it ran and how long for. Repeating the title, project and tags on every line would be eight
/// copies of the thing the collapse existed to say once.
struct TimeEntryRow: View {
    @Environment(\.services) private var services

    let entry: TimeEntrySnapshot
    let isEditing: Bool

    let onEdit: () -> Void
    let onCommit: (TimeEntryEdit) -> Void
    let onCancelEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Group {
            if isEditing {
                TimeEntryEditor(
                    composition: composition,
                    span: TimeEntrySpan(startedAt: entry.startedAt, endedAt: entry.endedAt),
                    entryCount: 1,
                    onCommit: onCommit,
                    onCancel: onCancelEdit
                )
                .padding(.leading, Theme.Spacing.section)
            } else {
                summary
            }
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil", action: onEdit)
            Button("Duplicate", systemImage: "plus.square.on.square", action: onDuplicate)
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .accessibilityIdentifier(AccessibilityID.Time.entryRow(id: entry.id.uuidString))
    }

    private var summary: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(timeRange)
                .font(Theme.Text.metadata)
                .rowForeground(.secondary)
                .monospacedDigit()

            if entry.source != .timer {
                Text(entry.source.displayName)
                    .font(Theme.Text.metadata)
                    .rowForeground(.tertiary)
            }

            Spacer(minLength: Theme.Spacing.small)

            Text(TimeFormatting.short(entry.duration(at: services?.dateProvider.now ?? Date())))
                .font(Theme.Text.rowSubtitle)
                .monospacedDigit()
                .rowForeground(.secondary)
        }
        .padding(.leading, Theme.Spacing.section)
        .frame(minHeight: Theme.Size.rowHeight)
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: onEdit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(timeRange), \(TimeFormatting.spelled(entry.duration()))")
        .accessibilityAddTraits(.isButton)
    }

    private var timeRange: String {
        let start = entry.startedAt.formatted(date: .omitted, time: .shortened)
        guard let endedAt = entry.endedAt else { return "\(start) – now" }
        return "\(start) – \(endedAt.formatted(date: .omitted, time: .shortened))"
    }

    private var composition: TimeEntryComposition {
        TimeEntryComposition(entry)
    }
}

// MARK: - Editor

/// Correcting an entry, in place.
///
/// In place rather than in a sheet, because correcting time is the most common thing anyone does
/// with it — you stopped the timer twenty minutes late, or forgot to start it — and a sheet for a
/// two-minute correction turns a habit into a chore.
///
/// Every field a row shows is here, which is the change that matters: the old editor offered the
/// description, the two ends and the billable flag, so an entry filed against the wrong project had
/// to be deleted and retyped. The subject and the tags are the two fields most often wrong, because
/// they are the two you skip when starting a timer in a hurry.
struct TimeEntryEditor: View {
    @Environment(\.services) private var services

    let composition: TimeEntryComposition
    let span: TimeEntrySpan?

    /// How many stretches this edit will land on, so a group edit can say so before it happens.
    let entryCount: Int

    let onCommit: (TimeEntryEdit) -> Void
    let onCancel: () -> Void

    @State private var draft = TimeEntryComposition()
    @State private var draftSpan: TimeEntrySpan?
    @State private var durationText = ""
    @FocusState private var isDescriptionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            TextField("Description", text: $draft.description)
                .textFieldStyle(.roundedBorder)
                .focused($isDescriptionFocused)
                .onSubmit(commit)

            ElephruitDesign.FlowLayout(spacing: Theme.Spacing.tight, lineSpacing: Theme.Spacing.tight) {
                TimeSubjectPicker(subject: draft.subject) { draft.subject = $0 }
                TimeProjectPicker(project: draft.project) { draft.project = $0 }
                TimePeoplePicker(people: draft.people) { draft.people = $0 }
                TimeTagPicker(slugs: draft.tagSlugs) { draft.tagSlugs = $0 }
            }

            HStack(spacing: Theme.Spacing.medium) {
                if draftSpan != nil {
                    spanFields
                } else {
                    Text("Editing \(entryCount) entries — their times stay as they are.")
                        .font(Theme.Text.metadata)
                        .rowForeground(.secondary)
                }

                Toggle("Billable", isOn: $draft.isBillable)
                    .toggleStyle(.checkbox)

                Spacer()

                Button("Cancel", action: onCancel)
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

    @ViewBuilder
    private var spanFields: some View {
        DatePicker("From", selection: startBinding, displayedComponents: [.hourAndMinute, .date])
            .datePickerStyle(.compact)
            .labelsHidden()

        if draftSpan?.endedAt != nil {
            Text("to")
                .font(Theme.Text.metadata)
                .rowForeground(.secondary)

            DatePicker("To", selection: endBinding, displayedComponents: [.hourAndMinute, .date])
                .datePickerStyle(.compact)
                .labelsHidden()
        } else {
            Text("still running")
                .font(Theme.Text.metadata)
                .rowForeground(.secondary)
        }

        TextField("0:00:00", text: $durationText)
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .frame(width: 84)
            .onSubmit(commitDuration)
            .help("Type a length — 1:30, 1.5, or 90m")
            .accessibilityLabel("Duration")
            .accessibilityIdentifier(AccessibilityID.Time.durationField)
    }

    /// An end before its start is the one edit that would corrupt every report, so Save refuses it
    /// rather than the repository silently correcting it after the fact.
    private var isValid: Bool {
        guard let span = draftSpan, let endedAt = span.endedAt else { return true }
        return endedAt > span.startedAt
    }

    private var startBinding: Binding<Date> {
        Binding(
            get: { draftSpan?.startedAt ?? Date() },
            set: { newValue in
                draftSpan?.startedAt = newValue
                syncDurationText()
            }
        )
    }

    private var endBinding: Binding<Date> {
        Binding(
            get: { draftSpan?.endedAt ?? draftSpan?.startedAt ?? Date() },
            set: { newValue in
                draftSpan?.endedAt = newValue
                syncDurationText()
            }
        )
    }

    private func loadDraft() {
        draft = composition
        draftSpan = span
        syncDurationText()
        isDescriptionFocused = true
    }

    private func syncDurationText() {
        guard let span = draftSpan else {
            durationText = ""
            return
        }
        let now = services?.dateProvider.now ?? Date()
        durationText = TimeFormatting.clock(max(0, (span.endedAt ?? now).timeIntervalSince(span.startedAt)))
    }

    /// Applies a typed duration by moving whichever end can move.
    ///
    /// A finished entry keeps its start and moves its end — the work began when it began, and the
    /// guess about when it stopped is what is being corrected. A running one has no end to move, so
    /// the start goes back instead, which is the "I started this at two" correction.
    private func commitDuration() {
        guard var span = draftSpan, let parsed = DurationParser.parse(durationText) else {
            // Unreadable input is not applied and not cleared: what was typed stays there to be
            // fixed, because silently reverting a field somebody just typed into reads as loss.
            syncDurationText()
            return
        }

        if span.endedAt != nil {
            span.endedAt = span.startedAt.addingTimeInterval(parsed)
        } else {
            span.startedAt = (services?.dateProvider.now ?? Date()).addingTimeInterval(-parsed)
        }

        draftSpan = span
        syncDurationText()
    }

    private func commit() {
        commitDuration()
        guard isValid else { return }
        onCommit(TimeEntryEdit(composition: draft, span: draftSpan))
    }
}
