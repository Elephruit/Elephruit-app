import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// What the entry bar does when you press its button.
///
/// One bar with two modes rather than a bar and a separate sheet. The fields are identical — what
/// you did, what it was against, its tags, whether it is billable — and only the question of *when*
/// differs: a timer starts now, a manual entry states its own span. Splitting that into two
/// surfaces means the commonest recovery from forgetting to start a timer begins with finding a
/// different piece of UI.
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

/// The bar at the top of the Time view: what you are doing, and the one button that changes it.
///
/// ### Why this is a form rather than a button
/// The old bar was a Start button that produced an untitled timer with nothing attached, on the
/// theory that filing it later is easier than filing it first. It is not: an untitled timer is a
/// row you have to *reconstruct* at the end of the day, from memory, and the memory is the thing
/// tracking was supposed to replace. Toggl's answer — a description field you type into and then
/// press play — costs a few seconds at the start and saves the reconstruction entirely.
///
/// The fields stay live while the timer runs, so nothing is lost by starting first anyway: naming
/// the thing three minutes in writes to the running entry rather than to a draft that has to be
/// applied afterwards.
struct TimeEntryBar: View {
    @Environment(\.services) private var services

    /// Owned by the Time view, because the toolbar's *Add Time* switches it too — a mode two
    /// controls can set cannot live inside one of them.
    @Binding var mode: TimeEntryMode

    /// Told rather than asked, so the view that owns the list can reload when this bar writes.
    let onChange: () -> Void
    let onOpenSubject: (UUID) -> Void

    @State private var draft = TimeEntryComposition()
    @State private var durationText = ""
    @State private var manualStart = Date()
    @State private var manualEnd = Date()
    @FocusState private var isDescriptionFocused: Bool
    @FocusState private var isDurationFocused: Bool

    private var running: RunningTimer? { services?.timer.running }

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            modeToggle

            descriptionField

            TimeSubjectPicker(
                subject: draft.subject,
                onPick: { subject in
                    draft.subject = subject
                    if running != nil {
                        services?.timer.setSubject(resolvedSubject())
                        commitChange()
                    }
                },
                onOpen: onOpenSubject
            )

            TimeTagPicker(
                slugs: draft.tagSlugs,
                onChange: { slugs in
                    draft.tagSlugs = slugs
                    if running != nil {
                        services?.timer.setTags(slugs)
                        commitChange()
                    }
                }
            )

            billableToggle

            Divider()
                .frame(height: 20)

            if mode == .manual {
                manualSpanFields
            }

            durationField

            actionButton

            if running != nil {
                discardButton
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .frame(minHeight: 52)
        .onAppear(perform: syncFromRunning)
        .onChange(of: running?.id) { _, _ in syncFromRunning() }
        .onChange(of: services?.timer.elapsed) { _, _ in syncDurationDisplay() }
        .onChange(of: mode) { _, _ in
            prepareManualSpan()
            syncDurationDisplay()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Time.timerBar)
    }

    // MARK: - Mode

