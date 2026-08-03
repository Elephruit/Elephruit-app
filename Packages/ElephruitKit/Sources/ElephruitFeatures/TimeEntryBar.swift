import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// The tracker: one button when nothing is running, and everything about the work once something is.
///
/// ### Why there is no longer a mode
/// There was: a *Timer* mode and a *Manual* mode, switched by a menu, sharing one set of fields. It
/// read as two equally likely things to be doing, and it made both worse. A timer had to be composed
/// before it could be started — a description, four pickers and, if the mode had been left on
/// Manual, a pair of date fields — so the fastest way to begin tracking was to fill in a form about
/// work you had not done yet. That is backwards for the one feature that matters here, which is
/// starting a timer *before* you know what to call the thing.
///
/// So the surface has two states rather than two modes, and they are not equals:
///
/// - **Nothing running.** One button. It says Start, it is the size of a thing you press without
///   aiming, and nothing competes with it. Beside it sit the two quiet ways in that are not "begin
///   work now": continuing something from earlier, and adding time by hand.
/// - **Something running.** The clock is the largest thing on the screen and the description field
///   takes focus by itself, because *now* is when you know what to call it. The filing chips arrive
///   with it: what it is against, whose time it was, how it is tagged.
///
/// Filling in details while the clock runs writes straight to the running entry, so nothing is lost
/// by starting first — which is the whole point.
///
/// Adding time by hand is a sheet, deliberately. It is a correction, it is done rarely, and giving
/// it a permanent third of the tracker taught everybody who opened this screen that guessing at
/// yesterday is as normal as measuring today.
struct TimeTrackerCard: View {
    @Environment(\.services) private var services

    /// Told rather than asked, so the view that owns the list can reload when this card writes.
    let onChange: () -> Void
    let onOpenSubject: (UUID) -> Void

    /// Opens the sheet for time already spent. Owned by the Time view, because the toolbar opens it
    /// too — a sheet two controls can present cannot live inside one of them.
    let onAddManually: () -> Void

    @State private var draft = TimeEntryComposition()
    @State private var durationText = ""
    @State private var isEditingDuration = false
    @State private var recentEntries: [RecentEntry] = []

    @FocusState private var isDescriptionFocused: Bool
    @FocusState private var isDurationFocused: Bool

    private var running: RunningTimer? { services?.timer.running }
    private var isRunning: Bool { running != nil }

    var body: some View {
        Group {
            if let running {
                runningState(running)
            } else {
                idleState
            }
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Theme.Colors.contentBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(isRunning ? Theme.Colors.recording.opacity(0.4) : Theme.Colors.separator)
        }
        .calmAnimation(value: isRunning)
        .onAppear {
            syncFromRunning()
            loadRecents()
        }
        .onChange(of: running?.id) { _, _ in
            syncFromRunning()
            loadRecents()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Time.timerBar)
    }

    // MARK: - Nothing running

