import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

// MARK: - Events

/// One calendar entry in a day.
///
/// ### Distinct by shape, not by colour alone
/// An event is a *fixed* block of time; a task is something you choose when to do. The row says so
/// structurally — a time range on the leading edge where a task has a status circle, and a coloured
/// spine carrying the calendar's own colour — so the difference survives colour-blindness,
/// greyscale, and a glance. The kind of entry it is (a meeting, an appointment, a defended block,
/// leave) is carried by a glyph and by whether there is a guest list, never by the colour alone.
struct TodayEventRow: View {
    @Environment(\.services) private var services

    let event: DayEvent
    let plan: DayPlan
    let model: TodayModel
    let actions: TodayActions

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            timeColumn

            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Theme.Palette.color(named: event.event.calendarColorName))
                .frame(width: 2)
                .opacity(event.event.isCancelled ? 0.4 : 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                titleLine
                contextLine
                if !event.participants.isEmpty { participants }
                preparationLine
            }

            Spacer(minLength: Theme.Spacing.small)

            if isHovering || isFocused { hoverActions }
        }
        .padding(.vertical, Theme.Spacing.tight)
        .opacity(event.event.isCancelled ? 0.55 : 1)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .background {
            if isFocused {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(Theme.Colors.selectionFill)
                    .padding(.horizontal, -Theme.Spacing.small)
            }
        }
        .hoverHighlight(isEnabled: !isFocused, extending: Theme.Spacing.small)
        .focusable()
        // The native macOS focus ring wraps the row's full flexible width, producing a large blue
        // rectangle around a small calendar entry. The quiet fill above still exposes keyboard
        // location without making the event look like an oversized text field.
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.return) {
            // Return joins where there is a call to join and opens the notes otherwise, which is
            // what the pointer does with the two controls the row reveals.
            if actions.joinLink(for: event) != nil {
                actions.join(event)
            } else {
                actions.openNotes(for: event)
            }
            return .handled
        }
        .contextMenu { TodayEventMenu(event: event, model: model, actions: actions) }
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(AccessibilityID.Today.event(event.id))
    }

    // MARK: Time

    @ViewBuilder
    private var timeColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if event.event.occupiesAllDayRow(calendar: calendar) {
                Text("All day")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            } else {
                Text(event.event.startAt.formatted(date: .omitted, time: .shortened))
                    .font(Theme.Text.rowSubtitle)
                    .monospacedDigit()
                    .foregroundStyle(isInProgress ? Theme.Colors.dueToday : Theme.Colors.primaryText)

                Text(event.event.endAt.formatted(date: .omitted, time: .shortened))
                    .font(Theme.Text.metadata)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
        .frame(width: TodayMetrics.timeGutterWidth, alignment: .leading)
    }

    private var isInProgress: Bool {
        guard let now = services?.dateProvider.now, plan.isToday else { return false }
        return event.isInProgress(at: now)
    }

    // MARK: Title

    private var titleLine: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Image(systemName: event.kind.symbolName)
                .font(.system(size: 10))
                .foregroundStyle(Theme.Colors.tertiaryText)
                .accessibilityHidden(true)

            Text(event.event.displayTitle)
                .font(Theme.Text.rowTitle)
                .strikethrough(event.event.isCancelled, color: Theme.Colors.tertiaryText)
                .foregroundStyle(Theme.Colors.primaryText)
                .lineLimit(1)

            if event.event.isRecurring {
                Image(systemName: "repeat")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .accessibilityHidden(true)
            }

            // A clash is a badge with a word behind it in the tooltip, not a red row. The news is
            // that two things want the same hour, not that the meeting is bad.
            if event.hasConflict, !event.event.isCancelled {
                Label("Clash", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Colors.warning)
                    .help(conflictDescription)
            }

            if event.event.isCancelled {
                Text("Canceled")
                    .font(Theme.Text.chip)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var contextLine: some View {
        if let context {
            Text(context)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .lineLimit(1)
        }
    }

    private var context: String? {
        var parts: [String] = []
        if let location = event.event.locationName, !location.isEmpty { parts.append(location) }
        if let calendarName = event.event.calendarName, !calendarName.isEmpty { parts.append(calendarName) }
        if event.kind != .meeting { parts.append(event.kind.displayName) }
        if let until = timeUntil { parts.append(until) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "in 20 minutes", and only while that is a useful thing to say.
    private var timeUntil: String? {
        guard plan.isToday, let now = services?.dateProvider.now else { return nil }
        if event.isInProgress(at: now) { return "happening now" }
        guard let interval = event.timeUntilStart(from: now), interval < 2 * 3600 else { return nil }
        return "in " + DurationPhrase.exact(interval)
    }

    // MARK: People

    private var participants: some View {
        HStack(spacing: -6) {
            ForEach(event.participants.prefix(5)) { participant in
                TodayParticipantChip(participant: participant)
            }

            if event.participants.count > 5 {
                Text("+\(event.participants.count - 5)")
                    .font(Theme.Text.chip)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .padding(.leading, Theme.Spacing.small + 6)
            }
        }
        .padding(.top, 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(participantsLabel)
    }

    private var participantsLabel: String {
        let names = event.participants.prefix(5).map(\.name)
        guard !names.isEmpty else { return "" }
        let extra = event.participants.count - names.count
        let list = ListPhrase.joined(names)
        return extra > 0 ? "With \(list) and \(extra) more" : "With \(list)"
    }

    // MARK: Preparation

    @ViewBuilder
    private var preparationLine: some View {
        if let summary = event.preparation.summary {
            HStack(spacing: Theme.Spacing.tight) {
                Image(systemName: event.preparation.openPreparationTaskIDs.isEmpty
                    ? "checkmark.circle"
                    : "list.bullet.clipboard")
                    .font(.system(size: 9))
                    .accessibilityHidden(true)

                Text(summary)
                    .font(Theme.Text.metadata)
            }
            .foregroundStyle(Theme.Colors.secondaryText)
        }
    }

    // MARK: Hover

    /// The two actions worth a click without opening anything.
    ///
    /// Join, because a meeting starting in four minutes is the one thing on this page with a
    /// deadline measured in seconds, and notes, because that is what somebody reaches for on the way
    /// in. Everything else is one right-click away, which is where actions belong when there are
    /// eight of them.
    private var hoverActions: some View {
        HStack(spacing: Theme.Spacing.tight) {
            if actions.joinLink(for: event) != nil {
                Button { actions.join(event) } label: {
                    Label("Join", systemImage: "video")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Join \(event.event.displayTitle)")
            }

            Button { actions.openNotes(for: event) } label: {
                Image(systemName: "note.text")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.Colors.secondaryText)
            .help("Notes for this meeting")
            .accessibilityLabel("Notes for \(event.event.displayTitle)")
        }
        .transition(.opacity)
    }

    // MARK: Descriptions

    private var calendar: Calendar {
        (services?.dateProvider ?? SystemDateProvider()).calendar
    }

    private var conflictDescription: String {
        let titles = event.conflictingEventIDs.compactMap { id in
            plan.events.first { $0.id == id }?.event.displayTitle
        }
        guard !titles.isEmpty else { return "Overlaps something else" }
        return "Overlaps " + ListPhrase.joined(titles)
    }

    private var tooltip: String {
        var lines = [event.event.displayTitle]
        if let notes = event.event.notes, !notes.isEmpty { lines.append(String(notes.prefix(240))) }
        if event.hasConflict { lines.append(conflictDescription) }
        return lines.joined(separator: "\n")
    }

    private var accessibilityLabel: String {
        var parts = [event.event.displayTitle, event.kind.displayName.lowercased()]
        parts.append(event.event.occupiesAllDayRow(calendar: calendar)
            ? "all day"
            : "\(event.event.startAt.formatted(date: .omitted, time: .shortened)) to \(event.event.endAt.formatted(date: .omitted, time: .shortened))")
        if !participantsLabel.isEmpty { parts.append(participantsLabel) }
        if event.hasConflict { parts.append(conflictDescription) }
        if event.event.isCancelled { parts.append("canceled") }
        if let preparation = event.preparation.summary { parts.append(preparation) }
        return parts.joined(separator: ", ")
    }
}

/// One face on an invitation.
struct TodayParticipantChip: View {
    let participant: DayParticipant

    var body: some View {
        Circle()
            .fill(fill)
            .overlay {
                Text(participant.initials)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(foreground)
            }
            .overlay {
                Circle().strokeBorder(Theme.Colors.contentBackground, lineWidth: 1.5)
            }
            .frame(width: 20, height: 20)
            // Declined is drawn dimmer rather than removed: somebody who said no to your meeting is
            // something you want to know before you walk in expecting them.
            .opacity(participant.participation == .declined ? 0.45 : 1)
            .accessibilityHidden(true)
    }

    /// Somebody the library knows gets their own colour; somebody who is only an address on an
    /// invitation gets a neutral fill, which is the honest difference between the two.
    private var fill: Color {
        participant.isKnown ? Theme.Colors.link.opacity(0.16) : Theme.Colors.subtleFill
    }

    private var foreground: Color {
        participant.isKnown ? Theme.Colors.link : Theme.Colors.secondaryText
    }
}

/// Everything a meeting can be asked to do.
struct TodayEventMenu: View {
    let event: DayEvent
    let model: TodayModel
    let actions: TodayActions

    var body: some View {
        if actions.joinLink(for: event) != nil {
            Button("Join Call", systemImage: "video") { actions.join(event) }
        }

        Button("Open in Calendar", systemImage: "calendar") { actions.openInCalendar(event) }
        Button("Meeting Notes", systemImage: "note.text") { actions.openNotes(for: event) }

        if !event.participants.isEmpty {
            Divider()
            Menu("Attendees") {
                ForEach(event.participants) { participant in
                    if let id = participant.personID {
                        Button(participant.name) { actions.select(id) }
                    } else {
                        // Somebody on the invitation the library has never heard of. Naming them is
                        // useful; pretending there is a record to open is not.
                        Text(participant.name)
                    }
                }
            }
        }

        Divider()

        Button("Add Preparation Task", systemImage: "checklist") {
            actions.addPreparationTask(titled: "Prepare for \(event.event.displayTitle)", for: event)
        }

        if !event.preparation.openPreparationTaskIDs.isEmpty {
            Button("Mark Preparation Done", systemImage: "checkmark.circle") {
                actions.markPreparationComplete(for: event)
            }
        }

        Button("Log a Follow-up", systemImage: "arrow.turn.up.right") {
            actions.logFollowUp(titled: "Follow up: \(event.event.displayTitle)", for: event)
        }

        // Editing lives in the calendar, and only where the calendar allows it. A subscribed
        // calendar refuses writes and says why — offering Reschedule here would be offering a
        // control that fails.
        if event.event.isEditable {
            Divider()
            Button("Reschedule…", systemImage: "clock.arrow.2.circlepath") {
                actions.openInCalendar(event)
            }
        }
    }
}

// MARK: - Tasks

/// One task in a day.
///
/// ### What a row shows and what it does not
/// The completion control, the title, and **only the metadata that is currently true and currently
/// relevant** — why it is here today, a time if it has one, a project, a person, an estimate. A task
/// with none of those is one line and nothing else, which is what most tasks are. Overdue is drawn
/// with the same weight as everything else and a colour on the *reason* alone: the news is the date,
/// not the whole row, and a list of red rows stops meaning anything by the third one.
struct TodayTaskRow: View {
    @Environment(\.services) private var services

    let task: DayTask
    let item: Item
    let plan: DayPlan
    let actions: TodayActions
    var isSelected = false
    var pinnedAt: Date?

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    /// ### Why the metadata is computed once and passed in
    /// It was computed three times per row — the emptiness check, the `ForEach`, and the
    /// accessibility label — and each pass builds the reason, resolves the container by walking the
    /// ancestor chain, and faults the waiting-on person out of `outgoingLinks`. Three of those per
    /// row, times every row in the day, times every pass the view makes. A computed property cannot
    /// cache; a parameter can.
    var body: some View {
        row(metadata)
    }

    private func row(_ pieces: [Piece]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            if pinnedAt != nil {
                timeGutter
            }

            completionControl

            titleLine

            Spacer(minLength: Theme.Spacing.small)

            // ### Why this is the same shape a task row in Tasks has
            // It is the same object. Today drew it with its facts on a second line and the Tasks
            // list drew it with them on a second line of its own design, which is redesign issue #8:
            // one thing, two pictures, and a reader who has to learn both. The facts are now on the
            // trailing edge in both places, off the same rule — only what is currently true — with
            // the same completion control at the head of the row.
            //
            // What stays different is what is genuinely different: a time gutter for work pinned to
            // an hour, the reason the task is here today, and the actions this page offers on hover.
            if !pieces.isEmpty { metadataLine(pieces) }

            // Focus reveals them too. A control that only exists under a pointer is a control
            // somebody navigating by keyboard cannot know about, let alone reach.
            if isHovering || isFocused { hoverActions }
        }
        .padding(.vertical, Theme.Spacing.tight)
        .frame(minHeight: Theme.Size.rowHeight)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .hoverHighlight(isEnabled: !isSelected || isFocused, extending: Theme.Spacing.small)
        .onTapGesture { actions.select(item.id) }
        // ### Why the row is focusable rather than wrapped in a button
        // A row is not one control — it carries a completion circle and, on hover, three more — and
        // nesting those inside an outer button on macOS makes the inner ones unreachable. So the row
        // takes focus in its own right and answers the two keys a row owes somebody who is not using
        // a mouse: Return opens it, Space ticks it off. Full Keyboard Access reaches the inner
        // controls the ordinary way.
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled(false)
        .onKeyPress(.return) {
            actions.select(item.id)
            return .handled
        }
        .onKeyPress(.space) {
            actions.toggleCompletion(item)
            return .handled
        }
        .contextMenu { TodayTaskMenu(task: task, item: item, plan: plan, actions: actions) }
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(pieces))
        .accessibilityAddTraits(item.status == .completed ? [.isSelected] : [])
    }

    @ViewBuilder
    private var timeGutter: some View {
        Text((pinnedAt ?? item.reminderAt ?? plan.date).formatted(date: .omitted, time: .shortened))
            .font(Theme.Text.metadata)
            .monospacedDigit()
            .foregroundStyle(Theme.Colors.secondaryText)
            .frame(width: TodayMetrics.timeGutterWidth, alignment: .leading)
    }

    /// The same control the Tasks list and the open card draw. Three copies of one circle is three
    /// chances for a flagged task to look different depending on which screen it is on.
    private var completionControl: some View {
        TaskCompletionControl(task: item) { actions.toggleCompletion(item) }
    }

    private var titleLine: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Text(item.displayTitle)
                .font(Theme.Text.rowTitle)
                .rowForeground(item.title.isEmpty ? .placeholder : .primary)
                .lineLimit(1)

            if item.isFlagged {
                Image(systemName: "flag.fill")
                    .font(.system(size: 8))
                    .rowTint(Theme.Colors.dueToday)
                    .accessibilityHidden(true)
            }

            if let symbol = item.priority.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: 8))
                    .rowForeground(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    private func metadataLine(_ pieces: [Piece]) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            ForEach(pieces) { piece in
                HStack(spacing: Theme.Spacing.hairline) {
                    Image(systemName: piece.symbolName)
                        .font(.system(size: 9))
                    Text(piece.text)
                        .font(Theme.Text.metadata)
                        .lineLimit(1)
                }
                .modifier(TodayMetadataTint(color: piece.color))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private struct Piece: Identifiable {
        var id: String
        var symbolName: String
        var text: String
        /// `nil` means secondary, which is most of them. Colour is reserved for a date that has
        /// actually arrived.
        var color: Color?
    }

    /// One line, at most, of what is currently true.
    private var metadata: [Piece] {
        var pieces: [Piece] = []

        // Why the task is here at all, which is the piece of context this page can give and a list
        // sorted by due date cannot.
        if let reason = task.primaryReason {
            pieces.append(
                Piece(
                    id: "reason",
                    symbolName: reason.symbolName,
                    text: reason.label,
                    color: colour(for: reason)
                )
            )
        }

        if let container = containerTitle {
            pieces.append(Piece(id: "container", symbolName: "folder", text: container))
        }

        if let person = item.waitingOnPerson() {
            pieces.append(Piece(id: "waiting", symbolName: "hourglass", text: person.displayTitle))
        }

        if let estimate = item.estimateMinutes, estimate > 0 {
            pieces.append(
                Piece(
                    id: "estimate",
                    symbolName: "hourglass.bottomhalf.filled",
                    text: DurationPhrase.exact(TimeInterval(estimate * 60))
                )
            )
        }

        let facts = item.taskFacts()
        if facts.checklistTotal > 0 {
            pieces.append(
                Piece(
                    id: "steps",
                    symbolName: "checklist",
                    text: "\(facts.checklistCompleted)/\(facts.checklistTotal)"
                )
            )
        }

        if facts.lifecycle == .waiting {
            pieces.append(Piece(id: "blocked", symbolName: "pause.circle", text: "Blocked"))
        }

        return pieces
    }

    /// Calm urgency: amber for late, and never red. Overdue is information about a date; a red row
    /// is an accusation about a person.
    private func colour(for reason: DayTaskReason) -> Color? {
        switch reason {
        case .overdue, .due: Theme.Colors.dueToday
        case .followUp: Theme.Colors.warning
        default: nil
        }
    }

    private var containerTitle: String? {
        let containers = item.enclosingContainers()
        return (containers.project ?? containers.list ?? containers.area)?.displayTitle
    }

    /// The three actions worth reaching without a menu, revealed on hover.
    private var hoverActions: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Button { actions.startTimer(on: item) } label: {
                Image(systemName: "play.circle")
            }
            .help("Start a timer on this")
            .accessibilityLabel("Start timer")

            Button { actions.reschedule(item, to: tomorrow) } label: {
                Image(systemName: "arrow.uturn.right.circle")
            }
            .help("Move to tomorrow")
            .accessibilityLabel("Move to tomorrow")

            Button { actions.setFlagged(!item.isFlagged, on: item) } label: {
                Image(systemName: item.isFlagged ? "flag.slash" : "flag")
            }
            .help(item.isFlagged ? "Remove the flag" : "Flag this")
            .accessibilityLabel(item.isFlagged ? "Unflag" : "Flag")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.Colors.secondaryText)
        .transition(.opacity)
    }

    private var tomorrow: Date {
        let clock = services?.dateProvider ?? SystemDateProvider()
        return clock.calendar.date(byAdding: .day, value: 1, to: plan.date) ?? clock.startOfTomorrow
    }

    private var tooltip: String {
        var lines = [item.displayTitle]
        if !item.body.isEmpty { lines.append(String(item.body.prefix(240))) }
        return lines.joined(separator: "\n")
    }

    private func accessibilityLabel(_ pieces: [Piece]) -> String {
        var parts = [item.displayTitle]
        if item.status == .completed { parts.append("completed") }
        if item.isFlagged { parts.append("flagged") }
        if item.priority != .normal { parts.append("\(item.priority.displayName) priority") }
        parts.append(contentsOf: pieces.map(\.text))
        return parts.joined(separator: ", ")
    }
}