    /// Hidden while a timer runs.
    ///
    /// Switching to manual mode with a timer going would leave the bar describing two different
    /// entries at once — the one ticking and the one about to be typed — and no arrangement of the
    /// fields makes that readable. Stopping first is one click and removes the question.
    @ViewBuilder
    private var modeToggle: some View {
        if running == nil {
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
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(mode.hint)
            .accessibilityLabel("Entry mode: \(mode.displayName)")
            .accessibilityIdentifier(AccessibilityID.Time.modeToggle)
        } else {
            Image(systemName: "record.circle")
                .foregroundStyle(Theme.Colors.destructive)
                .symbolEffect(.pulse, options: .repeating)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Fields

    private var descriptionField: some View {
        TextField(
            mode == .manual ? "What did you work on?" : "What are you working on?",
            text: $draft.description
        )
        .textFieldStyle(.plain)
        .font(Theme.Text.rowTitleEmphasised)
        .focused($isDescriptionFocused)
        .onSubmit { primaryAction() }
        // Written when the field gives up focus rather than on every keystroke: a running timer's
        // description is something you finish typing before you care that it is saved, and a write
        // per character would be a thousand saves for one sentence.
        .onChange(of: isDescriptionFocused) { _, focused in
            guard !focused, running != nil else { return }
            services?.timer.setDescription(draft.description)
            commitChange()
        }
        .accessibilityIdentifier(AccessibilityID.Time.descriptionField)
    }

    private var billableToggle: some View {
        Button {
            draft.isBillable.toggle()
            if running != nil {
                services?.timer.setBillable(draft.isBillable)
                commitChange()
            }
        } label: {
            Image(systemName: draft.isBillable ? "dollarsign.circle.fill" : "dollarsign.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(draft.isBillable ? Theme.Colors.selection : Theme.Colors.secondaryText)
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
        HStack(spacing: Theme.Spacing.tight) {
            DatePicker("From", selection: $manualStart, displayedComponents: [.hourAndMinute, .date])
                .datePickerStyle(.compact)
                .labelsHidden()
                .onChange(of: manualStart) { _, _ in syncDurationDisplay() }

            Text("–")
                .rowForeground(.secondary)

            DatePicker("To", selection: $manualEnd, displayedComponents: [.hourAndMinute, .date])
                .datePickerStyle(.compact)
                .labelsHidden()
                .onChange(of: manualEnd) { _, _ in syncDurationDisplay() }
        }
    }

    private var durationField: some View {
        TextField("0:00:00", text: $durationText)
            .textFieldStyle(.plain)
            .font(.system(.title3, design: .rounded, weight: .medium))
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .frame(width: 88)
            .focused($isDurationFocused)
            .onSubmit(commitDuration)
            .onChange(of: isDurationFocused) { _, focused in
                if focused {
                    // Nothing to type over in manual mode with no span yet, and in timer mode the
                    // live text would be overwritten a second later by the tick.
                    return
                }
                commitDuration()
            }
            .help("Type a length — 1:30, 1.5, or 90m")
            .accessibilityLabel("Duration")
            .accessibilityIdentifier(AccessibilityID.Time.durationField)
    }

    // MARK: - Actions

    private var actionButton: some View {
        Button(action: primaryAction) {
            Label(actionTitle, systemImage: actionSymbol)
                .labelStyle(.iconOnly)
                .frame(width: 20)
        }
        .buttonStyle(.borderedProminent)
        .tint(running == nil ? Theme.Colors.selection : Theme.Colors.destructive)
        .disabled(!canAct)
        .help(actionTitle)
        .accessibilityLabel(actionTitle)
        .accessibilityIdentifier(
            running == nil ? AccessibilityID.Time.startButton : AccessibilityID.Time.stopButton
        )
    }

    private var discardButton: some View {
        Button {
            services?.timer.discard()
            draft = TimeEntryComposition()
            commitChange()
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        // Deliberately quiet next to Stop. Both end the timer and only one keeps the time, so the
        // destructive one must not be the one the eye lands on first.
        .foregroundStyle(Theme.Colors.secondaryText)
        .help("Discard this timer without recording it")
        .accessibilityLabel("Discard timer")
        .accessibilityIdentifier(AccessibilityID.Time.discardButton)
    }

    private var actionTitle: String {
        if running != nil { return "Stop" }
        return mode == .manual ? "Add" : "Start"
    }

    private var actionSymbol: String {
        if running != nil { return "stop.fill" }
        return mode == .manual ? "plus" : "play.fill"
    }

    private var canAct: Bool {
        if running != nil { return true }
        return mode == .timer || manualEnd > manualStart
    }

    private func primaryAction() {
        guard let services else { return }

        if running != nil {
            services.timer.setDescription(draft.description)
            services.timer.stop()
            draft = TimeEntryComposition()
            commitChange()
            return
        }

        switch mode {
        case .timer:
            services.timer.switchTo(
                item: resolvedSubject(),
                description: draft.description,
                tagSlugs: draft.tagSlugs,
                isBillable: draft.isBillable
            )

        case .manual:
            guard manualEnd > manualStart else { return }
            let subject = resolvedSubject()
            services.perform {
                try services.timeEntries.addManual(
                    item: subject,
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

        if running != nil {
            services?.timer.setElapsed(parsed)
            commitChange()
        } else if mode == .manual {
            manualEnd = manualStart.addingTimeInterval(parsed)
        }

        syncDurationDisplay()
    }

    private func commitChange() {
        onChange()
    }

    /// The picked subject as an `Item`, or `nil` for time tracked against nothing.
    ///
    /// The draft holds an id and a title rather than the item itself, because a view cannot safely
    /// keep a `PersistentModel` across a store change. This is where that is turned back into
    /// something the repository can file against, and a lookup that fails means the item was deleted
    /// while the bar was open — in which case tracking against nothing is the right answer, not a
    /// refusal to start.
    private func resolvedSubject() -> Item? {
        guard let services, let subject = draft.subject else { return nil }
        return (try? services.items.item(id: subject.id)) ?? nil
    }

    // MARK: - Draft

    /// Fills the bar from whatever is running, so the fields describe the timer rather than a stale
    /// draft that happens to be sitting in them.
    private func syncFromRunning() {
        if let running {
            draft = TimeEntryComposition(
                description: running.entryDescription,
                subject: running.itemID.map { SubjectReference(id: $0, title: running.itemTitle ?? "Untitled") },
                tagSlugs: running.tagSlugs,
                isBillable: running.isBillable
            )
        } else {
            draft = TimeEntryComposition()
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

        if let elapsed = services?.timer.elapsed, running != nil {
            durationText = TimeFormatting.clock(elapsed)
        } else if mode == .manual {
            durationText = TimeFormatting.clock(max(0, manualEnd.timeIntervalSince(manualStart)))
        } else {
            durationText = TimeFormatting.clock(0)
        }
    }
}

/// The fields an entry shares whether it is timed or typed.
///
/// One value rather than four `@State`s so that clearing the bar, filling it from a running timer,
/// and handing it to a row editor are each one assignment and cannot half-happen.
struct TimeEntryComposition: Equatable {
    var description: String = ""
    var subject: SubjectReference?
    var tagSlugs: [String] = []
    var isBillable: Bool = false
}

/// An item referred to by a picker, without holding the item.
///
/// A `PersistentModel` cannot be held in view state that survives a store change, and none of these
/// surfaces needs more than the two fields it displays.
struct SubjectReference: Equatable, Hashable, Identifiable {
    var id: UUID
    var title: String
}

// MARK: - Pickers

/// What the time is against.
///
/// A popover rather than an always-open field: on the bar it has to sit beside five other controls,
/// and a search field wide enough to be useful would crowd out the description — which is the field
/// that has to be inviting, because it is the one that gets typed into every time.
struct TimeSubjectPicker: View {
    @Environment(\.services) private var services

    let subject: SubjectReference?
    let onPick: (SubjectReference?) -> Void

    /// `nil` on surfaces with nowhere to navigate to, like a row inside a sheet.
    var onOpen: ((UUID) -> Void)?

    @State private var isPresented = false
    @State private var query = ""
    @State private var suggestions: [SubjectReference] = []
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: Theme.Spacing.tight) {
                Image(systemName: subject == nil ? "folder.badge.plus" : "folder.fill")
                if let subject {
                    Text(subject.title)
                        .lineLimit(1)
                        .frame(maxWidth: 140, alignment: .leading)
                }
            }
            .font(Theme.Text.rowSubtitle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(subject == nil ? Theme.Colors.secondaryText : Theme.Colors.selection)
        .help(subject.map { "Against “\($0.title)”" } ?? "Choose what this time is against")
        .accessibilityLabel("Subject")
        .accessibilityValue(subject?.title ?? "none")
        .accessibilityIdentifier(AccessibilityID.Time.subjectPicker)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            TextField("Search tasks, projects, notes…", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .onChange(of: query) { _, text in updateSuggestions(for: text) }

            if let subject {
                Button("Clear “\(subject.title)”", systemImage: "xmark.circle") {
                    onPick(nil)
                    isPresented = false
                }
                .buttonStyle(.link)
                .font(Theme.Text.metadata)

                if let onOpen {
                    Button("Open “\(subject.title)”", systemImage: "arrow.forward.square") {
                        onOpen(subject.id)
                        isPresented = false
                    }
                    .buttonStyle(.link)
                    .font(Theme.Text.metadata)
                }
            }

            if suggestions.isEmpty {
                Text(query.count < 2 ? "Type two letters to search." : "Nothing matches.")
                    .font(Theme.Text.metadata)
                    .rowForeground(.tertiary)
            } else {
                ForEach(suggestions) { suggestion in
                    Button(suggestion.title) {
                        onPick(suggestion)
                        query = ""
                        suggestions = []
                        isPresented = false
                    }
                    .buttonStyle(.link)
                    .font(Theme.Text.rowSubtitle)
                    .lineLimit(1)
                }
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(width: 280)
        .onAppear { isSearchFocused = true }
    }

    private func updateSuggestions(for text: String) {
        guard let services, text.count >= 2 else {
            suggestions = []
            return
        }
        Task {
            let found = await services.search.titleSuggestions(prefix: text, limit: 6)
            guard query == text else { return }
            suggestions = found.map { SubjectReference(id: $0.id, title: $0.title) }
        }
    }
}

/// The tags on an entry.
///
/// Toggl's tag picker is a checklist of what exists plus a field that creates. Both halves earn
/// their place: the checklist is what stops a library growing `admin`, `Admin` and `adminstration`,
/// and the field is what stops the checklist being a wall you have to leave to get past.
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
            HStack(spacing: Theme.Spacing.tight) {
                Image(systemName: slugs.isEmpty ? "tag" : "tag.fill")
                if !slugs.isEmpty {
                    TagChipRow(slugs: slugs, limit: 2)
                }
            }
            .font(Theme.Text.rowSubtitle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(slugs.isEmpty ? Theme.Colors.secondaryText : Theme.Colors.selection)
        .help(slugs.isEmpty ? "Add tags" : "Tagged \(slugs.joined(separator: ", "))")
        .accessibilityLabel("Tags")
        .accessibilityValue(slugs.isEmpty ? "none" : slugs.joined(separator: ", "))
        .accessibilityIdentifier(AccessibilityID.Time.tagPicker)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
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
                    .rowForeground(.tertiary)
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