    /// One button, and two quiet doors that are not it.
    ///
    /// The subtitle is the instruction that replaces the whole composing step: you do not have to
    /// know what this is yet.
    private var idleState: some View {
        HStack(spacing: Theme.Spacing.large) {
            Button(action: start) {
                HStack(spacing: Theme.Spacing.large) {
                    Image(systemName: "play.fill")
                        .font(.title2)
                        .frame(width: 52, height: 52)
                        .foregroundStyle(Theme.Colors.onAccent)
                        .background(Circle().fill(Theme.Colors.selection))

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Start a timer")
                            .font(.system(.title3, design: .default, weight: .medium))

                        Text("Name it once it is running. Nothing has to be decided first.")
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                }
                // A labelled control owns the transparent spacing between its icon and words. If
                // the pointer can land inside the visual unit, the click must activate the unit.
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Start timing now")
            .accessibilityLabel("Start a timer")
            .accessibilityIdentifier(AccessibilityID.Time.startButton)

            Spacer(minLength: Theme.Spacing.small)

            secondaryWays
        }
    }

    /// Continuing, and adding by hand. Both quiet, and both a long way from the accent circle.
    @ViewBuilder
    private var secondaryWays: some View {
        if !recentEntries.isEmpty {
            Menu {
                ForEach(recentEntries) { recent in
                    Button(recent.title) { resume(recent.id) }
                }
            } label: {
                Label("Continue", systemImage: "arrow.clockwise")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(Theme.Text.rowSubtitle)
            .help("Pick up something from earlier, with its subject and tags intact")
        }

        Button(action: onAddManually) {
            Label("Add by Hand", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .font(Theme.Text.rowSubtitle)
        .help("Record time you have already spent")
        .accessibilityIdentifier(AccessibilityID.Time.addEntryButton)
    }

    // MARK: - Something running

    /// The clock leads, then what you are doing, then what it is filed under.
    private func runningState(_ running: RunningTimer) -> some View {
        // ### The arrangement, and why it is this one
        // The description takes the whole left because it is the only field typed into every single
        // time. Everything it is filed under is a compact cluster of glyphs immediately left of the
        // clock — a toolbar, read as a toolbar — rather than a row of labelled capsules under the
        // text, which pushed the card to two storeys and made five optional things look like five
        // required ones. A glyph with nothing in it is just a glyph; the moment it has a value it
        // takes that value's colour and shows it.
        HStack(alignment: .center, spacing: Theme.Spacing.medium) {
            Image(systemName: "record.circle")
                .font(.title3)
                .foregroundStyle(Theme.Colors.recording)
                .accessibilityHidden(true)

            TextField("Add a description", text: $draft.description)
                .textFieldStyle(.plain)
                .font(.system(.title3, design: .default, weight: .regular))
                .focused($isDescriptionFocused)
                .onSubmit { isDescriptionFocused = false }
                // Written when the field gives up focus rather than on every keystroke: a running
                // timer's description is something you finish typing before you care that it is
                // saved, and a write per character is a thousand saves per sentence.
                .onChange(of: isDescriptionFocused) { _, focused in
                    guard !focused else { return }
                    services?.timer.setDescription(draft.description)
                    commitChange()
                }
                .accessibilityIdentifier(AccessibilityID.Time.descriptionField)

            Spacer(minLength: Theme.Spacing.small)

            filingChips

            Divider()
                .frame(height: 24)

            clock(running)

            focusButton
            stopButton
            discardButton
        }
    }

    /// Everything the entry is filed under, as one cluster.
    ///
    /// Only while something runs. These are the questions you can answer once the clock is going,
    /// and putting them in front of Start was what made beginning to track a form to fill in.
    private var filingChips: some View {
        HStack(spacing: Theme.Spacing.tight) {
            TimeSubjectPicker(
                subject: draft.subject,
                onPick: { subject in
                    draft.subject = subject
                    services?.timer.setSubject(resolve(draft.subject))
                    commitChange()
                },
                onOpen: onOpenSubject
            )

            TimeProjectPicker(project: draft.project) { project in
                draft.project = project
                services?.timer.setProject(resolve(draft.project))
                commitChange()
            }

            TimePeoplePicker(people: draft.people) { people in
                draft.people = people
                services?.timer.setPeople(resolveAll(draft.people))
                commitChange()
            }

            TimeTagPicker(slugs: draft.tagSlugs) { slugs in
                draft.tagSlugs = slugs
                services?.timer.setTags(slugs)
                commitChange()
            }

            Button {
                draft.isBillable.toggle()
                services?.timer.setBillable(draft.isBillable)
                commitChange()
            } label: {
                TimeChipLabel(
                    symbolName: "dollarsign.circle",
                    title: nil,
                    isFilled: draft.isBillable
                )
            }
            .buttonStyle(.plain)
            .help(draft.isBillable ? "Billable" : "Not billable")
            .accessibilityLabel("Billable")
            .accessibilityValue(draft.isBillable ? "on" : "off")
            .accessibilityIdentifier(AccessibilityID.Time.billableToggle)
        }
    }

    // MARK: - The clock

    /// The elapsed time, and the field it becomes when you click it.
    ///
    /// ### Why a running clock is drawn rather than stored
    /// It used to be a `TextField` bound to `@State`, which made what you see a downstream
    /// consequence of a tick arriving *and* of the view being invalidated by it. Both are true most
    /// of the time and neither is guaranteed; the observed result was a clock that sat still for
    /// fifteen seconds and then jumped.
    ///
    /// A running clock is not state. It is a pure function of one stored date and the current
    /// moment, so `TimelineView` asks SwiftUI to redraw on a cadence it owns and each redraw
    /// computes the elapsed time from `startedAt`. Nothing is left to fall out of step, and it stays
    /// right across a sleep, a missed tick, and a clock change.
    ///
    /// It becomes a field on click, because typing a length into it is the correction this whole
    /// module is built around — see ``ElephruitCore/DurationParser``.
    @ViewBuilder
    private func clock(_ running: RunningTimer) -> some View {
        if isEditingDuration {
            TextField("0:00:00", text: $durationText)
                .textFieldStyle(.plain)
                .font(clockFont)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 128)
                .focused($isDurationFocused)
                .onSubmit(finishEditingDuration)
                .onChange(of: isDurationFocused) { _, focused in
                    guard !focused else { return }
                    finishEditingDuration()
                }
                .help("Type a length — 1:30, 1.5, or 90m")
                .accessibilityLabel("Duration")
                .accessibilityIdentifier(AccessibilityID.Time.durationField)
        } else {
            TimelineView(.periodic(from: running.startedAt, by: 1)) { context in
                Text(TimeFormatting.stopwatch(running.elapsed(at: context.date)))
                    .font(clockFont)
                    .monospacedDigit()
                    .lineLimit(1)
                    // The width is a floor, not a ceiling. Fixed at 128 this wrapped once a timer
                    // crossed ten hours — "23:17:0" over a lone "6" — because a frame narrower
                    // than the digits does not shrink them, it folds them.
                    .fixedSize()
                    .contentTransition(.numericText())
            }
            .frame(minWidth: 128, alignment: .trailing)
            .contentShape(.rect)
            .onTapGesture { beginEditingDuration() }
            .help("Started at \(running.startedAt.formatted(date: .omitted, time: .shortened)) — click to correct")
            .accessibilityLabel("Elapsed")
            .accessibilityIdentifier(AccessibilityID.Time.durationField)
        }
    }

    /// Large, rounded, and the biggest thing on the screen while it runs.
    ///
    /// A stopwatch that has to be hunted for is one nobody trusts is going. This is the single piece
    /// of the interface that answers the question the whole module exists for.
    private var clockFont: Font {
        .system(size: 30, weight: .medium, design: .rounded)
    }

    // MARK: - Buttons

    private var stopButton: some View {
        Button(action: stop) {
            Image(systemName: "stop.fill")
                .font(.title3)
                .frame(width: 40, height: 40)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.Colors.onAccent)
        .background(Circle().fill(Theme.Colors.recording))
        .help("Stop and keep this time")
        .accessibilityLabel("Stop")
        .accessibilityIdentifier(AccessibilityID.Time.stopButton)
    }

    /// Starts a focus cycle over whatever is being tracked.
    ///
    /// A labelled pill rather than an icon. It was a bare `brain.head.profile` glyph between the
    /// clock and Stop, at the same weight as the discard cross, and the first person to use it could
    /// not find the pomodoro at all. An unlabelled icon among unlabelled icons is not discovered; it
    /// is explained. The word costs forty points and removes the need to explain.
    @ViewBuilder
    private var focusButton: some View {
        if services?.timer.isFocusing != true {
            Button {
                services?.timer.startFocus()
                commitChange()
            } label: {
                HStack(spacing: Theme.Spacing.tight) {
                    Image(systemName: "brain.head.profile")
                    Text("Focus")
                }
                .font(Theme.Text.rowSubtitle)
                .padding(.horizontal, Theme.Spacing.medium)
                .frame(height: 30)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.selection)
            .background(Capsule().fill(Theme.Colors.selection.opacity(0.12)))
            .help(focusHint)
            .accessibilityLabel("Work in focus blocks")
            .accessibilityIdentifier(AccessibilityID.Time.focusButton)
        }
    }

    /// Says what pressing Focus will actually do, in the lengths this person has set.
    private var focusHint: String {
        let plan = services?.timer.pomodoroPlan ?? .standard
        let focus = Int((plan.focus / 60).rounded())
        let rest = Int((plan.shortBreak / 60).rounded())
        return "Work in \(focus)-minute blocks with \(rest)-minute breaks"
    }

    private var discardButton: some View {
        Button {
            services?.timer.discard()
            draft = TimeEntryComposition()
            commitChange()
        } label: {
            Image(systemName: "xmark")
                .font(Theme.Text.rowSubtitle)
                .frame(width: 26, height: 26)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Deliberately quiet next to Stop. Both end the timer and only one keeps the time, so the
        // destructive one must not be the one the eye lands on first.
        .foregroundStyle(Theme.Colors.secondaryText)
        .help("Throw this away without recording it")
        .accessibilityLabel("Discard timer")
        .accessibilityIdentifier(AccessibilityID.Time.discardButton)
    }

    // MARK: - Commands

    /// Starts an untitled timer, and puts the caret where the name goes.
    ///
    /// Untitled on purpose. Requiring a name before the clock starts is the friction this whole
    /// arrangement exists to remove, and the caret landing in the description means naming it is the
    /// obvious next thing rather than a thing to remember.
    private func start() {
        services?.timer.switchTo(item: nil)
        draft = TimeEntryComposition()
        commitChange()
        isDescriptionFocused = true
    }

    private func stop() {
        guard let services else { return }
        services.timer.setDescription(draft.description)
        services.timer.stop()
        draft = TimeEntryComposition()
        commitChange()
    }

    private func resume(_ id: UUID) {
        guard let services, let entry = try? services.timeEntries.entry(id: id) else { return }
        services.timer.resume(entry)
        commitChange()
    }

    private func beginEditingDuration() {
        syncDurationDisplay()
        isEditingDuration = true
        isDurationFocused = true
    }

    private func finishEditingDuration() {
        if let parsed = DurationParser.parse(durationText) {
            services?.timer.setElapsed(parsed)
            commitChange()
        }
        // Unreadable input is simply not applied. What was typed is dropped rather than left sitting
        // in a control that is about to become a clock again — a stopwatch reading "banana" is worse
        // than one that quietly refused.
        isEditingDuration = false
    }

    private func commitChange() {
        onChange()
    }

    // MARK: - Resolving

    /// A picked reference as an `Item`, or `nil`.
    ///
    /// The draft holds ids and titles rather than the items themselves, because a view cannot safely
    /// keep a `PersistentModel` across a store change. A lookup that fails means the item was
    /// deleted while the card was open — in which case tracking against nothing is the right answer,
    /// not a refusal.
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
        } else {
            draft = TimeEntryComposition()
        }
        isEditingDuration = false
        syncDurationDisplay()
    }

    private func syncDurationDisplay() {
        guard let running else {
            durationText = ""
            return
        }
        // Read straight off the start date rather than from the service's `elapsed`, so what lands
        // in the field when it is clicked is the number the clock beside it was showing — not
        // whatever the last tick happened to leave behind.
        durationText = TimeFormatting.clock(running.elapsed(at: Date()))
    }

    /// A few things worth carrying on with, deduplicated by what a continued timer would be.
    ///
    /// Two entries against one task with different descriptions are two different things to pick up,
    /// so the key is both. Entries with nothing to call them are skipped — a menu of three identical
    /// blank lines helps nobody.
    private func loadRecents() {
        guard let services, let recent = try? services.timeEntries.recentEntries(limit: 12) else {
            recentEntries = []
            return
        }

        var seen = Set<String>()
        var found: [RecentEntry] = []

        for entry in recent {
            let title = entry.item?.displayTitle ?? entry.entryDescription
            guard !title.isEmpty else { continue }

            let key = "\(entry.item?.id.uuidString ?? "")\u{1f}\(entry.entryDescription)"
            guard seen.insert(key).inserted else { continue }

            found.append(RecentEntry(id: entry.id, title: title))
            if found.count == 5 { break }
        }
        recentEntries = found
    }
}

/// Something worth carrying on with, as the Continue menu sees it.
struct RecentEntry: Identifiable, Hashable {
    let id: UUID
    let title: String
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
