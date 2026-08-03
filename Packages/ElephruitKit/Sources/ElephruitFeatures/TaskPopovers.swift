import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The six controls a task's card offers, each one a small popover over a single decision.
///
/// ### The rule these all obey
/// **A button is present only while its value is absent.** Once a task has a deadline, the Deadline
/// button is gone and the deadline is a chip; clearing it brings the button back. This is what keeps
/// a task with nothing set to one line of small controls rather than six empty form rows, and it is
/// asserted rather than agreed to — see ``ElephruitCore/TaskAttributes``.
///
/// ### Why the date controls are type-ahead fields
/// Because the app already understands "next tue" — ``ElephruitCore/TaskEntryParser`` has parsed it
/// in quick entry since the module was built — and offering that understanding in one surface and
/// not the other means the same three words mean two different things depending on where they were
/// typed. Both go through ``ElephruitCore/NaturalDateParser/interpret(_:)``, which is the function
/// quick entry itself calls, so there is one grammar rather than two that drift.
///
/// A grid is still there, underneath, because typing is faster only when you already know the date.
/// "The Tuesday after the bank holiday" is a thing you find by looking.

// MARK: - The field that replaces the button

/// A one-line field that reads a date phrase, with a clear control once anything is in it.
///
/// The placeholder is the button's own word — *When*, *Deadline* — so opening the control does not
/// change what it is called. That continuity is the reason this is a field in the button's place
/// rather than a field inside the popover: the thing you clicked is the thing you are typing into.
struct TaskDateTypeAheadField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Text.rowSubtitle)
                .focused($isFocused)
                .onSubmit(onSubmit)
                .frame(minWidth: 90)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear \(placeholder.lowercased())")
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.tight)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Theme.Colors.subtleFill)
        }
        .onAppear { isFocused = true }
    }
}

/// The row a resolved phrase produces, at the top of the popover.
///
/// Accented, because it is the answer to what was just typed and pressing Return takes it. One row,
/// never a ranked list: the parser is deterministic, so a second suggestion would be the app
/// pretending to be unsure.
struct TaskDateSuggestionRow: View {
    let suggestion: TaskDateSuggestion
    let onPick: () -> Void

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "calendar")
                Text(suggestion.title)
                    .font(Theme.Text.rowSubtitle)
                if !suggestion.detail.isEmpty {
                    Text("· " + suggestion.detail)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.onAccent.opacity(0.8))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.tight)
            .foregroundStyle(Theme.Colors.onAccent)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(Theme.Colors.selection)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("task.date.suggestion")
    }
}

// MARK: - The month

/// A month you can page through and pick a day from.
///
/// Geometry from ``ElephruitDesign/MonthGrid``, which the menu bar's mini calendar also draws, so
/// where the week starts and how many blanks precede the first is decided in one place.
struct TaskMonthPicker: View {
    let calendar: Calendar
    let today: Date
    var selected: Date?
    let onPick: (Date) -> Void

    @State private var visibleMonth: Date?

