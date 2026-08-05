import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import SwiftUI

/// What a meeting changed about the people who were in it.
///
/// ### Why the debrief box was not enough
/// There was already somewhere to type after a meeting: a text field on the event's annotation. It
/// wrote free text and the text became nothing. It created no facts, linked no people, and the next
/// brief was no better for having been written — so the one moment when the app knows *who you were
/// with and when* was the moment it did least with it.
///
/// This is the same box with the rest of the sentence attached. The notes still go where they went.
/// Beside them, each linked person gets somewhere to put what you learned about them, and every fact
/// written here carries the meeting as its source — which is what
/// ``ElephruitCore/BriefEntry/sourceItemID`` has been promising to make tappable since it was
/// written.
///
/// ### Nothing is extracted from the prose
/// The composer captures what the user chooses to structure. Reading the notes and guessing at facts
/// to write onto somebody's record is the one thing this module has been careful never to do, and a
/// debrief is exactly where it would be most tempting and most wrong.
struct MeetingDebriefSheet: View {
    @Environment(\.services) private var services

    let event: CalendarEventSummary

    /// The people already linked to this meeting. Attendee matching happens in the inspector, where
    /// a link is offered rather than made — see `EventInspectorView.unmatchedAttendees`.
    let people: [Item]

    let onFinish: () -> Void

    @State private var notes = ""
    @State private var facts: [UUID: [FactRow]] = [:]
    @State private var relatives: [UUID: [RelativeCapture]] = [:]
    @State private var hasLoaded = false

    /// One thing learned about somebody, mid-typing.
    struct FactRow: Identifiable, Equatable {
        let id = UUID()
        var category: QuickFactCategory = .goodToKnow
        var value = ""
        var schoolYearIntent: SchoolYearIntent = .current
        /// What the user called it, when the category is *Something else*.
        var customLabel = ""

        var cleanedValue: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

        /// The attribute this becomes, folding a named custom one back into the curated set.
        var attribute: FactAttribute {
            guard category == .somethingElse else { return category.attribute }
            return FactAttribute.custom(customLabel) ?? .quickFact
        }

        var isEmpty: Bool {
            cleanedValue.isEmpty || (category == .somethingElse && FactAttribute.custom(customLabel) == nil)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                    notesField

                    if people.isEmpty {
                        noPeopleNotice
                    } else {
                        ForEach(people, id: \.id) { person in
                            personSection(person)
                        }
                    }
                }
                .padding(Theme.Spacing.section)
            }

