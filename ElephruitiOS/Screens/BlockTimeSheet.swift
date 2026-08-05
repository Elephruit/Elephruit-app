import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// What a gap in the day can become.
///
/// ### Why a gap needed an answer at all
/// Today has drawn its free stretches as a dashed thread since the schedule learned about them, and
/// tapping one did nothing. A page that says "you have two hours free" and cannot be asked to do
/// anything with them is a page reporting on somebody's day rather than helping with it.
///
/// Three offers, in the order they are worth: the work already on this page, a block that simply
/// defends the time, and a reminder for a moment inside it. The first is the reason the other two
/// are here — the point is not that the app can write an event, it is that the thing you were
/// already looking at can claim the room it needs.
///
/// ### Nothing here is guessed silently
/// The calendar it lands on, how long it lasts, and whether it defends the time are all shown before
/// the write and all changeable. The length in particular comes from ``TimeBlockRules`` and is
/// *displayed* rather than assumed, because a block written for the wrong length is somebody's
/// afternoon spent wrong.
struct BlockTimeSheet: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    let actions: TodayActions
    let plan: DayPlan

    /// The gap that was tapped, when one was. Absent when the sheet was opened from a task, which
    /// has no opinion about where in the day it goes — the rules find it a place.
    var slot: DayFreeSlot?

    /// The work this block is for, when the sheet already knows. Absent when a gap was tapped and
    /// the question is still open.
    var task: Item?

    /// The lengths a block can be set to, in the units people actually think in.
    private static let standardLengths: [TimeInterval] = [
        15 * 60, 30 * 60, 45 * 60, 60 * 60, 90 * 60, 120 * 60,
    ]

    @State private var proposal: TimeBlockProposal?
    @State private var chosenTask: Item?

    /// What was written, once something was. The sheet becomes its own confirmation rather than
    /// vanishing: a write that disappears the instant it happens is one nobody can undo, and the
    /// page underneath has to rearrange itself around the new event anyway.
    @State private var written: CalendarEventSummary?
    @State private var failure: CalendarWriteFailure?
    @State private var isWorking = false

    /// Whether the third offer — a reminder rather than a block — is the one being answered.
    @State private var isNamingReminder = false
    @State private var reminderTitle = ""
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if let written {
                    confirmation(written)
                } else if isNamingReminder {
                    reminderFields
                } else if let proposal {
                    if slot != nil, task == nil { offers }
                    blockFields(proposal)
                } else {
                    noCalendarToWriteTo
                }

                if let failure {
                    Section {
                        Label(failure.message, systemImage: "exclamationmark.triangle")
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.warning)
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task { prepare() }
            // The calendar answers a beat after the page draws — it is an actor behind a permission
            // — so a sheet opened in that beat would find no calendar to write to and say so
            // permanently. Asked again when the answer arrives, which is the difference between a
            // race and a bug somebody reports as "it says I have no calendars".
            .onChange(of: (services?.calendar.calendars ?? []).count) { _, _ in prepare() }
        }
        // Tall when the gap is still asking what it is for — the offers alone fill a half sheet, and
        // a form nobody can see until they drag the sheet up is a form nobody reads before pressing
        // Add. Half height is right when the answer is already known.
        .presentationDetents(isChoosing ? [.large] : [.medium, .large])
        .accessibilityIdentifier("today.block.sheet")
    }

    // MARK: - What the gap could become

    /// The three offers, longest-fitting work first.
    ///
    /// The work is at the top because it is the only one of the three that could not be had
    /// anywhere else: a focus block and a reminder are both reachable from the plus, and neither
    /// knows what you were looking at when you pressed it.
    @ViewBuilder
    private var offers: some View {
        if let slot {
            let candidates = actions.work(for: slot, in: plan)
            if !candidates.isEmpty {
                Section("Move work into this time") {
                    ForEach(candidates) { candidate in
                        Button {
                            withCalmAnimation(Theme.Motion.standard) {
                                choose(actions.model.task(candidate.id))
                            }
                        } label: {
                            HStack(spacing: Theme.Spacing.small) {
                                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                                    Text(candidate.title)
                                        .font(Theme.Text.rowTitle)
                                        .lineLimit(2)
                                    if let estimate = candidate.estimateMinutes {
                                        // The estimate, and — when it is bigger than the gap — the
                                        // fact that this is a start rather than the whole job.
                                        Text(
                                            candidate.fitsWholly
                                                ? DurationPhrase.exact(TimeInterval(estimate * 60))
                                                : "\(DurationPhrase.exact(TimeInterval(estimate * 60))) · longer than this gap"
                                        )
                                        .font(Theme.Text.metadata)
                                        .foregroundStyle(Theme.Colors.secondaryText)
                                    }
                                }
                                Spacer(minLength: 0)
                                if chosenTask?.id == candidate.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.Colors.selection)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .accessibilityIdentifier("today.block.work")
            }

            Section {
                Button {
                    withCalmAnimation(Theme.Motion.standard) { choose(nil) }
                } label: {
                    HStack {
                        Label("Block this time", systemImage: "shield")
                        Spacer(minLength: 0)
                        if chosenTask == nil {
                            Image(systemName: "checkmark").foregroundStyle(Theme.Colors.selection)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("today.block.focus")

                Button {
                    withCalmAnimation(Theme.Motion.standard) { isNamingReminder = true }
                    isTitleFocused = true
                } label: {
                    Label("Add a reminder", systemImage: "bell")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("today.block.reminder")
            }
        }
    }

    // MARK: - The block itself

    @ViewBuilder
    private func blockFields(_ proposal: TimeBlockProposal) -> some View {
        Section {
            LabeledContent("When", value: proposal.rangeSummary)

            Picker("Length", selection: lengthBinding) {
                ForEach(lengthChoices, id: \.self) { length in
                    Text(DurationPhrase.exact(length)).tag(length)
                }
            }
            .accessibilityIdentifier("today.block.length")

            // Full width and unlabelled on screen. A segmented control drops its title anyway, and
            // "Shows as" beside two words that already read as an answer spends the row saying it
            // twice — the footer below explains what the answer *means*, which is the part nobody
            // can guess. VoiceOver still hears the title.
            Picker("Shows as", selection: availabilityBinding) {
                Text("Free").tag(EventAvailability.free)
                Text("Busy").tag(EventAvailability.busy)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Shows as")
            .accessibilityIdentifier("today.block.availability")

            if let writable = writableCalendars, writable.count > 1 {
                Picker("Calendar", selection: calendarBinding) {
                    ForEach(writable) { info in
                        Text(info.title).tag(info.id)
                    }
                }
                .accessibilityIdentifier("today.block.calendar")
            }
        } header: {
            Text(proposal.title)
        } footer: {
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(
                    proposal.availability == .busy
                        ? "Busy defends the time: other people's scheduling assistants will see it taken."
                        : "Free records the time without turning anything down."
                )

                if let slot, proposal.endAt > slot.range.upperBound {
                    // Allowed, and said out loud. Somebody deliberately taking an hour out of a
                    // forty-minute gap is doing something sensible; somebody doing it by accident
                    // should find out here rather than from the conflict warning afterwards.
                    Text("This runs past the free time, into what is booked after it.")
                }
            }
        }
    }

    /// The state where there is nothing to write to, said before a form is offered rather than
    /// after one has been filled in.
    private var noCalendarToWriteTo: some View {
        Section {
            Label(
                "There is no calendar Elephruit can add to. Turn the calendar on in Settings, or "
                    + "allow access, to block time here.",
                systemImage: "calendar.badge.exclamationmark"
            )
            .font(Theme.Text.rowSubtitle)
            .foregroundStyle(Theme.Colors.secondaryText)
        }
    }

    // MARK: - A reminder instead

    private var reminderFields: some View {
        Section {
            TextField("Remind me to…", text: $reminderTitle)
                .focused($isTitleFocused)
                .submitLabel(.done)
                .onSubmit(addReminder)
                .accessibilityIdentifier("today.block.reminder.title")
        } header: {
            Text(reminderMoment.formatted(date: .omitted, time: .shortened))
        } footer: {
            Text("A reminder, not an appointment. Nothing is added to your calendar.")
        }
    }

    // MARK: - What was written

    /// The receipt, and the way back out of it.
    ///
    /// Undo lives here rather than in a toast that fades, because the block somebody most wants to
    /// remove is the first one they ever wrote, and they will still be reading this when they
    /// realise it went to the wrong calendar.
    private func confirmation(_ event: CalendarEventSummary) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(event.displayTitle)
                    .font(Theme.Text.rowTitle)
                Text(
                    "\(event.startAt.formatted(date: .omitted, time: .shortened))"
                        + " – \(event.endAt.formatted(date: .omitted, time: .shortened))"
                        + (event.calendarName.map { " · \($0)" } ?? "")
                )
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
            }

            Button(role: .destructive) {
                remove(event)
            } label: {
                Label("Remove from calendar", systemImage: "trash")
            }
            .disabled(isWorking)
            .accessibilityIdentifier("today.block.remove")
        } header: {
            Text("Added to your calendar")
        }
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(written == nil ? "Cancel" : "Done") { dismiss() }
                .accessibilityIdentifier("today.block.dismiss")
        }

        ToolbarItem(placement: .confirmationAction) {
            if written == nil {
                if isNamingReminder {
                    Button("Add", action: addReminder)
                        .disabled(reminderTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("today.block.add")
                } else {
                    Button("Add", action: add)
                        .disabled(proposal == nil || isWorking)
                        .accessibilityIdentifier("today.block.add")
                }
            }
        }
    }

    /// Whether the sheet is still offering choices rather than confirming one.
    private var isChoosing: Bool {
        written == nil && !isNamingReminder && slot != nil && task == nil
    }

    private var navigationTitle: String {
        if written != nil { return "Added" }
        if isNamingReminder { return "New Reminder" }
        guard let slot else { return "Block Time" }
        return slot.durationSummary + " free"
    }

    // MARK: - Bindings

    private var writableCalendars: [CalendarInfo]? {
        services?.calendar.calendars.filter(\.allowsModification)
    }

    private var lengthChoices: [TimeInterval] {
        guard let length = proposal?.length, !Self.standardLengths.contains(length) else {
            return Self.standardLengths
        }
        // The proposed length is nearly always an odd one — an estimate, or a gap that stops when
        // the next meeting starts — and it has to be selectable or the picker shows nothing chosen.
        return (Self.standardLengths + [length]).sorted()
    }

    private var lengthBinding: Binding<TimeInterval> {
        Binding(
            get: { proposal?.length ?? TimeBlockRules.fallbackLength },
            set: { proposal?.length = $0 }
        )
    }

    private var availabilityBinding: Binding<EventAvailability> {
        Binding(
            get: { proposal?.availability ?? .busy },
            set: { proposal?.availability = $0 }
        )
    }

    private var calendarBinding: Binding<String> {
        Binding(
            get: { proposal?.calendarIdentifier ?? "" },
            set: { proposal?.calendarIdentifier = $0 }
        )
    }

    private var reminderMoment: Date {
        guard let slot, let services else { return plan.date }
        return TimeBlockRules.start(in: slot, calendar: services.dateProvider.calendar)
    }

    // MARK: - Doing it

    private func prepare() {
        guard proposal == nil, written == nil else { return }
        chosenTask = task
        proposal = actions.proposal(blocking: task, in: slot, on: plan)
    }

    /// Picks what the block is for, keeping the choices already made about it.
    ///
    /// The length and the title follow the work; the calendar and the busy-or-free answer are the
    /// user's and survive changing their mind about which task it is for.
    private func choose(_ task: Item?) {
        chosenTask = task
        guard var rebuilt = actions.proposal(blocking: task, in: slot, on: plan) else { return }
        if let current = proposal {
            rebuilt.calendarIdentifier = current.calendarIdentifier
            rebuilt.availability = current.availability
        }
        proposal = rebuilt
    }

    private func add() {
        guard let proposal else { return }
        isWorking = true
        failure = nil

        Task {
            let outcome = await actions.write(proposal)
            isWorking = false
            switch outcome {
            case .success(let event):
                withCalmAnimation(Theme.Motion.standard) { written = event }
            case .failure(let reason):
                // The sheet stays exactly as it was: a refused write must never eat the answers
                // somebody has just given it.
                failure = reason
            }
        }
    }

    private func remove(_ event: CalendarEventSummary) {
        isWorking = true
        failure = nil

        Task {
            let outcome = await actions.removeBlock(event)
            isWorking = false
            switch outcome {
            case .success: dismiss()
            case .failure(let reason): failure = reason
            }
        }
    }

    private func addReminder() {
        let trimmed = reminderTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        actions.createTask(titled: trimmed, remindingAt: reminderMoment)
        dismiss()
    }
}

/// Development-only launch routing, so the sheet can be photographed on a machine nobody is tapping.
///
/// The same reasoning as `PadReviewLaunch`: a review that cannot *reach* a screen repeatably ends up
/// reporting the previous build's bugs. Six defects in this page so far were caught by looking and
/// by nothing else — a control rendering at zero by zero, a column collapsed by `EmptyView`, a time
/// printed twice — and none of them would have failed a build or a test. A sheet that can only be
/// opened by a thumb is a sheet nobody looks at until it ships.
///
///     -ElephruitTodayBlockSheet [gap | work]
///
/// `gap` — the default — opens it on the day's first free stretch, as a tap on the thread does.
/// `work` opens it on the first piece of unscheduled work, as the swipe action does. They are
/// different sheets and both have to be looked at.
///
/// Inert without `-ElephruitDevelopmentMode`, exactly like the store and fixture switches beside it.
enum TodayReviewLaunch {
    enum BlockSubject: String {
        case gap
        case work
    }

    static func blockSheet(arguments: [String] = ProcessInfo.processInfo.arguments) -> BlockSubject? {
        guard arguments.contains("-ElephruitDevelopmentMode"),
              let index = arguments.firstIndex(of: "-ElephruitTodayBlockSheet")
        else { return nil }

        // The token is optional, and a following switch is not one: `-ElephruitTodayBlockSheet
        // -ElephruitPeopleCount 40` asks for a gap, not for a subject called "-ElephruitPeopleCount".
        let token = arguments.dropFirst(index + 1).first ?? ""
        return BlockSubject(rawValue: token) ?? .gap
    }
}

/// What the sheet was opened about — a gap in the day, or a task looking for one.
///
/// One presentation rather than two, because it is one question. Identifiable so that
/// `sheet(item:)` can carry the subject in, which is the presentation that cannot show a sheet
/// about the wrong thing after a reassembly.
enum BlockTimeSubject: Identifiable {
    case slot(DayFreeSlot, DayPlan)
    case task(Item, DayPlan)

    var id: String {
        switch self {
        case .slot(let slot, _): "slot:\(slot.range.lowerBound.timeIntervalSinceReferenceDate)"
        case .task(let task, _): "task:\(task.id)"
        }
    }

    /// The day it belongs to. Carried rather than assumed to be the anchor: the feed's later days
    /// have gaps of their own, and a block written into Thursday's afternoon from Tuesday's page
    /// must be Thursday's.
    var plan: DayPlan {
        switch self {
        case .slot(_, let plan), .task(_, let plan): plan
        }
    }

    var slot: DayFreeSlot? {
        guard case .slot(let slot, _) = self else { return nil }
        return slot
    }

    var task: Item? {
        guard case .task(let task, _) = self else { return nil }
        return task
    }
}