/// Applies a meaning-carrying colour, or the row's ordinary secondary style when there is none.
///
/// A modifier rather than a conditional inside the row, because `rowTint` and `rowForeground` are
/// different modifiers returning different types and a ternary between them does not typecheck.
private struct TodayMetadataTint: ViewModifier {
    let color: Color?

    func body(content: Content) -> some View {
        if let color {
            content.rowTint(color)
        } else {
            content.rowForeground(.secondary)
        }
    }
}

/// Everything a task can be asked to do from this page.
struct TodayTaskMenu: View {
    @Environment(\.services) private var services

    let task: DayTask
    let item: Item
    let plan: DayPlan
    let actions: TodayActions

    var body: some View {
        Button(item.status == .completed ? "Mark Incomplete" : "Mark Complete", systemImage: "checkmark.circle") {
            actions.toggleCompletion(item)
        }

        Button("Open", systemImage: "sidebar.trailing") { actions.select(item.id) }
        Button("Open in Tasks", systemImage: "checkmark.circle") { actions.openInModule(item) }

        Divider()

        Menu("Move To") {
            Button("Today") { actions.reschedule(item, to: clock.startOfToday) }
            Button("Later Today") { actions.moveToLaterToday(item) }
            Button("Tomorrow") { actions.reschedule(item, to: clock.startOfTomorrow) }
            Button("Next Week") { actions.reschedule(item, to: clock.startOfDay(daysFromToday: 7)) }
            Divider()
            Button("Take Off the Plan") { actions.reschedule(item, to: nil) }
        }

        Menu("Deadline") {
            Button("Today") { actions.setDeadline(clock.startOfToday, on: item) }
            Button("Tomorrow") { actions.setDeadline(clock.startOfTomorrow, on: item) }
            Button("In a Week") { actions.setDeadline(clock.startOfDay(daysFromToday: 7), on: item) }
            Divider()
            Button("Clear Deadline") { actions.setDeadline(nil, on: item) }
        }

        Menu("Priority") {
            ForEach(Priority.allCases, id: \.self) { priority in
                Button {
                    actions.setPriority(priority, on: item)
                } label: {
                    Label(priority.displayName, systemImage: item.priority == priority ? "checkmark" : "")
                }
            }
        }

        Divider()

        Button(item.isFlagged ? "Unflag" : "Flag", systemImage: "flag") {
            actions.setFlagged(!item.isFlagged, on: item)
        }
        Button("Start Timer", systemImage: "play.circle") { actions.startTimer(on: item) }

        Divider()

        // The canonical deletion, which every other task list already had. Linked tasks follow the
        // task list's two-command rule — see `TaskRowMenu` for why that is never a dialog.
        if item.syncState == .local {
            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                actions.moveToTrash(item)
            }
        } else {
            Button("Remove from Elephruit Only", systemImage: "trash", role: .destructive) {
                actions.deleteLinked(item, choice: .removeLocally)
            }
            .help("The reminder stays exactly where it is.")

            Button("Delete Here and in Reminders", systemImage: "trash.slash", role: .destructive) {
                actions.deleteLinked(item, choice: .deleteBoth)
            }
            .help("Removes the reminder from Reminders too, on every device it syncs to.")
        }
    }

    private var clock: any DateProvider { services?.dateProvider ?? SystemDateProvider() }
}

// MARK: - Compact lines, for a day nobody is standing on

struct TodayCompactEventLine: View {
    @Environment(\.services) private var services

    let event: DayEvent

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(timeText)
                .font(Theme.Text.metadata)
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.color(named: event.event.calendarColorName))
                .frame(width: TodayMetrics.timeGutterWidth, alignment: .leading)

            Text(event.event.displayTitle)
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.primaryText)
                .strikethrough(event.event.isCancelled, color: Theme.Colors.tertiaryText)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(timeText), \(event.event.displayTitle)")
    }

    private var timeText: String {
        let calendar = (services?.dateProvider ?? SystemDateProvider()).calendar
        return event.event.occupiesAllDayRow(calendar: calendar)
            ? "All day"
            : event.event.startAt.formatted(date: .omitted, time: .shortened)
    }
}

struct TodayCompactTaskLine: View {
    let task: DayTask
    let item: Item

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: task.primaryReason?.symbolName ?? "circle")
                .font(.system(size: 9))
                .foregroundStyle(Theme.Colors.tertiaryText)
                .frame(width: TodayMetrics.timeGutterWidth, alignment: .leading)

            Text(item.displayTitle)
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.displayTitle)
    }
}
