import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The contents of the floating timer panel.
///
/// ### Why this is the tracker card's arrangement rather than a new one
/// Because it is the same act. The clock leads, the name is the one field typed into every single
/// time, and everything the entry is filed under is a compact row of chips beneath it — the same
/// order, the same pickers, the same writes. A panel that invented its own layout for the same five
/// things would be a second place to learn, and the two would drift the first time either changed.
///
/// What differs is only what a panel does that a card does not: it has to explain that closing it
/// leaves the clock running, and it has to offer the way out of a shortcut pressed by mistake.
///
/// ### Why there is no Pause here
/// Pause is a thing you do to work already under way, and the floating widget and the Time screen
/// both offer it. This window is open for the twenty seconds after a timer starts; a fourth button
/// competing with Stop and Discard would be one more decision at the moment the whole point is to
/// have made none.
struct QuickLogView: View {
    @Environment(\.services) private var services

    @Bindable var controller: QuickLogController

    /// What the entry is filed under, for the chips to draw. Every change writes straight through to
    /// the running entry — this is what is on screen, not a pending edit.
    @State private var draft = TimeEntryComposition()
    @State private var vocabulary: CaptureVocabulary = .empty
    @State private var caret = 0
    @State private var suggestions: [String] = []
    @State private var suggestionSelection = 0

    @FocusState private var isDescriptionFocused: Bool

    private var running: RunningTimer? { services?.timer.running }

    private var completion: CaptureCompletion? {
        guard let completion = CaptureCompletion.active(
            in: controller.description,
            caretAt: caret
        ) else { return nil }

        switch completion.trigger {
        case .tag, .project, .person:
            return completion
        case .bang, .dueDate, .followDate:
            return nil
        }
    }

