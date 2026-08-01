import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// What the tracker does when you press its button.
///
/// One surface with two modes rather than a surface and a separate sheet. The fields are identical —
/// what you did, what it was against, who was there, its tags, whether it is billable — and only the
/// question of *when* differs: a timer starts now, a manual entry states its own span. Splitting
/// that into two surfaces means the commonest recovery from forgetting to start a timer begins with
/// finding a different piece of UI.
enum TimeEntryMode: String, CaseIterable, Hashable {
    /// Press to start; press again to stop.
    case timer

    /// Type a span, press to record it. Nothing runs.
    case manual

    var symbolName: String {
        switch self {
        case .timer: "stopwatch"
        case .manual: "plus.rectangle"
        }
    }

    var displayName: String {
        switch self {
        case .timer: "Timer"
        case .manual: "Manual"
        }
    }

    var hint: String {
        switch self {
        case .timer: "Start a timer running now."
        case .manual: "Record time you have already spent."
        }
    }
}

/// The tracker at the top of the Time view: what you are doing, and everything it is filed under.
///
/// ### Why this is a card rather than a bar
/// It was a bar — one row holding a description field, four pickers, a duration and two buttons —
/// and a row is the wrong container for a set that grows. Every field added made the description
/// narrower, and the description is the one that has to be inviting because it is the one typed into
/// every single time. At the width the app actually opens at, the pickers had already squeezed it to
/// a few characters.
///
/// So the shape follows what each part is. The **line you type** gets its own row and the whole
/// width. What it is **filed under** is a wrapping set of chips, because the number of them is the
/// user's and not the designer's — three tags and two people is a normal afternoon and must not
/// push the clock off the edge. The **clock and the buttons** hold the trailing edge at a fixed
/// place, so the target you press does not move as the rest of the row fills up.
///
/// The fields stay live while the timer runs, so nothing is lost by starting first: naming the thing
/// three minutes in writes to the running entry rather than to a draft that has to be applied
/// afterwards.
struct TimeTrackerCard: View {
    @Environment(\.services) private var services

    /// Owned by the Time view, because the toolbar's *Add Time* switches it too — a mode two
    /// controls can set cannot live inside one of them.
    @Binding var mode: TimeEntryMode

    /// Told rather than asked, so the view that owns the list can reload when this card writes.
    let onChange: () -> Void
    let onOpenSubject: (UUID) -> Void

    @State private var draft = TimeEntryComposition()
    @State private var durationText = ""
    @State private var manualStart = Date()
    @State private var manualEnd = Date()

    /// A length typed into the duration field before the timer was started.
    ///
    /// Applied the moment it starts, so the timer opens already reading that long. Without this the
    /// field is a dead control in timer mode, which is worse than either allowing it or removing it.
    @State private var pendingBackdate: TimeInterval?
    @FocusState private var isDescriptionFocused: Bool
    @FocusState private var isDurationFocused: Bool

    /// Whether the clock has been clicked and is a field for the moment.
    @State private var isEditingDuration = false

    private var running: RunningTimer? { services?.timer.running }
    private var isRunning: Bool { running != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(alignment: .center, spacing: Theme.Spacing.medium) {
                statusGlyph

                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    descriptionField
                    filingChips
                }

                Spacer(minLength: Theme.Spacing.small)

                clockAndControls
            }

