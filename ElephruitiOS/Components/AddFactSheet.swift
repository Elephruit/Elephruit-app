import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// One thing learned about somebody, recorded on a phone.
///
/// ### Why the list of what you can record has no end
/// ``ElephruitCore/FactAttribute`` has always been an open type, and its own documentation gives
/// *allergic to shellfish* as the reason. But every interface reached it through a closed list of
/// categories, so the model supported facts the app could not be told — an open type reachable only
/// through a closed menu is a closed type with extra steps.
///
/// The curated attributes are here as shortcuts because they are what people record most. Beneath
/// them, **Something else** takes a name and makes an attribute out of it, and everything downstream
/// — the card, the search, the supersede rule, the staleness, the export — works on it unchanged.
/// A named attribute that matches a curated one folds back into it, so typing "School" gives the
/// School card rather than a second card beside it reading the same.
struct AddFactSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.services) private var services

    let person: Item
    let onChange: () -> Void

    /// The attributes offered without being asked for, in the order the portrait shows them.
    private static let shortcuts: [FactAttribute] = [
        .conversationTopic, .significance, .quickFact, .like, .dislike,
        .foodAndDrink, .interest, .lifeEvent, .location, .employer, .role,
        .observedAge, .schoolGrade, .school, .giftIdea, .lookingFor,
    ]

    @State private var attribute: FactAttribute = .quickFact
    @State private var isNamingCustom = false
    @State private var customLabel = ""
    @State private var value = ""
    @State private var confidence: FactConfidence = .stated
    @State private var sensitivity: FactSensitivity = .normal
    @State private var schoolYearIntent: SchoolYearIntent = .current
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            List {
                kindSection
                valueSection
                certaintySection

                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.Colors.warning)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add a fact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: save)
                        .disabled(!isSavable)
                        .accessibilityIdentifier("person.addFact.save")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("person.addFact.sheet")
        }
    }

    // MARK: - What kind of fact

    private var kindSection: some View {
        Section {
            Picker("About", selection: $attribute) {
                ForEach(Self.shortcuts, id: \.rawValue) { option in
                    Label(option.displayName, systemImage: option.symbolName).tag(option)
                }

                // Present only once named, so the picker always says something true about the
                // current selection rather than reading "Something else" over a filled-in card.
                if let custom = FactAttribute.custom(customLabel), !Self.shortcuts.contains(custom) {
                    Label(custom.displayName, systemImage: custom.symbolName).tag(custom)
                }
            }

            if isNamingCustom {
                TextField("What is it about? — “allergy”, “team”", text: $customLabel)
                    .accessibilityIdentifier("person.addFact.customLabel")
                    .onChange(of: customLabel) { _, _ in
                        if let custom = FactAttribute.custom(customLabel) { attribute = custom }
                    }

                if let custom = FactAttribute.custom(customLabel), custom.isCurated {
                    Label(
                        "That is “\(custom.displayName)”, which Elephruit already keeps. "
                            + "It will go on that card.",
                        systemImage: "arrow.turn.down.right"
                    )
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                }
            } else {
                Button {
                    isNamingCustom = true
                } label: {
                    Label("Something else…", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("person.addFact.somethingElse")
            }
        } header: {
            Text("What is this about?")
        }
    }

    // MARK: - The fact itself

    @ViewBuilder
    private var valueSection: some View {
        Section {
            switch attribute.captureKind {
            case .wholeNumber:
                TextField(attribute.capturePrompt, text: $value)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("person.addFact.value")

                if let years = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Text(
                        "Recorded as \(years) today. Elephruit carries it forward, and shows it as "
                            + "approximate once a birthday could have passed."
                    )
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                }

            case .schoolGrade:
                TextField(attribute.capturePrompt, text: $value)
                    .accessibilityIdentifier("person.addFact.value")

                Picker("School year", selection: $schoolYearIntent) {
                    ForEach(SchoolYearIntent.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                if let reading = gradeReading {
                    Text(reading)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(
                            SchoolGrade.parse(value) == nil
                                ? Theme.Colors.warning : Theme.Colors.secondaryText
                        )
                }

            case .text:
                TextField(attribute.capturePrompt, text: $value, axis: .vertical)
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.sentences)
                    .accessibilityIdentifier("person.addFact.value")
            }
        } header: {
            Text(attribute.displayName)
        }
    }

    private var certaintySection: some View {
        Section {
            Picker("How certain", selection: $confidence) {
                ForEach(FactConfidence.allCases, id: \.rawValue) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Picker("Privacy", selection: $sensitivity) {
                ForEach(FactSensitivity.allCases, id: \.rawValue) { option in
                    Text(option.displayName).tag(option)
                }
            }
        } footer: {
            if sensitivity != .normal {
                Text("Never exported, and never included in a meeting brief.")
            }
        }
    }

    // MARK: - Derived

    private var cleanedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSavable: Bool {
        guard !cleanedValue.isEmpty else { return false }
        guard isNamingCustom else { return true }
        return FactAttribute.custom(customLabel) != nil
    }

    private var gradeReading: String? {
        RelativeCapture(gradeText: value, schoolYearIntent: schoolYearIntent)
            .gradeReading(observedOn: now, calendar: calendar)
    }

    private var now: Date { services?.dateProvider.now ?? Date() }
    private var calendar: Calendar { services?.dateProvider.calendar ?? .current }

    // MARK: - Saving

    private func save() {
        guard let services else { return }

        let draft = ObservationDraft(
            attribute: attribute,
            value: cleanedValue,
            // Stated rather than derived from the date, which is wrong for the whole of every
            // summer — see `SchoolYearIntent`.
            schoolYearStart: attribute == .schoolGrade
                ? schoolYearIntent.schoolYear(observedOn: now, calendar: calendar).startYear
                : nil
        )

        do {
            try services.persons.record(
                draft, about: person, observedOn: now,
                confidence: confidence, sensitivity: sensitivity, source: nil
            )
            services.noteChange(to: person)
            onChange()
            dismiss()
        } catch {
            saveError = error.summary
        }
    }
}
