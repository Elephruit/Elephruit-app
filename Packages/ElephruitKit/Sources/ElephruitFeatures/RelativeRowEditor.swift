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
/// ### The fields are asked for, not written here
/// This used to hold five hard-coded fields behind `if row.kind == .child`, which meant a colleague
/// could not have an age, a partner could not have a job, and adding any of it was an edit in six
/// files. It now asks ``ElephruitCore/RelationshipKind/suggestedAttributes`` what to *offer* and
/// ``ElephruitCore/FactAttribute/captureKind`` how to draw each one — and offers *Something else*
/// beneath, so what a row can carry is not a list anybody has to maintain.
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

    /// Attributes the user has asked for but not yet filled in.
    ///
    /// Held here rather than in the capture, because an attribute with no value is a field on
    /// screen rather than a fact about anybody — and ``ElephruitCore/RelativeCapture`` drops empty
    /// values on purpose, so a row parked in the model would vanish the moment it was drawn.
    @State private var pendingAttributes: [FactAttribute] = []
    @State private var customLabel = ""
    @State private var isNamingCustom = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            headerRow
            nameField

            ForEach(offeredAttributes, id: \.rawValue) { attribute in
                field(for: attribute)
            }

            customAdder
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

    // MARK: - Facts

    /// What this row draws: the suggestions for the relationship, then anything already recorded or
    /// asked for that is not among them.
    private var offeredAttributes: [FactAttribute] {
        let suggested = row.kind.suggestedAttributes
        let extra = (Array(row.facts.keys) + pendingAttributes)
            .filter { !suggested.contains($0) }
            .reduce(into: [FactAttribute]()) { seen, attribute in
                if !seen.contains(attribute) { seen.append(attribute) }
            }
        return suggested + extra
    }

    @ViewBuilder
    private func field(for attribute: FactAttribute) -> some View {
        switch attribute.captureKind {
        case .schoolGrade:
            gradeField(attribute)
        case .wholeNumber:
            numberField(attribute)
        case .text:
            TextField(
                "\(attribute.capturePrompt) (optional)",
                text: binding(for: attribute)
            )
            .accessibilityIdentifier("records.addRelative.\(attribute.rawValue)")
        }
    }

    /// Age, and the sentence saying what recording one actually means.
    @ViewBuilder
    private func numberField(_ attribute: FactAttribute) -> some View {
        TextField(
            attribute.capturePrompt,
            text: Binding(
                get: { row[attribute] ?? "" },
                set: { row[attribute] = Self.wholeNumber(from: $0) }
            )
        )
        .frame(width: 120)
        .accessibilityIdentifier("records.addRelative.\(attribute.rawValue)")

        if attribute == .observedAge, let years = row.age {
            Text(Self.ageExplanation(years))
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A grade, the school year it referred to, and what the app made of it.
    ///
    /// The intent control is the important one. "Going into 8th grade" said in July refers to the
    /// year about to begin, and reading that from the date alone is wrong for the whole of the
    /// summer, which is when the sentence is said. The resolved year is shown back so the answer is
    /// visible before it is stored rather than a year later.
    @ViewBuilder
    private func gradeField(_ attribute: FactAttribute) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            TextField(attribute.capturePrompt, text: binding(for: attribute))
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
    }

    /// The escape hatch, and the reason the suggestions above are only suggestions.
    @ViewBuilder
    private var customAdder: some View {
        if isNamingCustom {
            HStack(spacing: Theme.Spacing.small) {
                TextField("What is it? — “allergy”, “team”", text: $customLabel)
                    .accessibilityIdentifier("records.addRelative.customLabel")
                    .onSubmit(addCustom)

                Button("Add", action: addCustom)
                    .disabled(FactAttribute.custom(customLabel) == nil)

                Button("Cancel", role: .cancel) {
                    isNamingCustom = false
                    customLabel = ""
                }
            }
        } else {
            Button("Something else…", systemImage: "plus") { isNamingCustom = true }
                .buttonStyle(.borderless)
                .font(Theme.Text.metadata)
                .accessibilityIdentifier("records.addRelative.somethingElse")
        }
    }

    private func addCustom() {
        guard let attribute = FactAttribute.custom(customLabel) else { return }
        if !offeredAttributes.contains(attribute) {
            pendingAttributes.append(attribute)
        }
        customLabel = ""
        isNamingCustom = false
    }

    private func binding(for attribute: FactAttribute) -> Binding<String> {
        Binding(get: { row[attribute] ?? "" }, set: { row[attribute] = $0 })
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

    /// Digits only, and within a range that catches a typo rather than making a claim about how old
    /// anybody can be. Anything unreadable records nothing instead of asserting that somebody is
    /// nought.
    static func wholeNumber(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Int(trimmed), (0...120).contains(value) else { return nil }
        return String(value)
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