            Divider()
            footer
        }
        .frame(width: 680)
        .frame(minHeight: 620)
        .background(Theme.Colors.windowBackground)
        .accessibilityIdentifier("calendar.debriefSheet")
        .onAppear(perform: load)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: Theme.Spacing.medium) {
            IconTile(systemImage: "text.append", tint: Theme.Colors.captureAccent, size: .large)

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text("Log \(event.title)")
                    .font(Theme.Text.title)
                    .lineLimit(1)
                Text(event.startAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.vertical, Theme.Spacing.large)
    }

    private var notesField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            SectionHeader("What happened")

            TextEditor(text: $notes)
                .font(Theme.Text.rowSubtitle)
                .frame(height: 120)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .strokeBorder(Theme.Colors.separator)
                }
                .accessibilityIdentifier("calendar.debrief.notes")

            Text("Kept in Elephruit. Never written to your calendar.")
                .font(Theme.Text.keyHint)
                .foregroundStyle(Theme.Colors.tertiaryText)
        }
    }

    private var noPeopleNotice: some View {
        Label(
            "Nobody is linked to this meeting yet. Link an attendee in the inspector and what you "
                + "learn about them can be recorded here.",
            systemImage: "person.crop.circle.badge.questionmark"
        )
        .font(Theme.Text.rowSubtitle)
        .foregroundStyle(Theme.Colors.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - One person

    @ViewBuilder
    private func personSection(_ person: Item) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                PersonAvatar(name: person.displayTitle, colorName: person.colorName, size: 24)
                Text(person.displayTitle)
                    .font(.system(.headline, weight: .semibold))
                Spacer(minLength: 0)
            }

            ForEach(Binding(get: { facts[person.id] ?? [] }, set: { facts[person.id] = $0 })) { $fact in
                factRow($fact, personID: person.id)
            }

            ForEach(
                Binding(get: { relatives[person.id] ?? [] }, set: { relatives[person.id] = $0 })
            ) { $row in
                RelativeRowEditor(row: $row, subjectID: person.id) {
                    relatives[person.id]?.removeAll { $0.id == row.id }
                }
            }

            HStack(spacing: Theme.Spacing.small) {
                Button("Add a fact", systemImage: "plus") {
                    facts[person.id, default: []].append(FactRow())
                }
                .buttonStyle(.borderless)
                .font(Theme.Text.metadata)
                .accessibilityIdentifier("calendar.debrief.addFact")

                Spacer(minLength: 0)
            }

            RelativeQuickAddBar { kind, label in
                relatives[person.id, default: []].append(RelativeQuickAdd.row(kind: kind, label: label))
            }
        }
        .padding(Theme.Spacing.medium)
        .background(Theme.Colors.contentBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
    }

    @ViewBuilder
    private func factRow(_ fact: Binding<FactRow>, personID: UUID) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Picker("", selection: fact.category) {
                ForEach(QuickFactCategory.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 150)

            if fact.wrappedValue.category == .somethingElse {
                TextField("What is it?", text: fact.customLabel)
                    .frame(width: 140)
                    .accessibilityIdentifier("calendar.debrief.customLabel")
            }

            TextField(fact.wrappedValue.attribute.capturePrompt, text: fact.value)

            Button {
                facts[personID]?.removeAll { $0.id == fact.wrappedValue.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove this fact")
        }

        if fact.wrappedValue.category == .grade {
            HStack(spacing: Theme.Spacing.small) {
                Picker("", selection: fact.schoolYearIntent) {
                    ForEach(SchoolYearIntent.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)

                if let reading = gradeReading(fact.wrappedValue) {
                    Text(reading)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(
                            SchoolGrade.parse(fact.wrappedValue.cleanedValue) == nil
                                ? Theme.Colors.warning : Theme.Colors.secondaryText
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func gradeReading(_ fact: FactRow) -> String? {
        RelativeCapture(gradeText: fact.value, schoolYearIntent: fact.schoolYearIntent)
            .gradeReading(observedOn: observedOn, calendar: calendar)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Spacing.medium) {
            if writeCount > 0 {
                Label(
                    "\(writeCount) \(writeCount == 1 ? "thing" : "things") recorded against this meeting.",
                    systemImage: "link"
                )
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
            } else {
                Text("Notes alone are worth saving.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }

            Spacer(minLength: 0)

            Button("Cancel", role: .cancel, action: onFinish)
                .keyboardShortcut(.cancelAction)

            Button("Save", action: save)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!hasAnything)
                .accessibilityIdentifier("calendar.debrief.save")
        }
        .padding(Theme.Spacing.section)
        .background(Theme.Colors.contentBackground)
    }

    private var updates: [PersonUpdate] {
        people.compactMap { person in
            let drafts = (facts[person.id] ?? [])
                .filter { !$0.isEmpty }
                .map { fact in
                    ObservationDraft(
                        attribute: fact.attribute,
                        value: fact.cleanedValue,
                        // Stated rather than derived from the date — see `SchoolYearIntent`.
                        schoolYearStart: fact.category == .grade
                            ? fact.schoolYearIntent
                                .schoolYear(observedOn: observedOn, calendar: calendar)
                                .startYear
                            : nil
                    )
                }

            let update = PersonUpdate(
                subjectID: person.id,
                observations: drafts,
                relatives: relatives[person.id] ?? []
            )
            return update.isEmpty ? nil : update
        }
    }

    private var writeCount: Int { updates.reduce(0) { $0 + $1.writeCount } }

    private var hasAnything: Bool {
        !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || writeCount > 0
    }

    /// The date the facts are recorded against.
    ///
    /// The meeting's start, not now. A conversation logged the next morning happened yesterday, and
    /// every estimate downstream counts from this — so dating it to the typing would age a child by
    /// a day for every day the debrief was put off.
    private var observedOn: Date { event.startAt }

    private var calendar: Calendar { services?.dateProvider.calendar ?? .current }

    // MARK: - Loading and saving

    private func load() {
        guard !hasLoaded, let services else { return }
        hasLoaded = true
        notes = (try? services.eventLinks.annotation(for: event.identity))?.debriefNotes ?? ""
    }

    private func save() {
        guard let services else { return }
        let written = updates
        let text = notes

        services.perform {
            try services.eventLinks.setDebriefNotes(text, for: event)

            // The meeting item is the source every fact points back at, so it has to exist before
            // any of them are written. `creatingIfNeeded` is the same call the notes button makes.
            let meeting = try services.eventLinks.meetingItem(for: event)

            for update in written {
                let touched = try services.persons.apply(
                    update, source: meeting, observedOn: observedOn
                )
                for relative in touched {
                    services.noteChange(to: relative)
                }
                if let subject = try services.persons.person(id: update.subjectID) {
                    services.noteChange(to: subject)
                }
            }

            if let meeting {
                services.noteChange(to: meeting)
            }
        }

        onFinish()
    }
}