            if mode == .manual, !isRunning {
                manualSpanFields
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.medium)
        // ### Why this is a card and not the top of the window
        // It was a full-bleed slab pinned across the whole width, which is the shape of a *toolbar*
        // — something that belongs to the window rather than to the work. This belongs to the work:
        // it is one entry being composed, and on a wide screen a single entry stretched to seventeen
        // hundred points reads as a banner, not a thing you are filling in. An inset card with a
        // border says where it ends.
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Theme.Colors.contentBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(isRunning ? Theme.Colors.destructive.opacity(0.35) : Theme.Colors.separator)
        }
        .calmAnimation(value: isRunning)
        .onAppear(perform: syncFromRunning)
        .onChange(of: running?.id) { _, _ in syncFromRunning() }
        .onChange(of: mode) { _, _ in
            prepareManualSpan()
            syncDurationDisplay()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Time.timerBar)
    }

    // MARK: - Status

    /// The mode switch, or the running dot in the same slot.
    ///
    /// One slot rather than two, so the description begins at the same x whether or not anything is
    /// running — a field that shifts sideways the moment you press play is a field that loses the
    /// caret.
    @ViewBuilder
    private var statusGlyph: some View {
        if isRunning {
            Image(systemName: "record.circle")
                .font(.title2)
                .foregroundStyle(Theme.Colors.destructive)
                .symbolEffect(.pulse, options: .repeating)
                .frame(width: 28)
                .accessibilityHidden(true)
        } else {
            Menu {
                ForEach(TimeEntryMode.allCases, id: \.self) { candidate in
                    Button {
                        mode = candidate
                    } label: {
                        Label(candidate.displayName, systemImage: candidate.symbolName)
                    }
                    .help(candidate.hint)
                }
            } label: {
                Image(systemName: mode.symbolName)
                    .font(.title3)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 28)
            .help(mode.hint)
            .accessibilityLabel("Entry mode: \(mode.displayName)")
            .accessibilityIdentifier(AccessibilityID.Time.modeToggle)
        }
    }

    // MARK: - Fields

    private var descriptionField: some View {
        TextField(
            mode == .manual ? "What did you work on?" : "What are you working on?",
            text: $draft.description
        )
        .textFieldStyle(.plain)
        .font(.system(.title3, design: .default, weight: .regular))
        .focused($isDescriptionFocused)
        .onSubmit { primaryAction() }
        // Written when the field gives up focus rather than on every keystroke: a running timer's
        // description is something you finish typing before you care that it is saved, and a write
        // per character would be a thousand saves for one sentence.
        .onChange(of: isDescriptionFocused) { _, focused in
            guard !focused, isRunning else { return }
            services?.timer.setDescription(draft.description)
            commitChange()
        }
        .accessibilityIdentifier(AccessibilityID.Time.descriptionField)
    }

    /// Everything the entry is filed under, wrapping rather than compressing.
    private var filingChips: some View {
        ElephruitDesign.FlowLayout(spacing: Theme.Spacing.tight, lineSpacing: Theme.Spacing.tight) {
            TimeSubjectPicker(
                placeholder: "Item",
                subject: draft.subject,
                onPick: { subject in
                    draft.subject = subject
                    guard isRunning else { return }
                    services?.timer.setSubject(resolve(draft.subject))
                    commitChange()
                },
                onOpen: onOpenSubject
            )

            TimeProjectPicker(placeholder: "Project", project: draft.project) { project in
                draft.project = project
                guard isRunning else { return }
                services?.timer.setProject(resolve(draft.project))
                commitChange()
            }

            TimePeoplePicker(placeholder: "People", people: draft.people) { people in
                draft.people = people
                guard isRunning else { return }
                services?.timer.setPeople(resolveAll(draft.people))
                commitChange()
            }

            TimeTagPicker(placeholder: "Tags", slugs: draft.tagSlugs) { slugs in
                draft.tagSlugs = slugs
                guard isRunning else { return }
                services?.timer.setTags(slugs)
                commitChange()
            }

            billableToggle
        }
    }

    private var billableToggle: some View {
        Button {
            draft.isBillable.toggle()
            if isRunning {
                services?.timer.setBillable(draft.isBillable)
                commitChange()
            }
        } label: {
            TimeChipLabel(
                symbolName: draft.isBillable ? "dollarsign.circle.fill" : "dollarsign.circle",
                title: "Billable",
                isFilled: draft.isBillable
            )
        }
        .buttonStyle(.plain)
        .help(draft.isBillable ? "Billable" : "Not billable")
        .accessibilityLabel("Billable")
        .accessibilityValue(draft.isBillable ? "on" : "off")
        .accessibilityIdentifier(AccessibilityID.Time.billableToggle)
    }

    /// The span, in manual mode.
    ///
    /// Typing a duration moves the *end*, because the start is the part somebody recording a past
    /// stretch is sure about — "I started at nine and it took about ninety minutes".
    private var manualSpanFields: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text("From")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)

            DatePicker("From", selection: $manualStart, displayedComponents: [.hourAndMinute, .date])
                .datePickerStyle(.compact)
                .labelsHidden()
                .onChange(of: manualStart) { _, _ in syncDurationDisplay() }

            Text("to")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)

            DatePicker("To", selection: $manualEnd, displayedComponents: [.hourAndMinute, .date])
                .datePickerStyle(.compact)
                .labelsHidden()
                .onChange(of: manualEnd) { _, _ in syncDurationDisplay() }

            Spacer()
        }
        .padding(.leading, 28 + Theme.Spacing.medium)
    }

    // MARK: - The clock

    private var clockAndControls: some View {
        HStack(spacing: Theme.Spacing.small) {
            clock

            focusButton

            actionButton

            if isRunning {
                discardButton
            }
        }
    }

    /// The elapsed time, and the field it becomes when you click it.
    ///
    /// ### Why the running clock is not the text field
    /// It was, and it did not move. A `TextField` bound to `@State` can only advance when something
    /// writes to that state, which made the clock a downstream consequence of the service's tick
    /// arriving *and* of the view being invalidated by it. Both are true most of the time and
    /// neither is guaranteed: the observed result was a clock that sat at zero for fifteen seconds,
    /// jumped, then sat still until a minute and a half had gone.
    ///
    /// A running clock is not state. It is a pure function of one stored date and the current
    /// moment, so it is drawn as one: `TimelineView` asks SwiftUI to redraw on a cadence it owns,
    /// and each redraw computes the elapsed time from `startedAt`. There is nothing left to fall out
    /// of step with, and it stays right across a sleep, a missed tick, and a clock change.
    ///
    /// It becomes a field on click, because typing a length into it is the correction this whole
    /// module is built around — see ``ElephruitCore/DurationParser``.
    @ViewBuilder
    private var clock: some View {
        if isEditingDuration || mode == .manual || !isRunning {
            TextField("0:00:00", text: $durationText)
                .textFieldStyle(.plain)
                .font(clockFont)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 116)
                .foregroundStyle(Theme.Colors.secondaryText)
                .focused($isDurationFocused)
                .onSubmit(finishEditingDuration)
                .onChange(of: isDurationFocused) { _, focused in
                    guard !focused else { return }
                    finishEditingDuration()
                }
                .help("Type a length — 1:30, 1.5, or 90m")
                .accessibilityLabel("Duration")
                .accessibilityIdentifier(AccessibilityID.Time.durationField)
        } else if let running {
            TimelineView(.periodic(from: running.startedAt, by: 1)) { context in
                Text(TimeFormatting.stopwatch(running.elapsed(at: context.date)))
                    .font(clockFont)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(width: 116, alignment: .trailing)
            .contentShape(.rect)
            .onTapGesture { beginEditingDuration() }
            .help("Click to correct how long this has been running")
            .accessibilityLabel("Elapsed")
            .accessibilityIdentifier(AccessibilityID.Time.durationField)
        }
    }

    private var clockFont: Font {
        .system(.title, design: .rounded, weight: .medium)
    }

    private func beginEditingDuration() {
        syncDurationDisplay()
        isEditingDuration = true
        isDurationFocused = true
    }

    private func finishEditingDuration() {
        commitDuration()
        isEditingDuration = false
    }

    // MARK: - Actions

    private var actionButton: some View {
        Button(action: primaryAction) {
            Image(systemName: actionSymbol)
                .font(.title3)
                .frame(width: 34, height: 34)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        // AppKit's own answer to "text on an accent fill", rather than white. White is right under
        // a blue accent and wrong under a yellow one, and this is the token that knows which.
        .foregroundStyle(Theme.Colors.onAccent)
        .background(
            Circle().fill(isRunning ? Theme.Colors.destructive : Theme.Colors.selection)
                .opacity(canAct ? 1 : 0.4)
        )
        .disabled(!canAct)
        .help(actionTitle)
        .accessibilityLabel(actionTitle)
        .accessibilityIdentifier(
            isRunning ? AccessibilityID.Time.stopButton : AccessibilityID.Time.startButton
        )
    }

    /// Starts a focus cycle over whatever is being tracked.
    ///
    /// ### Why this is a labelled pill and not an icon
    /// It was a bare `brain.head.profile` glyph between the clock and the Stop button, at the same
    /// weight as the discard cross — and the first person to use it could not find the pomodoro at
    /// all. An unlabelled icon among other unlabelled icons is not a feature anybody discovers; it
    /// is a feature they have to be told about. The word costs forty points and removes the need to
    /// be told.
    ///
    /// Beside Start rather than in a menu, and only in timer mode: a pomodoro is a way of working
    /// through the next half hour, which is not something you can decide about an afternoon you are
    /// typing in from memory.
    @ViewBuilder
    private var focusButton: some View {
        if mode == .timer, services?.timer.isFocusing != true {
            Button {
                services?.timer.startFocus(
                    item: resolve(draft.subject),
                    project: resolve(draft.project),
                    people: resolveAll(draft.people),
                    description: draft.description,
                    tagSlugs: draft.tagSlugs,
                    isBillable: draft.isBillable
                )
                commitChange()
            } label: {
                HStack(spacing: Theme.Spacing.tight) {
                    Image(systemName: "brain.head.profile")
                    Text("Focus")
                }
                .font(Theme.Text.rowSubtitle)
                .padding(.horizontal, Theme.Spacing.small)
                .frame(height: 28)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.selection)
            .background(Capsule().fill(Theme.Colors.selection.opacity(0.12)))
            .help(focusHint)
            .accessibilityLabel("Start a focus block")
            .accessibilityIdentifier(AccessibilityID.Time.focusButton)
        }
    }

    /// Says what pressing Focus will actually do, in the lengths this person has set.
    private var focusHint: String {
        let plan = services?.timer.pomodoroPlan ?? .standard
        let focus = Int((plan.focus / 60).rounded())
        let rest = Int((plan.shortBreak / 60).rounded())
        return isRunning
            ? "Work in \(focus)-minute blocks with \(rest)-minute breaks, starting now"
            : "Start the timer and work in \(focus)-minute blocks with \(rest)-minute breaks"
    }

    private var discardButton: some View {
        Button {
            services?.timer.discard()
            draft = TimeEntryComposition()
            commitChange()
        } label: {
            Image(systemName: "xmark")
                .font(.body)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Deliberately quiet next to Stop. Both end the timer and only one keeps the time, so the
        // destructive one must not be the one the eye lands on first.
        .foregroundStyle(Theme.Colors.secondaryText)
        .help("Discard this timer without recording it")
        .accessibilityLabel("Discard timer")
        .accessibilityIdentifier(AccessibilityID.Time.discardButton)
    }

    private var actionTitle: String {
        if isRunning { return "Stop" }
        return mode == .manual ? "Add" : "Start"
    }

    private var actionSymbol: String {
        if isRunning { return "stop.fill" }
        return mode == .manual ? "plus" : "play.fill"
    }

    private var canAct: Bool {
        if isRunning { return true }
        return mode == .timer || manualEnd > manualStart
    }

    private func primaryAction() {
        guard let services else { return }

        if isRunning {
            services.timer.setDescription(draft.description)
            services.timer.stop()
            draft = TimeEntryComposition()
            commitChange()
            return
        }

        switch mode {
        case .timer:
            services.timer.switchTo(
                item: resolve(draft.subject),
                project: resolve(draft.project),
                people: resolveAll(draft.people),
                description: draft.description,
                tagSlugs: draft.tagSlugs,
                isBillable: draft.isBillable
            )

            // A duration typed before pressing play starts the timer already that long — the "I have
            // been at this twenty minutes and forgot to start it" case, which otherwise means
            // starting a timer and immediately correcting it.
            if let backdate = pendingBackdate {
                services.timer.setElapsed(backdate)
                pendingBackdate = nil
            }

        case .manual:
            guard manualEnd > manualStart else { return }
            let subject = resolve(draft.subject)
            let project = resolve(draft.project)
            let people = resolveAll(draft.people)

            services.perform {
                try services.timeEntries.addManual(
                    item: subject,
                    project: project,
                    people: people,
                    description: draft.description,
                    startedAt: manualStart,
                    endedAt: manualEnd,
                    tagSlugs: draft.tagSlugs,
                    isBillable: draft.isBillable
                )
            }
            // The description clears and everything else stays. Logging a morning by hand is four
            // entries against the same project with the same tags, and re-picking them each time is
            // the friction that stops people doing it at all.
            draft.description = ""
            manualStart = manualEnd
            manualEnd = manualStart.addingTimeInterval(3_600)
            syncDurationDisplay()
        }

        commitChange()
    }

    private func commitDuration() {
        guard let parsed = DurationParser.parse(durationText) else {
            // Unreadable input is not applied and not cleared — what was typed stays there to be
            // fixed, because silently reverting a field somebody just typed into reads as the app
            // losing their work.
            syncDurationDisplay()
            return
        }

        if isRunning {
            services?.timer.setElapsed(parsed)
            commitChange()
        } else if mode == .manual {
            manualEnd = manualStart.addingTimeInterval(parsed)
        } else {
            pendingBackdate = parsed > 0 ? parsed : nil
        }

        syncDurationDisplay()
    }

    private func commitChange() {
        onChange()
    }

    // MARK: - Resolving

    /// A picked reference as an `Item`, or `nil`.
    ///
    /// The draft holds ids and titles rather than the items themselves, because a view cannot safely
    /// keep a `PersistentModel` across a store change. This is where that is turned back into
    /// something the repository can file against, and a lookup that fails means the item was deleted
    /// while the card was open — in which case tracking against nothing is the right answer, not a
    /// refusal to start.
    private func resolve(_ reference: SubjectReference?) -> Item? {
        guard let services, let reference else { return nil }
        return (try? services.items.item(id: reference.id)) ?? nil
    }

    private func resolveAll(_ references: [SubjectReference]) -> [Item] {
        references.compactMap { resolve($0) }
    }

    // MARK: - Draft

    /// Fills the card from whatever is running, so the fields describe the timer rather than a stale
    /// draft that happens to be sitting in them.
    private func syncFromRunning() {
        if let running {
            draft = TimeEntryComposition(
                description: running.entryDescription,
                subject: running.itemID.map { SubjectReference(id: $0, title: running.itemTitle ?? "Untitled") },
                project: running.projectID.map {
                    SubjectReference(id: $0, title: running.projectTitle ?? "Untitled")
                },
                people: running.people.map { SubjectReference(id: $0.id, title: $0.name) },
                tagSlugs: running.tagSlugs,
                isBillable: running.isBillable
            )
            pendingBackdate = nil
        } else {
            draft = TimeEntryComposition()
            pendingBackdate = nil
            prepareManualSpan()
        }
        syncDurationDisplay()
    }

    /// Defaults to the hour just gone, which is nearly always what somebody is recording.
    private func prepareManualSpan() {
        let now = services?.dateProvider.now ?? Date()
        manualEnd = now
        manualStart = now.addingTimeInterval(-3_600)
    }

    /// Keeps the duration text in step with whatever it is describing — unless it is being typed
    /// into, in which case the user's half-finished input wins over the clock.
    private func syncDurationDisplay() {
        guard !isDurationFocused else { return }

        if isRunning, let running {
            // Read straight off the start date rather than from the service's `elapsed`, so what
            // lands in the field when it is clicked is the same number the clock beside it was
            // showing — not whatever the last tick happened to leave behind.
            durationText = TimeFormatting.clock(running.elapsed(at: Date()))
        } else if mode == .manual {
            durationText = TimeFormatting.clock(max(0, manualEnd.timeIntervalSince(manualStart)))
        } else {
            durationText = TimeFormatting.clock(pendingBackdate ?? 0)
        }
    }
}

/// The fields an entry shares whether it is timed or typed.
///
/// One value rather than six `@State`s so that clearing the card, filling it from a running timer,
/// and handing it to a row editor are each one assignment and cannot half-happen.
struct TimeEntryComposition: Equatable {
    var description: String = ""
    var subject: SubjectReference?

    /// The project this is billed to, when the subject's own parent chain is not the answer.
    var project: SubjectReference?

    /// Who was there.
    var people: [SubjectReference] = []

    var tagSlugs: [String] = []
    var isBillable: Bool = false

    /// The filing of an entry that already exists, for an editor to start from.
    ///
    /// One initialiser rather than the same six-line literal at three call sites, which is where a
    /// field added to this type quietly stops being carried into an edit.
    init(_ snapshot: TimeEntrySnapshot) {
        self.init(
            description: snapshot.entryDescription,
            subject: snapshot.itemID.map {
                SubjectReference(id: $0, title: snapshot.itemTitle ?? "Untitled")
            },
            // Only a project the user chose. Filling this from a derived one would pin it on save,
            // and the entry would stop following its task the next time that task moved.
            project: snapshot.isProjectExplicit ? snapshot.projectID.map {
                SubjectReference(id: $0, title: snapshot.projectTitle ?? "Untitled")
            } : nil,
            people: snapshot.people.map { SubjectReference(id: $0.id, title: $0.name) },
            tagSlugs: snapshot.tagSlugs,
            isBillable: snapshot.isBillable
        )
    }

    init(
        description: String = "",
        subject: SubjectReference? = nil,
        project: SubjectReference? = nil,
        people: [SubjectReference] = [],
        tagSlugs: [String] = [],
        isBillable: Bool = false
    ) {
        self.description = description
        self.subject = subject
        self.project = project
        self.people = people
        self.tagSlugs = tagSlugs
        self.isBillable = isBillable
    }
}

/// An item referred to by a picker, without holding the item.
///
/// A `PersistentModel` cannot be held in view state that survives a store change, and none of these
/// surfaces needs more than the two fields it displays.
struct SubjectReference: Equatable, Hashable, Identifiable {
    var id: UUID
    var title: String
}
