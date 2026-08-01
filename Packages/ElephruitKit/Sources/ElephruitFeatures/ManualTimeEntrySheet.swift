import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// Recording time that was never timed.
///
/// ### Why this is a sheet and not half the tracker
/// It was half the tracker: a mode you could leave the surface switched into, with a pair of date
/// fields sitting permanently under the description. Two things were wrong with that. It doubled the
/// size of the one control this module wants people to press, and — worse — it said that guessing at
/// a span you half-remember is as ordinary as measuring one as it happens. It is not. It is the
/// repair you make on the morning you forgot, and a repair that is always on screen is an invitation
/// to stop measuring.
///
/// So it is a sheet, reachable from *Add by Hand* beside the Start button, from the toolbar, and
/// from the empty state. Rare, obvious when wanted, and absent the rest of the time.
///
/// ### What it keeps between entries
/// Everything except the description. Logging a morning from memory is four entries against the same
/// project with the same tags, and re-picking them each time is the friction that stops anybody
/// finishing. The span rolls forward too, so the next entry starts where the last one ended.
struct ManualTimeEntrySheet: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    /// Told when something is written, so the log behind the sheet reloads.
    let onChange: () -> Void

    @State private var draft = TimeEntryComposition()
    @State private var startedAt = Date()
    @State private var endedAt = Date()
    @State private var durationText = ""
    @State private var added = 0

    @FocusState private var isDescriptionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            header

            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                TextField("What did you work on?", text: $draft.description)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Text.rowTitle)
                    .focused($isDescriptionFocused)
                    .onSubmit { if isValid { add() } }

                span

                ElephruitDesign.FlowLayout(spacing: Theme.Spacing.tight, lineSpacing: Theme.Spacing.tight) {
                    TimeSubjectPicker(subject: draft.subject) { draft.subject = $0 }
                    TimeProjectPicker(project: draft.project) { draft.project = $0 }
                    TimePeoplePicker(people: draft.people) { draft.people = $0 }
                    TimeTagPicker(slugs: draft.tagSlugs) { draft.tagSlugs = $0 }

                    Button {
                        draft.isBillable.toggle()
                    } label: {
                        TimeChipLabel(
                            symbolName: "dollarsign.circle",
                            title: nil,
                            isFilled: draft.isBillable
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Billable")
                    .accessibilityValue(draft.isBillable ? "on" : "off")
                }
            }

            Divider()

            footer
        }
        .padding(Theme.Spacing.section)
        .frame(width: 460)
        .onAppear(perform: prepare)
        .accessibilityIdentifier(AccessibilityID.Time.manualSheet)
    }

    // MARK: - Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
            Text("Add time you have already spent")
                .font(Theme.Text.title)

            Text("For the morning you forgot to start the timer. Everything but the description is kept for the next one.")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// From, to, and how long — with the last of the three doing the work.
    ///
    /// Typing a duration moves the **end**, because the start is the part somebody recording a past
    /// stretch is sure about: "I started at nine and it took about ninety minutes."
    private var span: some View {
        HStack(spacing: Theme.Spacing.small) {
            DatePicker("From", selection: $startedAt, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
                .labelsHidden()
                .onChange(of: startedAt) { _, _ in syncDurationText() }

            Text("to")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)

            DatePicker("To", selection: $endedAt, displayedComponents: [.hourAndMinute])
                .datePickerStyle(.compact)
                .labelsHidden()
                .onChange(of: endedAt) { _, _ in syncDurationText() }

            Spacer(minLength: Theme.Spacing.small)

            TextField("0:00", text: $durationText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .rounded, weight: .medium))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 84)
                .onSubmit(commitDuration)
                .help("Type a length — 1:30, 1.5, or 90m")
                .accessibilityLabel("Duration")
                .accessibilityIdentifier(AccessibilityID.Time.durationField)
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.small) {
            if added > 0 {
                Label(
                    added == 1 ? "1 entry added" : "\(added) entries added",
                    systemImage: "checkmark.circle"
                )
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.completed)
            } else if !isValid {
                Text("An entry has to end after it starts.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            Spacer()

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)

            // Adds and stays open, because logging a forgotten morning is four entries rather than
            // one, and a sheet that closes after each is three needless round trips.
            Button("Add", action: add)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
                .accessibilityIdentifier(AccessibilityID.Time.manualAddButton)
        }
    }

    // MARK: - State

    private var isValid: Bool { endedAt > startedAt }

    /// Defaults to the hour just gone, which is nearly always what somebody is recording.
    private func prepare() {
        let now = services?.dateProvider.now ?? Date()
        endedAt = now
        startedAt = now.addingTimeInterval(-3_600)
        syncDurationText()
        isDescriptionFocused = true
    }

    private func syncDurationText() {
        durationText = TimeFormatting.short(max(0, endedAt.timeIntervalSince(startedAt)))
    }

    private func commitDuration() {
        guard let parsed = DurationParser.parse(durationText) else {
            // Unreadable input is not applied and not cleared — what was typed stays there to be
            // fixed, because silently reverting a field somebody just typed into reads as loss.
            syncDurationText()
            return
        }
        endedAt = startedAt.addingTimeInterval(parsed)
        syncDurationText()
    }

    private func add() {
        guard let services, isValid else { return }

        let subject = resolve(draft.subject)
        let project = resolve(draft.project)
        let people = draft.people.compactMap { resolve($0) }

        let written = services.perform {
            try services.timeEntries.addManual(
                item: subject,
                project: project,
                people: people,
                description: draft.description,
                startedAt: startedAt,
                endedAt: endedAt,
                tagSlugs: draft.tagSlugs,
                isBillable: draft.isBillable
            )
        }
        guard written else { return }

        added += 1
        onChange()

        // The description clears and the span rolls forward; everything else stays.
        draft.description = ""
        let length = endedAt.timeIntervalSince(startedAt)
        startedAt = endedAt
        endedAt = startedAt.addingTimeInterval(length)
        syncDurationText()
        isDescriptionFocused = true
    }

    private func resolve(_ reference: SubjectReference?) -> Item? {
        guard let services, let reference else { return nil }
        return (try? services.items.item(id: reference.id)) ?? nil
    }
}