    private var month: Date {
        visibleMonth ?? selected ?? today
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.tight) {
            HStack {
                Button { page(by: -1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Previous month")

                Spacer(minLength: 0)

                Text(monthName)
                    .font(Theme.Text.sectionHeader)
                    .foregroundStyle(Theme.Colors.secondaryText)

                Spacer(minLength: 0)

                Button { page(by: 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next month")
            }
            .padding(.horizontal, Theme.Spacing.tight)

            MonthGrid(
                month: month,
                calendar: calendar,
                cellSize: CGSize(width: 26, height: 22),
                spacing: 1,
                showsWeekdayHeader: true
            ) { day in
                dayCell(day)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calendar for \(monthName)")
        .onChange(of: selected) { _, selection in
            guard let selection,
                  !calendar.isDate(selection, equalTo: month, toGranularity: .month)
            else { return }
            // Keyboard navigation can cross a month boundary without clicking the page arrows.
            // Keep the highlighted day visible instead of leaving selection in an offscreen month.
            visibleMonth = selection
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isToday = calendar.isDate(day, inSameDayAs: today)
        let isChosen = selected.map { calendar.isDate(day, inSameDayAs: $0) } ?? false

        return Button {
            onPick(day)
        } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(isChosen ? Theme.Colors.onAccent : Theme.Colors.primaryText)
                .frame(width: 26, height: 22)
                .background {
                    if isChosen {
                        Circle().fill(Theme.Colors.selection)
                    } else if isToday {
                        // A ring rather than a fill, so today and the chosen day are two different
                        // statements and a day can be both.
                        Circle().stroke(Theme.Colors.selection, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
    }

    private func page(by months: Int) {
        guard let next = calendar.date(byAdding: .month, value: months, to: month) else { return }
        visibleMonth = next
    }

    private var monthName: String {
        var style = Date.FormatStyle().month(.wide).year()
        style.timeZone = calendar.timeZone
        return month.formatted(style)
    }
}

// MARK: - When

/// *When*: the one control for every way of saying a task is not for right now.
///
/// ### Why Someday is in here rather than beside it
/// Because "not now" is one question with several answers, and Someday is one of them. Splitting it
/// out as its own toggle meant a task could be both scheduled for Thursday and parked indefinitely,
/// which is two people's answers to one question. Choosing anything here settles it.
///
/// ### Why none of this ever writes a deadline
/// A start date says *do not ask me until then* and can never make anything late; a deadline is an
/// external commitment and is the only date that can. Every control in this popover writes a start,
/// a commitment, or a reminder — never ``ElephruitPersistence/TaskService/setDeadline(_:on:)``. That
/// is the decision the whole scheduling model rests on, and there is a test that reads this file's
/// behaviour rather than trusting this paragraph.
struct WhenPopover: View {
    @Environment(\.services) private var services

    let task: Item
    let query: String
    let onFinish: () -> Void

    @State private var isAddingReminder = false
    @State private var reminderDate = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if let suggestion {
                TaskDateSuggestionRow(suggestion: suggestion) { pick(startingOn: suggestion.date) }
                Divider()
            }

            choice("Today", symbolName: "star", hint: "Put it on today's plan.") {
                apply(.today)
            }

            choice(
                "This Evening",
                symbolName: "moon",
                hint: "Today, in the back half of it."
            ) {
                apply(.thisEvening)
            }

            Divider()

            TaskMonthPicker(
                calendar: clock.calendar,
                today: clock.now,
                selected: task.availableFrom,
                onPick: { pick(startingOn: $0) }
            )

            Divider()

            choice(
                "Someday",
                symbolName: "archivebox",
                hint: "Parked on purpose. It leaves every count and cannot be late."
            ) {
                apply(.someday)
            }

            if task.availableFrom != nil || task.isSomeday {
                choice("Clear", symbolName: "xmark.circle", hint: "No start date, and not parked.") {
                    apply(.clear)
                }
            }

            Divider()

            reminderSection
        }
        .padding(Theme.Spacing.medium)
        .frame(width: 250)
    }

    // MARK: Reminder

    /// ### Why this is offered at all, given nothing is delivered
    /// The app schedules no `UNNotificationRequest`: it holds no notification entitlement, which
    /// `docs/25-tasks-module-record.md` records as a known gap. The choice was to leave the control
    /// out until a scheduler lands, or to offer it and say plainly what it does.
    ///
    /// It is offered, and it says so. The field already exists on the model and already draws on the
    /// row, so hiding it in the one place somebody would go looking for it makes the app seem to have
    /// lost the time rather than seem honest about it. What is not acceptable is a prominent *Add
    /// Reminder* that silently never interrupts — so the line underneath is not a footnote, it is
    /// part of the control.
    ///
    /// A reminder owned by Reminders is a different case and says so: that one really does arrive.
    @ViewBuilder
    private var reminderSection: some View {
        if let reminderAt = task.reminderAt {
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                HStack(spacing: Theme.Spacing.small) {
                    Label(
                        reminderAt.formatted(date: .abbreviated, time: .shortened),
                        systemImage: "bell"
                    )
                    .font(Theme.Text.rowSubtitle)

                    Spacer(minLength: 0)

                    Button("Remove") { act { try $0.tasks.setReminder(nil, timed: false, on: task) } }
                        .buttonStyle(.borderless)
                        .font(Theme.Text.metadata)
                }

                Text(reminderDeliveryNote)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if isAddingReminder {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                DatePicker(
                    "Remind me",
                    selection: $reminderDate,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
                .labelsHidden()

                HStack {
                    Button("Set") {
                        act { try $0.tasks.setReminder(reminderDate, timed: true, on: task) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Cancel") { isAddingReminder = false }
                        .buttonStyle(.borderless)
                        .font(Theme.Text.metadata)
                }

                Text(Self.notDeliveredNote)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Button("Add Reminder", systemImage: "bell") {
                reminderDate = clock.now
                isAddingReminder = true
            }
            .buttonStyle(.borderless)
            .font(Theme.Text.metadata)
            .accessibilityIdentifier("task.when.addReminder")
        }
    }

    static let notDeliveredNote = """
        Elephruit shows this time on the task. It does not send a notification yet.
        """

    private var reminderDeliveryNote: String {
        task.reminderOwner == .system
            ? "Reminders sends this one, so Elephruit will not send a second."
            : Self.notDeliveredNote
    }

    // MARK: Plumbing

    private var suggestion: TaskDateSuggestion? {
        services.flatMap { TaskDateSuggestion.resolving(query, using: $0.dateProvider) }
    }

    private var clock: any DateProvider {
        services?.dateProvider ?? SystemDateProvider()
    }

    private func pick(startingOn date: Date) {
        apply(.startingOn(date))
    }

    /// Every choice in this popover goes through one call, so what each one means is decided in the
    /// store rather than in five button actions — see ``ElephruitPersistence/TaskService/apply(_:to:)``.
    private func apply(_ choice: TaskWhenChoice) {
        act { try $0.tasks.apply(choice, to: task) }
    }

    private func choice(
        _ title: String,
        symbolName: String,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbolName)
                .font(Theme.Text.rowSubtitle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(hint)
        .accessibilityIdentifier("task.when.\(TextNormalizer.slug(title))")
    }

    private func act(_ work: (AppServices) throws -> Void) {
        guard let services else { return }
        services.perform {
            try work(services)
            services.noteChange(to: task)
        }
        onFinish()
    }
}

// MARK: - Deadline

/// *Deadline*: the only date that can make a task late.
///
/// Nothing else in this popover — no Today, no This Evening, no Someday. Those are answers to *when
/// will I do this*, and a deadline is an answer to *when does somebody else need it*. Putting them
/// in one control is how the two collapse into each other.
struct DeadlinePopover: View {
    @Environment(\.services) private var services

    let task: Item
    let query: String
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if let suggestion {
                TaskDateSuggestionRow(suggestion: suggestion) { pick(suggestion.date) }
                Divider()
            }

            TaskMonthPicker(
                calendar: clock.calendar,
                today: clock.now,
                selected: task.dueAt,
                onPick: pick
            )

            if task.dueAt != nil {
                Divider()

                Button("Clear Deadline", systemImage: "xmark.circle") {
                    act { try $0.tasks.setDeadline(nil, on: task) }
                }
                .buttonStyle(.borderless)
                .font(Theme.Text.metadata)
            }

            Text("A deadline is an outside commitment. A start date is when you will get to it.")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.medium)
        .frame(width: 250)
    }

    private var suggestion: TaskDateSuggestion? {
        services.flatMap { TaskDateSuggestion.resolving(query, using: $0.dateProvider) }
    }

    private var clock: any DateProvider {
        services?.dateProvider ?? SystemDateProvider()
    }

    private func pick(_ date: Date) {
        act { try $0.tasks.setDeadline(date, on: task) }
    }

    private func act(_ work: (AppServices) throws -> Void) {
        guard let services else { return }
        services.perform {
            try work(services)
            services.noteChange(to: task)
        }
        onFinish()
    }
}

// MARK: - The controls that open them

/// *When*, as a control: a button until you click it, a field while it is open.
///
/// The two states are one control rather than a button that reveals a field, because the word on the
/// button is the placeholder in the field. Nothing is renamed on the way in, and nothing new appears
/// beside what you clicked.
struct TaskWhenControl: View {
    @Environment(\.services) private var services

    let task: Item
    var onChange: () -> Void = {}

    @State private var isOpen = false
    @State private var query = ""

    var body: some View {
        Group {
            if isOpen {
                TaskDateTypeAheadField(placeholder: "When", text: $query, onSubmit: commit)
            } else {
                Button("When", systemImage: "calendar") { open() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("When you will get to this. Never a deadline.")
                    .accessibilityIdentifier("task.button.when")
            }
        }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            WhenPopover(task: task, query: query, onFinish: close)
        }
    }

    private func open() {
        query = ""
        isOpen = true
    }

    private func close() {
        isOpen = false
        query = ""
        onChange()
    }

    /// Return in the field takes the row the field is showing, which is the only row it shows.
    private func commit() {
        guard let services,
              let suggestion = TaskDateSuggestion.resolving(query, using: services.dateProvider)
        else { return }

        services.perform {
            try services.tasks.apply(.startingOn(suggestion.date), to: task)
            services.noteChange(to: task)
        }
        close()
    }
}

/// *Deadline*, as a control. The same two states, over the one date that can make a task late.
struct TaskDeadlineControl: View {
    @Environment(\.services) private var services

    let task: Item
    var onChange: () -> Void = {}

    @State private var isOpen = false
    @State private var query = ""

    var body: some View {
        Group {
            if isOpen {
                TaskDateTypeAheadField(placeholder: "Deadline", text: $query, onSubmit: commit)
            } else {
                Button("Deadline", systemImage: "flag.pattern.checkered") { open() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("The date this must be finished by. The only date that can make it overdue.")
                    .accessibilityIdentifier("task.button.deadline")
            }
        }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            DeadlinePopover(task: task, query: query, onFinish: close)
        }
    }

    private func open() {
        query = ""
        isOpen = true
    }

    private func close() {
        isOpen = false
        query = ""
        onChange()
    }

    private func commit() {
        guard let services,
              let suggestion = TaskDateSuggestion.resolving(query, using: services.dateProvider)
        else { return }

        services.perform {
            try services.tasks.setDeadline(suggestion.date, on: task)
            services.noteChange(to: task)
        }
        close()
    }
}

// MARK: - Tags, move, people

/// *Tags*, over the library's one vocabulary.
struct TaskTagPopover: View {
    @Environment(\.services) private var services

    let task: Item
    let onFinish: () -> Void

    var body: some View {
        TagPickerContent(slugs: task.tags.map(\.slug).sorted()) { slugs in
            guard let services else { return }
            services.perform {
                try services.items.setTags(task, slugs: slugs)
                services.noteChange(to: task)
            }
        }
    }
}

/// *Move*: which project, list, or area this task lives in.
///
/// Filing is a parent rather than a link for a task, because a task lives in exactly one place —
/// unlike a note, which may be filed under three projects at once. "No project" therefore means the
/// Inbox, and says so.
struct TaskMovePopover: View {
    @Environment(\.services) private var services

    let task: Item
    let onFinish: () -> Void

    @State private var projects: [ProjectChoice] = []

    var body: some View {
        ProjectPickerContent(
            chosenID: task.parent?.id,
            projects: projects,
            clearTitle: "Inbox",
            clearDetail: "Out of every project, waiting to be filed",
            footnote: nil
        ) { picked in
            move(to: picked?.id)
        }
        .onAppear { projects = ProjectChoice.live(in: services) }
    }

    private func move(to id: UUID?) {
        guard let services else { return }
        services.perform {
            let destination = id.flatMap { try? services.items.item(id: $0) } ?? nil
            try services.items.setParent(task, to: destination)
            services.noteChange(to: task)
        }
        onFinish()
    }
}

/// *People*: who this task involves.
///
/// One of the two controls a stricter task manager refuses to have. It is here because a task that
/// involves somebody is the ordinary case in the work this app is for, and because the link it
/// writes is the one the person's own page already reads — so attaching a name here makes the task
/// appear on their timeline without anything being copied anywhere.
struct TaskPeoplePopover: View {
    @Environment(\.services) private var services

    let task: Item
    let onFinish: () -> Void

    var body: some View {
        PeoplePickerContent(
            people: references,
            footnote: """
                They appear on this task and it appears on their page. Nothing is written to your \
                address book.
                """
        ) { updated in
            apply(updated)
        }
    }

    private var references: [SubjectReference] {
        task.linkedPeople(kinds: [.mentions])
            .map { SubjectReference(id: $0.id, title: $0.displayTitle) }
    }

    private func apply(_ updated: [SubjectReference]) {
        guard let services else { return }
        services.perform {
            let people = updated.compactMap { try? services.items.item(id: $0.id) }.compactMap { $0 }
            try services.tasks.setRelatedPeople(people, on: task)
            services.noteChange(to: task)
        }
    }
}
