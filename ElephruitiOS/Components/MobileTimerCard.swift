import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The tracker, as a phone draws it: one button when nothing is running, and everything about
/// the work once something is.
///
/// ### Why this is the Mac's card rather than a smaller idea
/// The phone had a Start button and a Stop button and nothing else. That is not a simpler time
/// tracker, it is a lossy one: a timer started on the phone could not be named, filed, paused,
/// or thrown away, so every stretch tracked away from the desk arrived in the log as an
/// anonymous block somebody had to reconstruct later — which is the failure that makes people
/// abandon time tracking altogether. The two apps share one store, and an entry started on
/// either has to be able to carry the same facts.
///
/// So this is `ElephruitFeatures/TimeEntryBar.swift`'s argument, laid out for a thumb: two
/// states rather than two modes, the clock as the largest thing on the screen while it runs,
/// and the filing arriving *with* the clock rather than standing in front of it. What differs
/// is arrangement, not capability — a Mac card is a toolbar wide enough to read left to right,
/// and a phone card is three rows, with the destructive and rare commands behind a menu so the
/// two that matter are never aimed at by accident.
struct MobileTimerCard: View {
    @Environment(\.services) private var services

    /// Which filing question is open, as a popover.
    private enum Filing: String, Identifiable {
        case subject, project, people, tags
        var id: String { rawValue }
    }

    @State private var descriptionText = ""
    @State private var preparedFor: UUID?
    @State private var activePopover: Filing?
    /// The same list again as a sheet, once somebody asks to type. See `MobileChoiceList`.
    @State private var searching: Filing?
    @State private var isEditingDuration = false
    @State private var durationText = ""
    @State private var recents: [ContinuableEntry] = []

    @FocusState private var isDescriptionFocused: Bool
    @FocusState private var isDurationFocused: Bool

