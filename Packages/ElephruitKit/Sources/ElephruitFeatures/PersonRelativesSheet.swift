import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import SwiftUI

/// Everybody around somebody, recorded in one pass.
///
/// ### Why this replaced a sheet that took one person at a time
/// The sentence this exists to capture is *"he has a son and a daughter — the son's going into his
/// senior year, the daughter into eighth, both at South High"*. Through the old sheet that was six
/// trips: link a child, open their page, open a fact sheet, pick a category, type a grade, and then
/// all of it again for the second child — with the school having nowhere structured to go either
/// time. Nobody does that. What they do instead is nothing, which is how an app for remembering
/// people ends up not being told about anybody's family.
///
/// So: rows, added by pressing the word you would have used. *Son* is one click and is already a
/// complete fact — the app knows of a son, and knows it does not know his name. Everything else on
/// the row is optional and can be filled in the same breath or years later.
///
/// ### What it does not do
/// It does not ask for a birthday, and it does not ask for a range. An age is one number recorded
/// against today, and ``ElephruitCore/AgeEstimator`` widens it as time passes; a grade is one word
/// plus the year it referred to, and ``ElephruitCore/GradeEstimator`` advances it every August.
/// Asking the user for the bounds would be asking them to do arithmetic the app is better at, about
/// a child whose birthday they have just said they do not know.
struct AddRelativesSheet: View {
    @Environment(\.services) private var services

    let person: Item

    /// The kind the sheet opens with a row for, when it was opened from a specific button.
    let initialKind: RelationshipKind?

    let onFinish: () -> Void

    @State private var rows: [RelativeCapture] = []
    @State private var matches: [UUID: [Item]] = [:]
    @FocusState private var focusedRow: UUID?

    init(person: Item, initialKind: RelationshipKind? = nil, onFinish: @escaping () -> Void) {
        self.person = person
        self.initialKind = initialKind
        self.onFinish = onFinish
    }

