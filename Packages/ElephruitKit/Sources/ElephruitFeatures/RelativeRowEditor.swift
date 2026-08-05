import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import SwiftUI

/// One person being recorded alongside somebody else, as a row.
///
/// Extracted from the family editor the moment the meeting debrief needed the same thing. Two
/// copies of a form whose fields decide how a school year is stored is exactly how the Mac and the
/// phone came to disagree about people in the first place — see ``ElephruitCore/PersonUpdate``.
///
/// Everything it edits lives in the binding. It writes nothing and knows nothing about a store,
/// which is what lets the family editor and the debrief save on their own terms.
struct RelativeRowEditor: View {
    @Environment(\.services) private var services

    @Binding var row: RelativeCapture

    /// Whose page or meeting this row hangs off, so the search cannot offer them as their own
    /// relative.
    let subjectID: UUID

    let onRemove: () -> Void

    @State private var matches: [Item] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            headerRow
            nameField

            if row.kind == .child {
                schoolFields
            }

            TextField(
                "Worth remembering (optional)",
                text: Binding(get: { row.note ?? "" }, set: { row.note = $0 })
            )
        }
        .padding(Theme.Spacing.medium)
        .background(Theme.Colors.contentBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
    }

    private var headerRow: some View {
        HStack(spacing: Theme.Spacing.small) {
            Picker("", selection: $row.kind) {
                ForEach(RelationshipKind.allCases, id: \.rawValue) { option in
                    Text(option.displayName.capitalized).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 150)

            TextField(
                "Call them",
                text: Binding(get: { row.label ?? "" }, set: { row.label = $0 })
            )
            .frame(width: 120)
            .help("“son” rather than “child” — the app uses your word and never guesses one")

            Spacer(minLength: 0)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove this person")
        }
    }

    @ViewBuilder
    private var nameField: some View {
        TextField(
            "Their name (optional)",
            text: Binding(
                get: { row.name ?? "" },
                set: { newValue in
                    row.name = newValue
                    // Typing over a chosen person unpicks them: the field now says somebody else.
                    row.existingPersonID = nil
                    search(newValue)
                }
            )
        )
        .accessibilityIdentifier("records.addRelative.name")

        if row.existingPersonID != nil {
            Label("Linking the record that already exists.", systemImage: "checkmark.circle")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
        } else if !matches.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text("Already in Elephruit")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)

                ForEach(matches, id: \.id) { match in
                    Button {
                        row.existingPersonID = match.id
                        row.name = match.displayTitle
                        matches = []
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
    private var schoolFields: some View {
        HStack(spacing: Theme.Spacing.small) {
            TextField(
                "Age",
                text: Binding(
                    get: { row.age.map(String.init) ?? "" },
                    set: { row.age = Self.age(from: $0) }
                )
            )
            .frame(width: 60)

            TextField(
                "Grade — “8th”, “senior”",
                text: Binding(get: { row.gradeText ?? "" }, set: { row.gradeText = $0 })
            )
            .accessibilityIdentifier("records.addRelative.grade")

            Picker("", selection: $row.schoolYearIntent) {
                ForEach(SchoolYearIntent.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 190)
            .disabled(row.statedGradeText == nil)
        }

        if let reading = row.gradeReading(observedOn: now, calendar: calendar) {
            Text(reading)
                .font(Theme.Text.metadata)
                .foregroundStyle(row.parsedGrade == nil ? Theme.Colors.warning : Theme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }

        TextField(
            "School (optional)",
            text: Binding(get: { row.school ?? "" }, set: { row.school = $0 })
        )
        .accessibilityIdentifier("records.addRelative.school")

        if let years = row.age {
            Text(Self.ageExplanation(years))
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var now: Date { services?.dateProvider.now ?? Date() }
    private var calendar: Calendar { services?.dateProvider.calendar ?? .current }

    private func search(_ query: String) {
        guard let services, query.trimmingCharacters(in: .whitespaces).count >= 2 else {
            matches = []
            return
        }

        let key = TextNormalizer.foldedForMatching(query)
        matches = ((try? services.persons.allPeople(includingPlaceholders: true)) ?? [])
            .filter { $0.id != subjectID && TextNormalizer.foldedForMatching($0.displayTitle).contains(key) }
            .prefix(4)
            .map { $0 }
    }

    /// The age typed in, when it is a plausible one.
    ///
    /// Nil rather than zero for anything unparseable, so a stray keystroke records nothing instead of
    /// asserting that somebody is nought. The upper bound is a sanity check on a typo, not a claim
    /// about how old a child can be.
    static func age(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let years = Int(trimmed), (0...120).contains(years) else { return nil }
        return years
    }

    /// Says what recording an age will actually mean, before it is recorded.
    static func ageExplanation(_ years: Int) -> String {
        "Recorded as \(years) today. Elephruit carries it forward, and shows it as approximate "
            + "once a birthday could have passed."
    }
}

// MARK: - Adding a row

/// The row of buttons that adds a relative.
struct RelativeQuickAddBar: View {
    let onAdd: (RelationshipKind, String?) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            ForEach(RelativeQuickAdd.all, id: \.label) { entry in
                Button {
                    onAdd(entry.kind, entry.label.lowercased())
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
                onAdd(.friend, nil)
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