    private var timer: TimerService? { services?.timer }
    private var running: RunningTimer? { timer?.running }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if let running {
                runningState(running)
            } else {
                idleState
            }
        }
        .padding(.vertical, Theme.Spacing.small)
        .task(id: running?.id) { prepare() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Time.timerBar)
    }

    // MARK: - Nothing running

    /// One button, and the two quiet ways in that are not "begin work now".
    private var idleState: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Button(action: start) {
                HStack(spacing: Theme.Spacing.medium) {
                    Image(systemName: "play.fill")
                        .font(.title3)
                        .frame(width: 52, height: 52)
                        .foregroundStyle(Theme.Colors.onAccent)
                        .background(Circle().fill(Theme.Colors.selection))

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Start a timer")
                            .font(.system(.title3, design: .default, weight: .medium))
                            .foregroundStyle(Theme.Colors.primaryText)
                        Text("Name it once it is running.")
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start a timer")
            .accessibilityIdentifier(AccessibilityID.Time.startButton)

            if let paused = timer?.paused {
                resumeRow(paused)
            }

            if !recents.isEmpty {
                continueMenu
            }
        }
    }

    /// What a pause offers back. Worth its own row rather than a menu item: somebody who paused
    /// five minutes ago is coming back to exactly this, and the accumulated total says the time
    /// already worked was kept.
    private func resumeRow(_ paused: PausedTimer) -> some View {
        Button {
            timer?.resumeFromPause()
            announce()
        } label: {
            HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: "play.circle")
                    .foregroundStyle(Theme.Colors.selection)
                    .frame(width: Theme.Size.rowGlyph)
                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    Text("Resume “\(paused.displayTitle)”")
                        .font(Theme.Text.rowTitle)
                        .lineLimit(1)
                    Text("\(TimeFormatting.spelled(paused.accumulated)) so far")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.Time.resumeButton)
    }

    /// Picking something up again, with its subject, project, people and tags intact.
    ///
    /// Entries rather than subjects, for the reason the Mac's menu bar settled on: continuing an
    /// *entry* keeps the description and the filing, and starting a bare timer against the same
    /// item throws all of it away every time.
    private var continueMenu: some View {
        Menu {
            ForEach(recents) { recent in
                Button(recent.title) { resume(recent.id) }
            }
        } label: {
            HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(width: Theme.Size.rowGlyph)
                Text("Continue something from earlier")
                    .font(Theme.Text.rowTitle)
                    .foregroundStyle(Theme.Colors.primaryText)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier(AccessibilityID.Time.continueMenu)
    }

    // MARK: - Something running

    private func runningState(_ running: RunningTimer) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            descriptionRow
            clockRow(running)
            filingRow(running)

            if let session = timer?.pomodoro {
                Divider()
                focusStrip(session)
            }

            if let finished = timer?.finishedPhase {
                finishedBanner(finished)
            }
        }
    }

    /// What you are doing, typed while the clock runs.
    ///
    /// Written when the field gives up focus rather than on every keystroke — a running timer's
    /// description is something you finish typing before you care that it is saved.
    private var descriptionRow: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "record.circle")
                .foregroundStyle(Theme.Colors.recording)
                .accessibilityHidden(true)

            TextField("What are you working on?", text: $descriptionText)
                .font(.system(.body, design: .default, weight: .regular))
                .focused($isDescriptionFocused)
                .submitLabel(.done)
                .onSubmit { isDescriptionFocused = false }
                .onChange(of: isDescriptionFocused) { _, focused in
                    guard !focused else { return }
                    timer?.setDescription(descriptionText)
                    announce()
                }
                .accessibilityIdentifier(AccessibilityID.Time.descriptionField)
        }
    }

    /// The clock, and the three things that can be done to it.
    ///
    /// ### Why the clock is drawn rather than stored
    /// A running clock is not state: it is a pure function of one stored date and the current
    /// moment. `TimelineView` redraws it on a cadence SwiftUI owns, so it stays right across a
    /// suspension, a missed tick and a clock change — which on a phone is every few minutes
    /// rather than an edge case.
    private func clockRow(_ running: RunningTimer) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            clock(running)
            Spacer(minLength: Theme.Spacing.small)
            pauseButton
            stopButton
            moreMenu
        }
    }

    @ViewBuilder
    private func clock(_ running: RunningTimer) -> some View {
        if isEditingDuration {
            TextField("0:00:00", text: $durationText)
                .font(clockFont)
                .monospacedDigit()
                .keyboardType(.numbersAndPunctuation)
                .frame(maxWidth: 160, alignment: .leading)
                .focused($isDurationFocused)
                .submitLabel(.done)
                .onSubmit(finishEditingDuration)
                .onChange(of: isDurationFocused) { _, focused in
                    guard !focused else { return }
                    finishEditingDuration()
                }
                .accessibilityLabel("Duration")
                .accessibilityHint("Type a length — 1:30, 1.5, or 90m")
                .accessibilityIdentifier(AccessibilityID.Time.durationField)
        } else {
            TimelineView(.periodic(from: running.startedAt, by: 1)) { context in
                Text(TimeFormatting.stopwatch(sittingElapsed(running, at: context.date)))
                    .font(clockFont)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.numericText())
            }
            .contentShape(Rectangle())
            .onTapGesture { beginEditingDuration() }
            .accessibilityLabel("Elapsed")
            .accessibilityHint("Started at \(running.startedAt.formatted(date: .omitted, time: .shortened)). Tap to correct.")
            .accessibilityIdentifier(AccessibilityID.Time.durationField)
        }
    }

    /// Large, rounded, and the biggest thing on the screen while it runs. A stopwatch that has
    /// to be hunted for is one nobody trusts is going.
    private var clockFont: Font {
        .system(size: 34, weight: .medium, design: .rounded)
    }

    private var stopButton: some View {
        Button {
            timer?.setDescription(descriptionText)
            timer?.stop()
            announce()
        } label: {
            Image(systemName: "stop.fill")
                .font(.title3)
                .frame(width: 48, height: 48)
                .foregroundStyle(Theme.Colors.onAccent)
                .background(Circle().fill(Theme.Colors.recording))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop timer")
        .accessibilityIdentifier(AccessibilityID.Time.stopButton)
    }

    /// Stops the entry and keeps the sitting. Beside Stop because the two are asked at the same
    /// moment and mean different things — one says the work is done, the other says it is not.
    private var pauseButton: some View {
        Button {
            timer?.setDescription(descriptionText)
            timer?.pause()
            announce()
        } label: {
            Image(systemName: "pause.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
                .foregroundStyle(Theme.Colors.selection)
                .background(Circle().fill(Theme.Colors.selection.opacity(0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pause timer")
        .accessibilityIdentifier(AccessibilityID.Time.pauseButton)
    }

    /// The rare and the destructive, one tap further away than the two that are neither.
    ///
    /// Discard sits behind a menu rather than beside Stop on purpose: both end the timer and
    /// only one keeps the time, so on a surface aimed at with a thumb they must not be
    /// neighbours.
    private var moreMenu: some View {
        Menu {
            if timer?.isFocusing == true {
                Button("End Focus", systemImage: "brain.head.profile") { timer?.endFocus() }
            } else {
                Button(focusTitle, systemImage: "brain.head.profile") { timer?.startFocus() }
            }

            Button("Start Again From Zero", systemImage: "arrow.counterclockwise") {
                timer?.setDescription(descriptionText)
                timer?.restart()
                announce()
            }

            Divider()

            Button("Discard", systemImage: "trash", role: .destructive) {
                timer?.discard()
                descriptionText = ""
                announce()
            }
            .accessibilityIdentifier(AccessibilityID.Time.discardButton)
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More timer commands")
    }

    /// Says what starting a focus cycle will actually do, in the lengths this person has set.
    private var focusTitle: String {
        let plan = timer?.pomodoroPlan ?? .standard
        let focus = Int((plan.focus / 60).rounded())
        let rest = Int((plan.shortBreak / 60).rounded())
        return "Focus — \(focus) on, \(rest) off"
    }

    // MARK: - Filing

    /// What the entry is filed under, as a scrolling row of chips.
    ///
    /// Only while something runs. These are the questions that can be answered once the clock is
    /// going, and putting them in front of Start is what made beginning to track a form to fill
    /// in. A chip with nothing in it is a glyph; the moment it has a value it shows it.
    private func filingRow(_ running: RunningTimer) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.small) {
                chip(
                    symbolName: "doc.text",
                    title: running.itemTitle,
                    label: "Subject",
                    identifier: AccessibilityID.Time.subjectPicker
                ) { activePopover = .subject }
                    .popover(isPresented: showing(.subject), arrowEdge: .top) {
                        subjectPicker(style: .popover, onRequestSearch: { requestSearch(.subject) })
                    }

                chip(
                    symbolName: "square.stack.3d.up",
                    title: running.projectTitle,
                    label: "Project",
                    identifier: AccessibilityID.Time.projectPicker
                ) { activePopover = .project }
                    .popover(isPresented: showing(.project), arrowEdge: .top) {
                        projectPicker(style: .popover, onRequestSearch: { requestSearch(.project) })
                    }

                chip(
                    symbolName: "person.2",
                    title: peopleSummary(running),
                    label: "People",
                    identifier: AccessibilityID.Time.peoplePicker
                ) { activePopover = .people }
                    .popover(isPresented: showing(.people), arrowEdge: .top) {
                        peoplePicker(style: .popover, onRequestSearch: { requestSearch(.people) })
                    }

                chip(
                    symbolName: "number",
                    title: running.tagSlugs.isEmpty ? nil : running.tagSlugs.joined(separator: " "),
                    label: "Tags",
                    identifier: AccessibilityID.Time.tagPicker
                ) { activePopover = .tags }
                    .popover(isPresented: showing(.tags), arrowEdge: .top) {
                        MobileTagPicker(
                            selected: tagBinding(running),
                            onRequestSearch: { requestSearch(.tags) }
                        )
                    }

                Button {
                    timer?.setBillable(!running.isBillable)
                    announce()
                } label: {
                    chipLabel(
                        symbolName: "dollarsign.circle",
                        title: running.isBillable ? "Billable" : nil,
                        isFilled: running.isBillable
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Billable")
                .accessibilityValue(running.isBillable ? "on" : "off")
                .accessibilityIdentifier(AccessibilityID.Time.billableToggle)
            }
            .padding(.vertical, Theme.Spacing.hairline)
        }
        .scrollIndicators(.hidden)
        .sheet(item: $searching) { filing in
            NavigationStack {
                searchSheet(filing)
            }
        }
    }

    @ViewBuilder
    private func searchSheet(_ filing: Filing) -> some View {
        switch filing {
        case .subject: subjectPicker(style: .search, onRequestSearch: nil)
        case .project: projectPicker(style: .search, onRequestSearch: nil)
        case .people: peoplePicker(style: .search, onRequestSearch: nil)
        case .tags:
            if let running {
                MobileTagPicker(selected: tagBinding(running), style: .search)
            }
        }
    }

    private func chip(
        symbolName: String,
        title: String?,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            chipLabel(symbolName: symbolName, title: title, isFilled: title != nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(title ?? "none")
        .accessibilityIdentifier(identifier)
    }

    private func chipLabel(symbolName: String, title: String?, isFilled: Bool) -> some View {
        HStack(spacing: Theme.Spacing.tight) {
            Image(systemName: symbolName)
            if let title {
                Text(title)
                    .lineLimit(1)
            }
        }
        .font(Theme.Text.chip)
        .foregroundStyle(isFilled ? Theme.Colors.selection : Theme.Colors.secondaryText)
        .padding(.horizontal, Theme.Spacing.small)
        .frame(height: 32)
        .background(
            Capsule().fill(isFilled ? Theme.Colors.selectionFill : Theme.Colors.subtleFill)
        )
        .contentShape(Capsule())
    }

    private func peopleSummary(_ running: RunningTimer) -> String? {
        guard let first = running.people.first else { return nil }
        if running.people.count == 1 { return first.name }
        return "\(first.name) +\(running.people.count - 1)"
    }

    // MARK: - Focus

    /// A cycle under way: which phase, how long is left, and the three commands it has.
    private func focusStrip(_ session: PomodoroSession) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: session.phase.symbolName)
                .foregroundStyle(Theme.Colors.selection)

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(session.phase.displayName)
                    .font(Theme.Text.rowTitle)
                Text(session.roundDescription)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            Spacer(minLength: Theme.Spacing.small)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(TimeFormatting.short(session.remaining(at: context.date)))
                    .font(.system(.title3, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

            Button {
                if session.isPaused { timer?.resumeFocus() } else { timer?.pauseFocus() }
            } label: {
                Image(systemName: session.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.isPaused ? "Resume the cycle" : "Pause the cycle")
            .accessibilityIdentifier(AccessibilityID.Time.focusPause)

            Button {
                timer?.skipFocusPhase()
            } label: {
                Image(systemName: "forward.end.fill")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip this block")
            .accessibilityIdentifier(AccessibilityID.Time.focusSkip)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Time.focusStrip)
    }

    /// A phase that has ended and has not been acknowledged.
    ///
    /// This is the whole of what a finished block can say on a phone: there is no notification
    /// permission, so a suspended app cannot make a sound or post a banner, and the honest thing
    /// is to say what happened when the person comes back rather than to pretend they were told.
    private func finishedBanner(_ phase: PomodoroPhase) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: phase.symbolName)
                .foregroundStyle(Theme.Colors.warning)
            Text(phase.completionMessage)
                .font(Theme.Text.rowSubtitle)
            Spacer(minLength: 0)
            Button("OK") { timer?.acknowledgeFinishedPhase() }
                .font(Theme.Text.metadata)
        }
        .padding(Theme.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Theme.Colors.subtleFill)
        )
        .accessibilityIdentifier(AccessibilityID.Time.focusBanner)
    }

    // MARK: - Pickers

    private func showing(_ filing: Filing) -> Binding<Bool> {
        Binding(
            get: { activePopover == filing },
            set: { if !$0 { activePopover = nil } }
        )
    }

    /// Closes the popup and opens the sheet built for a keyboard. One beat apart, because two
    /// presentations changing places in the same frame is how a sheet arrives with no content.
    private func requestSearch(_ filing: Filing) {
        activePopover = nil
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            searching = filing
        }
    }

    private func subjectPicker(style: MobileChoiceStyle, onRequestSearch: (() -> Void)?) -> some View {
        MobileItemPicker(
            title: "Subject",
            // What time is plausibly tracked against, most recently touched first. A person or a
            // heading is not something an hour is spent *on*, and offering them would make the
            // list longer without making it more useful.
            kinds: [.task, .reminder, .project, .note, .area, .goal],
            selected: running?.itemID,
            style: style,
            onRequestSearch: onRequestSearch,
            onPick: { id in
                timer?.setSubject(id.flatMap { item(id: $0) })
                announce()
            }
        )
    }

    private func projectPicker(style: MobileChoiceStyle, onRequestSearch: (() -> Void)?) -> some View {
        MobileItemPicker(
            title: "Project",
            kinds: [.project],
            selected: running?.projectID,
            style: style,
            onRequestSearch: onRequestSearch,
            onPick: { id in
                timer?.setProject(id.flatMap { item(id: $0) })
                announce()
            }
        )
    }

    private func peoplePicker(style: MobileChoiceStyle, onRequestSearch: (() -> Void)?) -> some View {
        MobileParticipantPicker(
            selected: Set((running?.people ?? []).map(\.id)),
            style: style,
            onRequestSearch: onRequestSearch,
            onPick: { ids in
                timer?.setPeople(ids.compactMap { item(id: $0) })
                announce()
            }
        )
    }

    /// Tags write straight through, because there is no draft to keep: the running entry is the
    /// only place this state lives, and a second copy of it here is a second thing to get wrong.
    private func tagBinding(_ running: RunningTimer) -> Binding<[String]> {
        Binding(
            get: { timer?.running?.tagSlugs ?? running.tagSlugs },
            set: {
                timer?.setTags($0)
                announce()
            }
        )
    }

    private func item(id: UUID) -> Item? {
        guard let services else { return nil }
        return (try? services.items.item(id: id)) ?? nil
    }

    // MARK: - Commands

    /// Starts an untitled timer and puts the caret where the name goes.
    ///
    /// Untitled on purpose: requiring a name before the clock starts is the friction this
    /// arrangement exists to remove.
    private func start() {
        timer?.switchTo(item: nil)
        descriptionText = ""
        preparedFor = timer?.running?.id
        isDescriptionFocused = true
        announce()
    }

    private func resume(_ id: UUID) {
        guard let services, let entry = try? services.timeEntries.entry(id: id) else { return }
        services.timer.resume(entry)
        announce()
    }

    /// What the clock reads: this stretch plus every earlier one in the same sitting, so a
    /// resumed pause does not appear to have started over.
    private func sittingElapsed(_ running: RunningTimer, at now: Date) -> TimeInterval {
        timer?.sittingElapsed(at: now) ?? running.elapsed(at: now)
    }

    private func beginEditingDuration() {
        guard let running else { return }
        durationText = TimeFormatting.clock(running.elapsed(at: Date()))
        isEditingDuration = true
        isDurationFocused = true
    }

    private func finishEditingDuration() {
        if let parsed = DurationParser.parse(durationText) {
            timer?.setElapsed(parsed)
            announce()
        }
        // Unreadable input is simply not applied, rather than left sitting in a control that is
        // about to become a clock again.
        isEditingDuration = false
    }

    /// Tells the screen around this card that the log it is drawing has changed.
    ///
    /// Every command here writes to the store, and the list below is a fetch — a plain call that
    /// SwiftUI has no way of knowing went stale. The Mac card says the same thing through an
    /// `onChange` closure its owner passes in; on the phone the token on `AppServices` reaches
    /// the log, the report and the accessory above the tab bar without threading a closure
    /// through any of them.
    private func announce() {
        services?.noteTimeChange()
    }

    /// Fills the card from whatever is running, so the fields describe the timer rather than a
    /// stale draft that happens to be sitting in them.
    private func prepare() {
        let identifier = running?.id
        guard preparedFor != identifier else { return }
        preparedFor = identifier
        descriptionText = running?.entryDescription ?? ""
        isEditingDuration = false
        loadRecents()
    }

    private func loadRecents() {
        guard running == nil, let services else {
            recents = []
            return
        }
        let entries = (try? services.timeEntries.recentEntries(limit: 12)) ?? []

        // Deduplicated by what a continued timer would actually *be* — the subject and the
        // description together — rather than by subject: two stretches of one task with different
        // descriptions are two different things to carry on with.
        var seen = Set<String>()
        var continuable: [ContinuableEntry] = []
        for entry in entries {
            let title = entry.item?.displayTitle ?? entry.entryDescription
            guard !title.isEmpty else { continue }
            let key = "\(entry.item?.id.uuidString ?? "")\u{1f}\(entry.entryDescription)"
            guard seen.insert(key).inserted else { continue }
            continuable.append(ContinuableEntry(id: entry.id, title: title))
            if continuable.count == 5 { break }
        }
        recents = continuable
    }
}

/// Something worth picking up again, reduced to what the menu needs.
private struct ContinuableEntry: Identifiable, Hashable {
    let id: UUID
    let title: String
}

// MARK: - Item pickers keyed by identity

/// One item, chosen by identity rather than by name.
///
/// ### Why not the composer's pickers
/// `MobileProjectPicker` and `MobilePeoplePicker` carry *titles*, because the reminder draft they
/// serve resolves names at save time. A timer has no save time — every pick writes to the running
/// entry immediately — so a title would have to be resolved back to an item on the spot, and two
/// projects called "Website" would resolve to whichever came first. These carry the id.
struct MobileItemPicker: View {
    @Environment(\.services) private var services

    let title: String
    let kinds: [ItemKind]
    let selected: UUID?
    var style: MobileChoiceStyle = .popover
    var onRequestSearch: (() -> Void)?
    let onPick: (UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var choices: [MobileChoice] = []

    var body: some View {
        MobileChoiceList(
            title: title,
            choices: choices,
            allowsMultiple: false,
            selection: Set([selected?.uuidString].compactMap { $0 }),
            onToggle: { choice in
                let picked = UUID(uuidString: choice.id)
                onPick(picked == selected ? nil : picked)
                if style == .popover { dismiss() }
            },
            onClear: {
                onPick(nil)
                dismiss()
            },
            style: style,
            onRequestSearch: onRequestSearch
        )
        .task { load() }
    }

    private func load() {
        guard let services else { return }
        var query = ItemQuery()
        query.kinds = Set(kinds)
        query.sort = .updatedNewestFirst
        // Bounded, because this list is read once into values and then matched as plain strings:
        // the cost of a longer one is paid on arrival rather than per keystroke, and nobody
        // scrolls past two hundred rows to find what they were doing this morning.
        query.limit = 200

        choices = ((try? services.items.items(matching: query)) ?? []).map {
            MobileChoice(
                id: $0.id.uuidString,
                title: $0.displayTitle,
                symbolName: $0.effectiveSymbolName,
                colorName: $0.colorName
            )
        }
    }
}

/// Who was there, chosen by identity.
struct MobileParticipantPicker: View {
    @Environment(\.services) private var services

    let selected: Set<UUID>
    var style: MobileChoiceStyle = .popover
    var onRequestSearch: (() -> Void)?
    let onPick: ([UUID]) -> Void

    @State private var choices: [MobileChoice] = []

    var body: some View {
        MobileChoiceList(
            title: "People",
            choices: choices,
            allowsMultiple: true,
            selection: Set(selected.map(\.uuidString)),
            onToggle: { choice in
                guard let id = UUID(uuidString: choice.id) else { return }
                var next = selected
                if next.contains(id) { next.remove(id) } else { next.insert(id) }
                // Ordered by the list rather than by the set, so the chip does not reshuffle the
                // names every time one is added.
                onPick(choices.compactMap { UUID(uuidString: $0.id) }.filter { next.contains($0) })
            },
            onClear: { onPick([]) },
            style: style,
            onRequestSearch: onRequestSearch
        )
        .task {
            choices = ((try? services?.records.allRecords()) ?? []).map {
                MobileChoice(
                    id: $0.id.uuidString,
                    title: $0.displayTitle,
                    symbolName: $0.effectiveSymbolName,
                    colorName: $0.colorName
                )
            }
        }
    }
}