    /// The words on the add buttons, and what each one means.
    ///
    /// Gendered words sit beside the neutral one rather than replacing it. The app never infers one
    /// — pressing *Son* is the user saying it, which is the only way a gendered word ever enters a
    /// record here.
    private static let quickAdds: [(label: String, kind: RelationshipKind)] = [
        ("Son", .child),
        ("Daughter", .child),
        ("Child", .child),
        ("Partner", .partner),
        ("Parent", .parent),
        ("Sibling", .sibling),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    addBar

                    if rows.isEmpty {
                        emptyState
                    } else {
                        ForEach($rows) { $row in
                            relativeRow($row)
                        }
                    }
                }
                .padding(Theme.Spacing.section)
            }

            Divider()
            footer
        }
        .frame(width: 640)
        .frame(minHeight: 560)
        .background(Theme.Colors.windowBackground)
        .accessibilityIdentifier(AccessibilityID.Records.addRelationshipSheet)
        .onAppear {
            guard rows.isEmpty, let initialKind else { return }
            append(kind: initialKind, label: nil)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: Theme.Spacing.medium) {
            IconTile(
                systemImage: "figure.2.and.child.holdinghands",
                tint: Theme.Colors.captureAccent,
                size: .large
            )

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text("Add family to \(person.displayTitle)")
                    .font(Theme.Text.title)
                Text("A name is optional. Record what you were told, and fill the rest in later.")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.vertical, Theme.Spacing.large)
    }

    private var addBar: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Add")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)

            HStack(spacing: Theme.Spacing.small) {
                ForEach(Self.quickAdds, id: \.label) { entry in
                    Button {
                        append(kind: entry.kind, label: entry.label.lowercased())
                    } label: {
                        Text(entry.label)
                            .font(Theme.Text.chip)
                            .padding(.horizontal, Theme.Spacing.small)
                            .frame(height: 28)
                            .background(Theme.Colors.tintedFill(Theme.Colors.captureAccent), in: Capsule())
                            .foregroundStyle(Theme.Colors.captureAccent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("records.addRelative.\(entry.label.lowercased())")
                }

                Button {
                    append(kind: .friend, label: nil)
                } label: {
                    Label("Someone else", systemImage: "plus")
                        .font(Theme.Text.chip)
                        .padding(.horizontal, Theme.Spacing.small)
                        .frame(height: 28)
                        .background(Theme.Colors.subtleFill, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        Text("Nobody yet. Press a word above — *Son* on its own is already worth recording.")
            .font(Theme.Text.rowSubtitle)
            .foregroundStyle(Theme.Colors.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Theme.Spacing.large)
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                if update.recordableRelatives.isEmpty {
                    Text("Nothing to add yet.")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                } else {
                    ForEach(update.recordableRelatives) { row in
                        Text(summary(of: row))
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if containsChild {
                        Label(
                            "Children stay in Elephruit. Nothing here is written to your Apple Contacts.",
                            systemImage: "lock.shield"
                        )
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }
            }

            Spacer(minLength: Theme.Spacing.medium)

            Button("Cancel", role: .cancel, action: onFinish)
                .keyboardShortcut(.cancelAction)

            Button(addButtonTitle, action: save)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(update.recordableRelatives.isEmpty)
                .accessibilityIdentifier("records.addRelative.save")
        }
        .padding(Theme.Spacing.section)
        .background(Theme.Colors.contentBackground)
    }

    // MARK: - One relative

    @ViewBuilder
    private func relativeRow(_ row: Binding<RelativeCapture>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                Picker("", selection: row.kind) {
                    ForEach(RelationshipKind.allCases, id: \.rawValue) { option in
                        Text(option.displayName.capitalized).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                TextField(
                    "Call them",
                    text: Binding(
                        get: { row.wrappedValue.label ?? "" },
                        set: { row.wrappedValue.label = $0 }
                    )
                )
                .frame(width: 120)
                .help("“son” rather than “child” — the app uses your word and never guesses one")

                Spacer(minLength: 0)

                Button {
                    remove(row.wrappedValue.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove this person")
            }

            nameField(row)

            if row.wrappedValue.kind == .child {
                schoolFields(row)
            }

            TextField(
                "Worth remembering (optional)",
                text: Binding(
                    get: { row.wrappedValue.note ?? "" },
                    set: { row.wrappedValue.note = $0 }
                )
            )
        }
        .padding(Theme.Spacing.medium)
        .background(Theme.Colors.contentBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
    }

    @ViewBuilder
    private func nameField(_ row: Binding<RelativeCapture>) -> some View {
        let id = row.wrappedValue.id

        TextField(
            "Their name (optional)",
            text: Binding(
                get: { row.wrappedValue.name ?? "" },
                set: { newValue in
                    row.wrappedValue.name = newValue
                    // Typing over a chosen person unpicks them: the field now says somebody else.
                    row.wrappedValue.existingPersonID = nil
                    search(newValue, for: id)
                }
            )
        )
        .accessibilityIdentifier("records.addRelative.name")

        if row.wrappedValue.existingPersonID != nil {
            Label("Linking the record that already exists.", systemImage: "checkmark.circle")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
        } else if let found = matches[id], !found.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text("Already in Elephruit")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)

                ForEach(found, id: \.id) { match in
                    Button {
                        row.wrappedValue.existingPersonID = match.id
                        row.wrappedValue.name = match.displayTitle
                        matches[id] = []
                    } label: {
                        HStack(spacing: Theme.Spacing.small) {
                            PersonAvatar(name: match.displayTitle, colorName: match.colorName, size: 20)
                            Text(match.displayTitle)
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Age, grade and school — and the sentence saying which school year was meant.
    ///
    /// The intent control is the important one. "Going into 8th grade" said in July refers to the
    /// year about to begin, and reading that from the date alone is wrong for the whole of the
    /// summer, which is when the sentence is said. The resolved year is shown back so the answer is
    /// visible before it is stored rather than a year later.
    @ViewBuilder
    private func schoolFields(_ row: Binding<RelativeCapture>) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            TextField(
                "Age",
                text: Binding(
                    get: { row.wrappedValue.age.map(String.init) ?? "" },
                    set: { row.wrappedValue.age = Self.age(from: $0) }
                )
            )
            .frame(width: 60)

            TextField(
                "Grade — “8th”, “senior”",
                text: Binding(
                    get: { row.wrappedValue.gradeText ?? "" },
                    set: { row.wrappedValue.gradeText = $0 }
                )
            )
            .accessibilityIdentifier("records.addRelative.grade")

            Picker("", selection: row.schoolYearIntent) {
                ForEach(SchoolYearIntent.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 190)
            .disabled(row.wrappedValue.statedGradeText == nil)
        }

        if let reading = row.wrappedValue.gradeReading(observedOn: now, calendar: calendar) {
            Text(reading)
                .font(Theme.Text.metadata)
                .foregroundStyle(
                    row.wrappedValue.parsedGrade == nil ? Theme.Colors.warning : Theme.Colors.secondaryText
                )
                .fixedSize(horizontal: false, vertical: true)
        }

        TextField(
            "School (optional)",
            text: Binding(
                get: { row.wrappedValue.school ?? "" },
                set: { row.wrappedValue.school = $0 }
            )
        )
        .accessibilityIdentifier("records.addRelative.school")

        if let years = row.wrappedValue.age {
            Text(Self.ageExplanation(years))
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - What will happen

    private var update: PersonUpdate {
        PersonUpdate(subjectID: person.id, relatives: rows)
    }

    private var containsChild: Bool {
        update.recordableRelatives.contains { $0.kind == .child }
    }

    private var addButtonTitle: String {
        let count = update.recordableRelatives.count
        return count <= 1 ? "Add" : "Add \(count) people"
    }

    private func summary(of row: RelativeCapture) -> String {
        row.summarySentence(
            subjectName: person.displayTitle,
            observedOn: now,
            calendar: calendar
        )
    }

    private var now: Date { services?.dateProvider.now ?? Date() }
    private var calendar: Calendar { services?.dateProvider.calendar ?? .current }

    // MARK: - Editing

    /// Adds a row, always carrying a word.
    ///
    /// The word is what makes a row worth writing — see ``ElephruitCore/RelativeCapture/isEmpty``.
    /// Every row here arrives by somebody pressing a button that says one, so seeding it from the
    /// button is not a default being invented on the user's behalf; it is what they just pressed.
    /// Without it, opening the sheet from *Add Child…* produces a row the Add button refuses.
    private func append(kind: RelationshipKind, label: String?) {
        rows.append(RelativeCapture(kind: kind, label: label ?? kind.displayName))
    }

    private func remove(_ id: UUID) {
        rows.removeAll { $0.id == id }
        matches[id] = nil
    }

    private func search(_ query: String, for rowID: UUID) {
        guard let services, query.trimmingCharacters(in: .whitespaces).count >= 2 else {
            matches[rowID] = []
            return
        }

        let key = TextNormalizer.foldedForMatching(query)
        matches[rowID] = ((try? services.persons.allPeople(includingPlaceholders: true)) ?? [])
            .filter { $0.id != person.id && TextNormalizer.foldedForMatching($0.displayTitle).contains(key) }
            .prefix(4)
            .map { $0 }
    }

    /// The age typed in, when it is a plausible one.
    ///
    /// Nil rather than zero for anything unparseable, so a stray keystroke records nothing instead of
    /// asserting that somebody is nought. The upper bound is a sanity check on a typo, not a claim
    /// about how old a child can be.
    private static func age(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let years = Int(trimmed), (0...120).contains(years) else { return nil }
        return years
    }

    /// Says what recording an age will actually mean, before it is recorded.
    private static func ageExplanation(_ years: Int) -> String {
        "Recorded as \(years) today. Elephruit carries it forward, and shows it as approximate "
            + "once a birthday could have passed."
    }

    // MARK: - Saving

    private func save() {
        guard let services else { return }
        let written = update

        services.perform {
            // One call, one save. Superseding, reciprocals, placeholder creation and school years
            // all live behind it — see `PersonRepository.apply`.
            let touched = try services.persons.apply(
                written,
                source: nil,
                observedOn: services.dateProvider.now
            )
            for relative in touched {
                services.noteChange(to: relative)
            }
            services.noteChange(to: person)
        }

        onFinish()
    }
}
