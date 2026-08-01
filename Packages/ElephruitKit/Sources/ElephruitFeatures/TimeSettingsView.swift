import ElephruitCore
import ElephruitDesign
import SwiftUI

/// Everything about tracked time that is a preference rather than a record.
///
/// Three groups, and the order is the order somebody meets them: how the timer behaves, how focus
/// blocks are shaped, and whether any of it is copied into a calendar. The last is last because it
/// is the only one that writes outside this app, and it says so before it offers a switch.
public struct TimeSettingsSection: View {
    @Environment(\.services) private var services

    @AppStorage("time.rounding") private var storedRounding = TimeRounding.exact.rawValue
    @AppStorage("time.dayTargetHours") private var dayTargetHours = 0.0
    @AppStorage("time.defaultsToBillable") private var defaultsToBillable = false
    @AppStorage("time.groupsSimilarEntries") private var groupsSimilarEntries = true
    @AppStorage("time.pomodoro.sound") private var playsFocusSound = true

    @State private var plan = PomodoroPlan.standard
    @State private var mirrorMessage: String?

    public init() {}

    public var body: some View {
        tracking
        focus
        mirroring
    }

    // MARK: - Tracking

    @ViewBuilder
    private var tracking: some View {
        Section {
            Toggle("Collapse alike entries in the log", isOn: $groupsSimilarEntries)
                .help("Eight goes at one task become one row you can open")

            Toggle("New entries are billable", isOn: $defaultsToBillable)
                .help("For work that is billable more often than not")

            Picker("Round totals", selection: roundingBinding) {
                ForEach(TimeRounding.allCases, id: \.self) { rule in
                    Text(rule.displayName).tag(rule)
                }
            }

            LabeledContent("A working day is") {
                HStack(spacing: Theme.Spacing.tight) {
                    TextField(
                        "None",
                        value: $dayTargetHours,
                        format: .number.precision(.fractionLength(0...2))
                    )
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)

                    Text("hours")
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }
        } header: {
            Text("Tracking")
        } footer: {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text("Rounding changes what a report and an export say. It never changes a recorded entry — an hour that ran for fifty-one minutes stays fifty-one minutes, because that is the only number that could ever settle a dispute.")

                Text(dayTargetHours > 0
                    ? "A progress bar towards \(TimeFormatting.spelled(dayTargetHours * 3_600)) appears above today's log."
                    : "Leave this at zero for no progress bar. Nobody should be shown progress towards a number they never set.")
            }
            .font(Theme.Text.metadata)
            .foregroundStyle(Theme.Colors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Focus

    @ViewBuilder
    private var focus: some View {
        Section {
            PhaseLengthField(title: "Focus block", minutes: minutesBinding(\.focus))
            PhaseLengthField(title: "Short break", minutes: minutesBinding(\.shortBreak))
            PhaseLengthField(title: "Long break", minutes: minutesBinding(\.longBreak))

            Stepper(
                "Long break after \(plan.roundsBeforeLongBreak) blocks",
                value: roundsBinding,
                in: 1...12
            )

            Toggle("Start breaks automatically", isOn: planBinding(\.startsBreaksAutomatically))
            Toggle("Start the next block automatically", isOn: planBinding(\.startsNextFocusAutomatically))
            Toggle("Make a sound when a phase ends", isOn: $playsFocusSound)
                .onChange(of: playsFocusSound) { _, newValue in
                    services?.timer.playsPomodoroSound = newValue
                }
        } header: {
            Text("Focus Blocks")
        } footer: {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text("A full set takes \(TimeFormatting.spelled(plan.setLength)).")

                Text("Breaks start themselves by default and work does not, on purpose. An ignored break costs nothing; work that starts by itself begins a timer against your name while you are still in the kitchen, and writes an entry you have to find and correct later.")

                Text("The end of a phase makes a sound and bounces the icon. Elephruit does not post notifications — that needs a permission this app has never asked for, and asking for it deserves its own explanation rather than arriving with a focus timer.")
            }
            .font(Theme.Text.metadata)
            .foregroundStyle(Theme.Colors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .task { plan = services?.storedPomodoroPlan ?? .standard }
    }

    // MARK: - Mirroring

    @ViewBuilder
    private var mirroring: some View {
        Section {
            if let services, services.calendar.isEnabled {
                Toggle("Write finished time to a calendar", isOn: mirrorEnabledBinding)

                if services.timeMirror.policy.isEnabled {
                    Picker("Calendar", selection: mirrorCalendarBinding) {
                        Text("Choose…").tag(String?.none)
                        ForEach(writableCalendars, id: \.id) { calendar in
                            Text(calendar.title).tag(String?.some(calendar.id))
                        }
                    }

                    Toggle("Include what the time was against", isOn: mirrorBinding(\.includesSubject))
                    Toggle("Include tags", isOn: mirrorBinding(\.includesTags))
                    Toggle("Mark the time as busy", isOn: mirrorBinding(\.marksAsBusy))

                    Picker("Skip anything under", selection: minimumBinding) {
                        Text("Nothing").tag(0.0)
                        Text("2 minutes").tag(120.0)
                        Text("5 minutes").tag(300.0)
                        Text("15 minutes").tag(900.0)
                    }

                    LabeledContent("Written so far", value: "\(services.timeMirror.mirroredCount) events")

                    HStack {
                        Button("Mirror This Month Now") { backfill() }
                            .disabled(!services.timeMirror.isReady || services.timeMirror.isWorking)

                        Button("Remove Every Mirrored Event…", role: .destructive) { removeAll() }
                            .disabled(services.timeMirror.mirroredCount == 0 || services.timeMirror.isWorking)
                    }

                    if let mirrorMessage {
                        Text(mirrorMessage)
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                }
            } else {
                Text("Turn the calendar on under Calendar first. Elephruit cannot write to a calendar it has not been given.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Calendar")
        } footer: {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text("Use a calendar of its own. Pouring tracked time into the calendar that holds your actual meetings makes both unreadable, and undoing it means deleting events one at a time.")

                Text("Three things are never written, whatever is switched on above: **who you were with**, because an hour with somebody is a fact about them and an event is visible to everybody a calendar is shared with; the **contents of anything you linked**; and **whether the time is billable**. There is nowhere in the write path to put any of them.")

                Text("It only ever writes. An event edited in Calendar never changes the entry it came from — the entry is the record and the event is a copy. Turning this off leaves everything already written in place.")
            }
            .font(Theme.Text.metadata)
            .foregroundStyle(Theme.Colors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var writableCalendars: [CalendarInfo] {
        (services?.calendar.calendars ?? []).filter(\.allowsModification)
    }

    // MARK: - Bindings

    private var roundingBinding: Binding<TimeRounding> {
        Binding(
            get: { TimeRounding(rawValue: storedRounding) ?? .exact },
            set: { storedRounding = $0.rawValue }
        )
    }

    private var roundsBinding: Binding<Int> {
        Binding(
            get: { plan.roundsBeforeLongBreak },
            set: { newValue in
                var updated = plan
                updated.roundsBeforeLongBreak = newValue
                savePlan(updated)
            }
        )
    }

    private func planBinding(_ keyPath: WritableKeyPath<PomodoroPlan, Bool>) -> Binding<Bool> {
        Binding(
            get: { plan[keyPath: keyPath] },
            set: { newValue in
                var updated = plan
                updated[keyPath: keyPath] = newValue
                savePlan(updated)
            }
        )
    }

    /// A phase length in minutes, which is the only unit anybody thinks in.
    ///
    /// Clamping happens inside ``PomodoroPlan``, so a field typed to zero comes back as the minimum
    /// rather than being refused while somebody is still mid-edit.
    private func minutesBinding(_ keyPath: WritableKeyPath<PomodoroPlan, TimeInterval>) -> Binding<Int> {
        Binding(
            get: { Int((plan[keyPath: keyPath] / 60).rounded()) },
            set: { newValue in
                var updated = plan
                updated[keyPath: keyPath] = Double(newValue) * 60
                savePlan(updated)
            }
        )
    }

    /// Round-trips through `PomodoroPlan`'s own initialiser, so what settings shows is what the timer
    /// will actually run rather than what was typed at it.
    private func savePlan(_ updated: PomodoroPlan) {
        let clamped = PomodoroPlan(
            focus: updated.focus,
            shortBreak: updated.shortBreak,
            longBreak: updated.longBreak,
            roundsBeforeLongBreak: updated.roundsBeforeLongBreak,
            startsBreaksAutomatically: updated.startsBreaksAutomatically,
            startsNextFocusAutomatically: updated.startsNextFocusAutomatically
        )
        plan = clamped
        services?.storedPomodoroPlan = clamped
    }

    private var mirrorEnabledBinding: Binding<Bool> {
        Binding(
            get: { services?.timeMirror.policy.isEnabled ?? false },
            set: { newValue in
                guard let services else { return }
                var policy = services.timeMirror.policy
                policy.isEnabled = newValue
                // A default destination is *not* chosen here. Picking one silently would mean the
                // first entry after this toggle lands in whichever calendar happened to be first,
                // which is the one outcome this setting exists to let somebody avoid.
                services.timeMirror.policy = policy
            }
        )
    }

    private var mirrorCalendarBinding: Binding<String?> {
        Binding(
            get: { services?.timeMirror.policy.calendarIdentifier },
            set: { newValue in
                guard let services else { return }
                var policy = services.timeMirror.policy
                policy.calendarIdentifier = newValue
                services.timeMirror.policy = policy
            }
        )
    }

    private func mirrorBinding(_ keyPath: WritableKeyPath<TimeMirrorPolicy, Bool>) -> Binding<Bool> {
        Binding(
            get: { services?.timeMirror.policy[keyPath: keyPath] ?? false },
            set: { newValue in
                guard let services else { return }
                var policy = services.timeMirror.policy
                policy[keyPath: keyPath] = newValue
                services.timeMirror.policy = policy
            }
        )
    }

    private var minimumBinding: Binding<Double> {
        Binding(
            get: { services?.timeMirror.policy.minimumDuration ?? 300 },
            set: { newValue in
                guard let services else { return }
                var policy = services.timeMirror.policy
                policy.minimumDuration = newValue
                services.timeMirror.policy = policy
            }
        )
    }

    // MARK: - Actions

    private func backfill() {
        guard let services else { return }
        let range = TimeWindow.thisMonth.range(using: services.dateProvider)

        Task {
            let written = await services.timeMirror.backfill(range)
            mirrorMessage = written == 0
                ? "Nothing new to write — this month is already mirrored."
                : "Wrote \(written) event\(written == 1 ? "" : "s")."
        }
    }

    private func removeAll() {
        guard let services else { return }
        Task {
            let removed = await services.timeMirror.removeEverythingWritten()
            mirrorMessage = "Removed \(removed) event\(removed == 1 ? "" : "s"). Nothing tracked was deleted."
        }
    }
}

/// A phase length, in minutes, with a stepper beside the field.
///
/// Both, because the two ways of changing one are genuinely different: a stepper is for nudging
/// twenty-five to thirty, and typing is for somebody who already knows they work in fifty.
private struct PhaseLengthField: View {
    let title: String
    @Binding var minutes: Int

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: Theme.Spacing.tight) {
                TextField(title, value: $minutes, format: .number)
                    .frame(width: 50)
                    .multilineTextAlignment(.trailing)
                    .labelsHidden()

                Text("min")
                    .foregroundStyle(Theme.Colors.secondaryText)

                Stepper(title, value: $minutes, in: 1...240, step: 5)
                    .labelsHidden()
            }
        }
    }
}
