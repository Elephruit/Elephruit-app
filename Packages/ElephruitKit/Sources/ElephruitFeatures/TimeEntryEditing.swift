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

// MARK: - Live durations

/// A duration that keeps moving while something under it is still running.
///
/// ### Why the log needs this at all
/// Because it did not have it, and the result was a card reading `0:25` directly above a row
/// reading `0:00` for the same stretch of work. The log is rebuilt from a snapshot taken when the
/// view last reloaded, which is right for ninety-nine rows out of a hundred and wrong for the one
/// that has not finished yet.
///
/// `since` is the moment the running stretch began, and `nil` for everything settled — which is
/// almost every row, and those pay nothing: no timeline, no redraw, just the number they were
/// given. Only a day that contains a running entry costs a redraw a second, and only for as long
/// as it does.
struct LiveDuration: View {
    /// What the duration is when nothing is running: the settled total.
    let base: TimeInterval

    /// When the still-running stretch started, or `nil` if none is.
    let since: Date?

    let font: Font

    /// Whether to count in seconds rather than in hours and minutes.
    ///
    /// ### Why this is not simply "is it running"
    /// Because it depends on what the number is *of*. A single stretch that is still going is the
    /// same stretch the tracker is showing at the top of the screen, and the two must agree — the
    /// version that did not was genuinely alarming to read: a card saying `0:56` above a row saying
    /// `0:01` looks like the log has lost fifty-five seconds, when in fact one was counting seconds
    /// and the other minutes. A *day's* total is a different quantity that nobody reads to the
    /// second, and `4:25:13` in a section header is noise pretending to be precision.
    var countsSeconds = false

    var body: some View {
        if let since {
            TimelineView(.periodic(from: since, by: 1)) { context in
                text(base + max(0, context.date.timeIntervalSince(since)))
                    .contentTransition(.numericText())
            }
        } else {
            text(base)
        }
    }

    private func text(_ interval: TimeInterval) -> some View {
        Text(countsSeconds ? TimeFormatting.stopwatch(interval) : TimeFormatting.short(interval))
            .font(font)
            .monospacedDigit()
    }
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

            LiveDuration(
                base: section.settledTotal,
                since: section.runningSince,
                font: Theme.Text.sectionHeader
            )
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

    @State private var isHovering = false

    let group: TimeEntryGroup
    let isExpanded: Bool
    let isEditing: Bool

    /// Whether the keyboard is on this row.
    ///
    /// The controls appear on hover *or* here, so the pointer and the keyboard reach the same set of
    /// actions. Hiding them behind hover alone made every correction in this log a mouse-only one.
    var isCurrent: Bool = false

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

            // Fixed width, so the durations form a column: a list of times starting at a different
            // x on every row cannot be added up by eye, which is the only reason to read one.
            LiveDuration(
                base: group.settledTotal,
                since: group.runningSince,
                font: Theme.Text.rowTitle,
                countsSeconds: group.isRunning
            )
            .frame(width: 64, alignment: .trailing)

            // ### Why editing is a visible button and not only a double-click
            // Because a double-click is not an affordance. Every entry in this log can be corrected
            // in place — the subject, the people, the tags, the clock times — and none of that is
            // worth having if the only way to reach it is a gesture nobody is told about. A pencil
            // costs nothing when the pointer is elsewhere and answers the question the moment it
            // arrives. The double-click still works, and so does the context menu.
            //
            // ### And why deleting is here rather than only in the context menu
            // Because a context menu is the one place a right-click-averse user never looks, and
            // "remove this" is not an advanced operation on a log of guesses about yesterday. It is
            // the last control in the cluster, quiet rather than red, and what it does is offered
            // straight back — see `TimeView.delete(_:describing:)`.
            // The cluster fades as one. Three controls appearing separately as the pointer crossed
            // them would be three events where there is one, and the row would visibly reflow.
            HStack(spacing: Theme.Spacing.small) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .rowForeground(.secondary)
                .help("Edit this entry")
                .accessibilityLabel("Edit")
                .accessibilityIdentifier(AccessibilityID.Time.editRowButton)

                Button(action: onResume) {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.plain)
                .rowForeground(.secondary)
                .help("Continue this")
                .accessibilityLabel("Continue")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .rowForeground(.secondary)
                .help(group.isSingle ? "Delete this entry" : "Delete all \(group.count) of these")
                .accessibilityLabel(group.isSingle ? "Delete" : "Delete all \(group.count)")
                .accessibilityIdentifier(AccessibilityID.Time.deleteRowButton)
            }
            // Held in the layout while hidden, so nothing shifts when the pointer arrives, and
            // never hidden from VoiceOver or from the keyboard — an `opacity(0)` control that is
            // still in the focus order is a focus stop nobody can see, which is worse than either
            // showing it or removing it.
            .opacity(isHovering || isCurrent ? 1 : 0)
            .accessibilityHidden(false)
        }
        .frame(minHeight: Theme.Size.rowHeightExpanded)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .calmAnimation(value: isHovering)
        .onTapGesture(count: 2, perform: onEdit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
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

    @State private var isHovering = false

    let entry: TimeEntrySnapshot
    let isEditing: Bool

    /// Whether the keyboard is on this row — see ``TimeEntryGroupRow/isCurrent``.
    var isCurrent: Bool = false

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

            LiveDuration(
                base: entry.isRunning ? 0 : entry.duration(),
                since: entry.isRunning ? entry.startedAt : nil,
                font: Theme.Text.rowSubtitle,
                countsSeconds: entry.isRunning
            )
            .rowForeground(.secondary)
            .frame(width: 64, alignment: .trailing)

            // The same two controls the group row carries, in the same place, so a stretch inside an
            // expanded group is corrected the way the row above it is rather than by remembering
            // that this one needs a right-click.
            HStack(spacing: Theme.Spacing.small) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .rowForeground(.secondary)
                .help("Edit this stretch")
                .accessibilityLabel("Edit")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .rowForeground(.secondary)
                .help("Delete this stretch")
                .accessibilityLabel("Delete")
            }
            .opacity(isHovering || isCurrent ? 1 : 0)
        }
        .padding(.leading, Theme.Spacing.section)
        .frame(minHeight: Theme.Size.rowHeight)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .calmAnimation(value: isHovering)
        .onTapGesture(count: 2, perform: onEdit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(timeRange), \(TimeFormatting.spelled(entry.duration()))")
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