    private var suggestionSource: CaptureSuggestionSource {
        CaptureSuggestionSource(services: services, vocabulary: vocabulary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.FloatingCapturePanel.sectionSpacing) {
                if running == nil {
                    stopped
                } else if controller.presentation == .confirmReplacement {
                    replacementConfirmation
                } else {
                    naming
                }
            }
            .padding(Theme.FloatingCapturePanel.outerPadding)
            .background(Theme.FloatingCapturePanel.background)

            Divider()

            footer
                .padding(.horizontal, Theme.FloatingCapturePanel.outerPadding)
                .padding(.vertical, Theme.Spacing.medium)
                .background(Theme.FloatingCapturePanel.groupedBackground)
        }
        .frame(width: 560)
        .background(Theme.FloatingCapturePanel.background)
        .onAppear {
            refreshVocabulary()
            syncFromRunning()
            focusDescriptionIfEditing()
        }
        // The panel is reused rather than rebuilt, so this view outlives any one opening of it. Both
        // the re-sync and the caret have to happen again when it comes back, or the second use of the
        // shortcut shows the first use's filing and lands the caret nowhere.
        .onChange(of: controller.isVisible) { _, visible in
            guard visible else { return }
            syncFromRunning()
            focusDescriptionIfEditing()
        }
        .onChange(of: controller.presentation) { _, _ in focusDescriptionIfEditing() }
        .onChange(of: running?.id) { _, _ in syncFromRunning() }
        .onChange(of: controller.description) { _, _ in applyGrammarPreview() }
        .onChange(of: completion) { _, _ in refreshSuggestions() }
        .task(id: services?.changeToken) {
            refreshVocabulary()
            applyGrammarPreview()
        }
        // Escape is the same as Done rather than a cancel, because there is nothing here to cancel:
        // the clock is already going and the name is already written down. A hidden Escape that
        // discarded an hour would be the worst key on this window.
        .onExitCommand { controller.hide() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Time.quickLog)
    }

    /// The clock identifies this as a timer without making the panel announce its own feature name.
    private var timingBadge: some View {
        HStack(spacing: Theme.Spacing.small) {
            Circle()
                .fill(Theme.Colors.recording)
                .frame(width: 7, height: 7)

            clock
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.FloatingCapturePanel.groupedBackground)
        )
    }

    /// A running clock is a pure function of one stored date and the current moment, so it is drawn
    /// on `TimelineView`'s cadence rather than stored and pushed at — the same reasoning, and the
    /// same fix, as the clock on the tracker card.
    @ViewBuilder
    private var clock: some View {
        if let running {
            TimelineView(.periodic(from: running.startedAt, by: 1)) { context in
                Text(TimeFormatting.stopwatch(running.elapsed(at: context.date)))
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .help("Started at \(running.startedAt.formatted(date: .omitted, time: .shortened))")
            .accessibilityLabel("Elapsed")
        }
    }

    // MARK: - Naming

    /// The name, then what it is filed under. In that order because the name is the field typed into
    /// every time and the chips are the ones usually left alone.
    private var naming: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.medium) {
                CaptureNotesField(
                    text: $controller.description,
                    caret: $caret,
                    vocabulary: vocabulary,
                    placeholder: "Add a description",
                    font: Theme.AppKitText.capturePrimaryInput,
                    isSingleLine: true,
                    onSubmit: { controller.hide() },
                    onCancel: { controller.hide() },
                    onMove: { moveSuggestion($0) },
                    onAccept: { acceptSuggestion() }
                )
                    .frame(height: 26)
                    .focused($isDescriptionFocused)
                    .accessibilityLabel("What are you working on?")
                    .accessibilityIdentifier(AccessibilityID.Time.quickLogDescription)

                timingBadge
            }

            if !suggestions.isEmpty {
                suggestionList
            }

            // Enough air to keep the field calm, without making a one-line timer feel like a
            // document editor. Suggestions still grow the panel naturally when they are present.
            Spacer(minLength: 32)

            CaptureGrammarHints(hints: timerGrammarHints)
        }
        .frame(minHeight: 108)
    }

    private var timerGrammarHints: [(sigil: String, meaning: String, example: String)] {
        Array(CaptureParser.grammarHints.prefix(3))
    }

    private var suggestionList: some View {
        CaptureSuggestionList(
            prefix: completion?.trigger.prefix ?? "",
            suggestions: suggestions,
            selection: suggestionSelection
        ) { index in
            suggestionSelection = index
            acceptSuggestion()
        }
    }

    @discardableResult
    private func moveSuggestion(_ direction: Int) -> Bool {
        guard !suggestions.isEmpty else { return false }
        suggestionSelection = max(
            0,
            min(suggestions.count - 1, suggestionSelection + direction)
        )
        return true
    }

    @discardableResult
    private func acceptSuggestion() -> Bool {
        guard let completion, suggestions.indices.contains(suggestionSelection) else { return false }
        let applied = completion.applying(
            suggestions[suggestionSelection],
            to: controller.description,
            caretAt: caret
        )
        controller.description = applied.text
        caret = applied.caret
        suggestions = []
        return true
    }

    private func refreshSuggestions() {
        guard let completion else {
            suggestions = []
            return
        }

        suggestionSelection = 0
        switch completion.trigger {
        case .tag:
            suggestions = suggestionSource.tagSlugs(matching: completion.query, limit: 6)
        case .project:
            suggestions = suggestionSource.containers(matching: completion.query, limit: 6)
        case .person:
            suggestions = suggestionSource.people(matching: completion.query, limit: 6)
        case .bang, .dueDate, .followDate:
            suggestions = []
        }
    }

    // MARK: - Replacement confirmation

    /// An invocation while another timer is running is a question, not an edit.
    ///
    /// The current entry is rendered from `RunningTimer` and no field is bound to it. This makes the
    /// preservation guarantee visible as well as structural: until the prominent action is chosen,
    /// the name and filing stay exactly as they were.
    private var replacementConfirmation: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                FloatingCapturePanelPrompt(
                    "Timer already running",
                    message: "Stop and save it before starting a new timer?"
                )

                Spacer(minLength: Theme.Spacing.medium)

                timingBadge
            }

            if let running {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                        Text(running.displayTitle)
                            .font(Theme.FloatingCapturePanel.recordTitleFont)
                            .foregroundStyle(Theme.FloatingCapturePanel.primaryText)
                            .lineLimit(2)

                        Spacer(minLength: Theme.Spacing.small)

                        Text("CURRENT")
                            .font(Theme.FloatingCapturePanel.statusFont)
                            .foregroundStyle(Theme.Colors.recording)
                    }

                    if let secondaryDescription = secondaryDescription(for: running) {
                        Text(secondaryDescription)
                            .font(Theme.FloatingCapturePanel.supportingFont)
                            .foregroundStyle(Theme.FloatingCapturePanel.secondaryText)
                            .lineLimit(2)
                    }

                    if let details = filingSummary(for: running) {
                        Text(details)
                            .font(Theme.FloatingCapturePanel.metadataFont)
                            .foregroundStyle(Theme.FloatingCapturePanel.tertiaryText)
                            .lineLimit(2)
                    }
                }
                .padding(Theme.Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(
                        cornerRadius: Theme.FloatingCapturePanel.cornerRadius,
                        style: .continuous
                    )
                        .fill(Theme.FloatingCapturePanel.groupedBackground)
                )
            }
        }
    }

    /// Everything the entry is filed under, as one row.
    ///
    /// The tracker card's chips, unchanged and doing the same writes. A project chosen here is the
    /// same `setProject` a project chosen there is; there is no second path for a picker to fall out
    /// of step along.
    private var filingChips: some View {
        HStack(spacing: Theme.Spacing.tight) {
            TimeSubjectPicker(
                subject: draft.subject,
                onPick: { subject in
                    draft.subject = subject
                    services?.timer.setSubject(resolve(subject))
                }
            )
            .fixedSize(horizontal: true, vertical: false)

            TimeProjectPicker(
                project: draft.project,
                onPick: { project in
                    draft.project = project
                    services?.timer.setProject(resolve(project))
                }
            )
            .fixedSize(horizontal: true, vertical: false)

            TimePeoplePicker(
                people: draft.people,
                onChange: { people in
                    draft.people = people
                    services?.timer.setPeople(people.compactMap { resolve($0) })
                }
            )
            .fixedSize(horizontal: true, vertical: false)

            TimeTagPicker(
                slugs: draft.tagSlugs,
                onChange: { slugs in
                    draft.tagSlugs = slugs
                    services?.timer.setTags(slugs)
                }
            )
            .fixedSize(horizontal: true, vertical: false)

            Button {
                draft.isBillable.toggle()
                services?.timer.setBillable(draft.isBillable)
            } label: {
                TimeChipLabel(symbolName: "dollarsign.circle", title: nil, isFilled: draft.isBillable)
            }
            .buttonStyle(.plain)
            .help(draft.isBillable ? "Billable" : "Not billable")
            .accessibilityLabel("Billable")
            .accessibilityValue(draft.isBillable ? "on" : "off")
        }
    }

    // MARK: - Nothing running

    /// What the panel becomes when the timer it was opened for is stopped somewhere else.
    ///
    /// The menu bar can stop a timer while this window is open, and so can the floating widget.
    /// Leaving the fields on screen would offer edits to an entry that is finished; closing the
    /// window out from under somebody would be the app deciding the conversation is over. So it says
    /// what happened and offers the one thing there is left to do.
    private var stopped: some View {
        HStack(spacing: Theme.Spacing.medium) {
            FloatingCapturePanelPrompt(
                "Nothing is being timed",
                message: "The timer was stopped somewhere else."
            )

            Spacer(minLength: Theme.Spacing.small)

            Button("Start Timing") {
                controller.startTimerIfIdle()
                isDescriptionFocused = true
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(AccessibilityID.Time.quickLogStart)
        }
    }

    // MARK: - Footer

    /// The three exits, and the sentence that stops the first of them being frightening.
    private var footer: some View {
        HStack(spacing: Theme.Spacing.small) {
            if running != nil, controller.presentation == .editing {
                filingChips
            }

            Spacer()

            if running != nil, controller.presentation == .confirmReplacement {
                Button("Keep Timing") { controller.hide() }
                    .keyboardShortcut(.cancelAction)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier(AccessibilityID.Time.quickLogKeep)

                Button("Stop & Start New") {
                    guard controller.replaceRunningTimer() else { return }
                    syncFromRunning()
                    isDescriptionFocused = true
                }
                .buttonStyle(.borderedProminent)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier(AccessibilityID.Time.quickLogReplace)
            } else if running != nil {
                // Quiet, and a long way from Done. It ends the same work Stop does and keeps none of
                // it, so it must not be the button the eye lands on.
                Button("Discard") { controller.discardTimer() }
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Throw this away without recording it")
                    .accessibilityIdentifier(AccessibilityID.Time.quickLogDiscard)

                Button("Stop") { controller.stopTimer() }
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Stop now and keep this time")
                    .accessibilityIdentifier(AccessibilityID.Time.quickLogStop)
            }

            if controller.presentation != .confirmReplacement || running == nil {
                Button("Done") { controller.hide() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Put the panel away. The timer keeps running.")
                    .accessibilityIdentifier(AccessibilityID.Time.quickLogDone)
            }
        }
    }

    // MARK: - Filling in

    /// Fills the chips from whatever is running, so they describe the timer rather than a stale draft
    /// left over from the last time this panel was open.
    private func syncFromRunning() {
        guard let running else {
            draft = TimeEntryComposition()
            return
        }

        draft = TimeEntryComposition(
            description: running.entryDescription,
            subject: running.itemID.map {
                SubjectReference(id: $0, title: running.itemTitle ?? "Untitled")
            },
            project: running.projectID.map {
                SubjectReference(id: $0, title: running.projectTitle ?? "Untitled")
            },
            people: running.people.map { SubjectReference(id: $0.id, title: $0.name) },
            tagSlugs: running.tagSlugs,
            isBillable: running.isBillable
        )
        applyGrammarPreview()
    }

    private func refreshVocabulary() {
        vocabulary = (try? services?.capture.vocabulary()) ?? .empty
        refreshSuggestions()
    }

    /// Shows inline filing immediately, while persistence still waits for an intentional exit.
    private func applyGrammarPreview() {
        guard let running else { return }
        let parsed = CaptureParser.parse(controller.description, knowing: vocabulary)

        var preview = TimeEntryComposition(
            description: running.entryDescription,
            subject: running.itemID.map {
                SubjectReference(id: $0, title: running.itemTitle ?? "Untitled")
            },
            project: running.projectID.map {
                SubjectReference(id: $0, title: running.projectTitle ?? "Untitled")
            },
            people: running.people.map { SubjectReference(id: $0.id, title: $0.name) },
            tagSlugs: running.tagSlugs,
            isBillable: running.isBillable
        )

        for slug in parsed.tagSlugs where !preview.tagSlugs.contains(slug) {
            preview.tagSlugs.append(slug)
        }

        if let hint = parsed.projectHint,
           let project = try? services?.capture.resolveContainer(named: hint) {
            preview.project = SubjectReference(id: project.id, title: project.displayTitle)
        }

        if !parsed.personHints.isEmpty {
            var query = ItemQuery()
            query.kinds = [.person]
            let people = (try? services?.items.items(matching: query)) ?? []
            for hint in parsed.personHints {
                let folded = TextNormalizer.foldedForMatching(hint)
                guard let person = people.first(where: {
                    TextNormalizer.foldedForMatching($0.displayTitle) == folded
                }) else { continue }
                guard !preview.people.contains(where: { $0.id == person.id }) else { continue }
                preview.people.append(SubjectReference(id: person.id, title: person.displayTitle))
            }
        }

        draft = preview
    }

    private func focusDescriptionIfEditing() {
        isDescriptionFocused = controller.presentation == .editing && running != nil
    }

    private func secondaryDescription(for running: RunningTimer) -> String? {
        guard running.itemTitle != nil,
              !running.entryDescription.isEmpty,
              running.entryDescription != running.displayTitle
        else { return nil }
        return running.entryDescription
    }

    private func filingSummary(for running: RunningTimer) -> String? {
        var details: [String] = []
        if let projectTitle = running.projectTitle, !projectTitle.isEmpty {
            details.append(projectTitle)
        }
        if !running.people.isEmpty {
            details.append(running.people.map(\.name).joined(separator: ", "))
        }
        if !running.tagSlugs.isEmpty {
            details.append(running.tagSlugs.map { "#\($0)" }.joined(separator: " "))
        }
        if running.isBillable { details.append("Billable") }
        return details.isEmpty ? nil : details.joined(separator: "  ·  ")
    }

    /// A picked reference as an `Item`, or `nil`.
    ///
    /// The draft holds ids and titles rather than the items themselves, because a view cannot safely
    /// keep a `PersistentModel` across a store change. A lookup that fails means the item was deleted
    /// while the panel was open, in which case filing against nothing is the right answer.
    private func resolve(_ reference: SubjectReference?) -> Item? {
        guard let services, let reference else { return nil }
        return (try? services.items.item(id: reference.id)) ?? nil
    }
}
