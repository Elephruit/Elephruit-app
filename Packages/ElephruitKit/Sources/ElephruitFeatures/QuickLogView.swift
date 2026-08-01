import ElephruitCore
import ElephruitDesign
import ElephruitModel
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

    @FocusState private var isDescriptionFocused: Bool

    private var running: RunningTimer? { services?.timer.running }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            header

            if running == nil {
                stopped
            } else {
                naming
            }

            Divider()

            footer
        }
        .padding(Theme.Spacing.large)
        .frame(width: 480)
        .background(.regularMaterial)
        .onAppear {
            syncFromRunning()
            isDescriptionFocused = true
        }
        // The panel is reused rather than rebuilt, so this view outlives any one opening of it. Both
        // the re-sync and the caret have to happen again when it comes back, or the second use of the
        // shortcut shows the first use's filing and lands the caret nowhere.
        .onChange(of: controller.isVisible) { _, visible in
            guard visible else { return }
            syncFromRunning()
            isDescriptionFocused = true
        }
        .onChange(of: running?.id) { _, _ in syncFromRunning() }
        // Escape is the same as Done rather than a cancel, because there is nothing here to cancel:
        // the clock is already going and the name is already written down. A hidden Escape that
        // discarded an hour would be the worst key on this window.
        .onExitCommand { controller.hide() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Time.quickLog)
    }

    // MARK: - Header

    /// What this is, and — the part that matters — the clock proving it is already going.
    private var header: some View {
        HStack(spacing: Theme.Spacing.small) {
            Label(headline, systemImage: "record.circle")
                .font(.system(.headline, design: .default, weight: .medium))
                .foregroundStyle(running == nil ? Theme.Colors.secondaryText : Theme.Colors.destructive)
                .symbolEffect(.pulse, options: running == nil ? .nonRepeating : .repeating)

            Spacer(minLength: Theme.Spacing.small)

            clock
        }
    }

    /// Which of the three things just happened.
    ///
    /// *Already timing* is not a pedantic distinction from *Timing now*. Somebody who pressed the
    /// shortcut expecting to begin something needs to know that they did not — that this window is
    /// about work that was already under way, and that typing a name into it renames that work rather
    /// than describing something new. Saying "Timing now" over an adopted entry would be the window
    /// taking credit for a clock it did not start.
    private var headline: String {
        guard running != nil else { return "Not timing" }
        return controller.startedTheTimer ? "Timing now" : "Already timing"
    }

    /// A running clock is a pure function of one stored date and the current moment, so it is drawn
    /// on `TimelineView`'s cadence rather than stored and pushed at — the same reasoning, and the
    /// same fix, as the clock on the tracker card.
    @ViewBuilder
    private var clock: some View {
        if let running {
            TimelineView(.periodic(from: running.startedAt, by: 1)) { context in
                Text(TimeFormatting.stopwatch(running.elapsed(at: context.date)))
                    .font(.system(size: 24, weight: .medium, design: .rounded))
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
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            TextField("What are you working on?", text: $controller.description)
                .textFieldStyle(.plain)
                .font(.system(.title3, design: .default, weight: .regular))
                .focused($isDescriptionFocused)
                .onSubmit { controller.hide() }
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.vertical, Theme.Spacing.small)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .fill(Theme.Colors.contentBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .strokeBorder(Theme.Colors.separator)
                )
                .accessibilityLabel("What are you working on?")
                .accessibilityIdentifier(AccessibilityID.Time.quickLogDescription)

            filingChips
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

            TimeProjectPicker(
                project: draft.project,
                onPick: { project in
                    draft.project = project
                    services?.timer.setProject(resolve(project))
                }
            )

            TimePeoplePicker(
                people: draft.people,
                onChange: { people in
                    draft.people = people
                    services?.timer.setPeople(people.compactMap { resolve($0) })
                }
            )

            TimeTagPicker(
                slugs: draft.tagSlugs,
                onChange: { slugs in
                    draft.tagSlugs = slugs
                    services?.timer.setTags(slugs)
                }
            )

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

            Spacer(minLength: 0)
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
            VStack(alignment: .leading, spacing: 1) {
                Text("Nothing is being timed")
                    .font(.system(.title3, design: .default, weight: .medium))

                Text("The timer was stopped somewhere else.")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

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
            Text(running == nil ? "" : "Closing keeps it running.")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)

            Spacer()

            if running != nil {
                // Quiet, and a long way from Done. It ends the same work Stop does and keeps none of
                // it, so it must not be the button the eye lands on.
                Button("Discard") { controller.discardTimer() }
                    .help("Throw this away without recording it")
                    .accessibilityIdentifier(AccessibilityID.Time.quickLogDiscard)

                Button("Stop") { controller.stopTimer() }
                    .help("Stop now and keep this time")
                    .accessibilityIdentifier(AccessibilityID.Time.quickLogStop)
            }

            Button("Done") { controller.hide() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .help("Put the panel away. The timer keeps running.")
                .accessibilityIdentifier(AccessibilityID.Time.quickLogDone)
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
