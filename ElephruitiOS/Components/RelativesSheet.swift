import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// Somebody's family, recorded on a phone.
///
/// ### Why this exists at all
/// The phone was read-only about people. `PersonScreen` loaded a portrait, a timeline and a context
/// and drew them, and wrote nothing — no facts, no relationships, no corrections. Which is exactly
/// backwards, because the phone is the thing in your pocket when somebody tells you they have a son
/// going into his senior year, and the Mac is the thing you get back to three days later having
/// forgotten.
///
/// ### Why it is not a port of the Mac's sheet
/// The Mac has a 640-point panel with rows side by side. A phone has one column and a thumb, so the
/// same material is a `Form`: one relative at a time, added from the same words, with the fields
/// stacked. What is deliberately *identical* is everything underneath — ``ElephruitCore/RelativeCapture``
/// builds the same value, ``ElephruitCore/PersonUpdate`` carries it, and one repository call writes
/// it. The two apps drifted into two different people modules once already, and it was the write
/// paths that let them.
struct RelativesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.services) private var services

    let person: Item

    /// Called after the save, so the page behind can re-read.
    let onChange: () -> Void

    @State private var rows: [RelativeCapture] = []
    @State private var saveError: String?
    /// Attributes asked for but not yet filled in, per row. Not in the capture, because an
    /// attribute with no value is a field on screen rather than a fact about anybody.
    @State private var pending: [UUID: [FactAttribute]] = [:]
    @State private var naming: UUID?
    @State private var customLabel = ""

    var body: some View {
        NavigationStack {
            List {
                addSection

                ForEach($rows) { $row in
                    Section {
                        rowFields($row)
                    } header: {
                        Text(row.statedLabel?.capitalized ?? row.kind.displayName.capitalized)
                    } footer: {
                        Text(
                            row.summarySentence(
                                subjectName: person.displayTitle,
                                observedOn: now,
                                calendar: calendar
                            )
                        )
                    }
                }

                if rows.contains(where: { $0.kind == .child }) {
                    Section {
                        Label(
                            "Children stay in Elephruit. Nothing here is written to your Apple Contacts.",
                            systemImage: "lock.shield"
                        )
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                    }
                }

                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.Colors.warning)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Family")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: save)
                        .disabled(update.recordableRelatives.isEmpty)
                        .accessibilityIdentifier("person.relatives.save")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("person.relatives.sheet")
        }
    }

    // MARK: - Adding

    private var addSection: some View {
        Section {
            ForEach(RelativeQuickAdd.all, id: \.label) { entry in
                Button {
                    rows.append(RelativeQuickAdd.row(kind: entry.kind, label: entry.label.lowercased()))
                } label: {
                    Label("Add a \(entry.label.lowercased())", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("person.relatives.add.\(entry.label.lowercased())")
            }

            Button {
                rows.append(RelativeQuickAdd.row(kind: .friend, label: nil))
            } label: {
                Label("Add someone else", systemImage: "plus.circle")
            }
        } header: {
            Text("Who")
        } footer: {
            Text(
                "A name is optional. “A son” on its own is worth recording — Elephruit will ask for "
                    + "his name when you know it."
            )
        }
    }

    // MARK: - One relative

    /// What this row draws: the suggestions for the relationship, then anything already recorded or
    /// asked for that is not among them.
    ///
    /// The fields used to be five hard-coded ones behind `kind == .child`, which meant a colleague
    /// could not have an age and a partner could not have a job. They are asked for now — see
    /// `RelationshipKind.suggestedAttributes` — and *Something else* is underneath, so what a row
    /// can carry is not a list anybody has to maintain.
    private func offeredAttributes(for row: RelativeCapture) -> [FactAttribute] {
        let suggested = row.kind.suggestedAttributes
        let extra = (Array(row.facts.keys) + (pending[row.id] ?? []))
            .filter { !suggested.contains($0) }
            .reduce(into: [FactAttribute]()) { seen, attribute in
                if !seen.contains(attribute) { seen.append(attribute) }
            }
        return suggested + extra
    }

    @ViewBuilder
    private func rowFields(_ row: Binding<RelativeCapture>) -> some View {
        Picker("Relationship", selection: row.kind) {
            ForEach(RelationshipKind.allCases, id: \.rawValue) { option in
                Text(option.displayName.capitalized).tag(option)
            }
        }

        TextField(
            "Call them",
            text: Binding(get: { row.wrappedValue.label ?? "" }, set: { row.wrappedValue.label = $0 })
        )

        TextField(
            "Their name (optional)",
            text: Binding(get: { row.wrappedValue.name ?? "" }, set: { row.wrappedValue.name = $0 })
        )
        .textInputAutocapitalization(.words)
        .accessibilityIdentifier("person.relatives.name")

        ForEach(offeredAttributes(for: row.wrappedValue), id: \.rawValue) { attribute in
            field(row, attribute)
        }

        customAdder(row)
    }

    @ViewBuilder
    private func field(_ row: Binding<RelativeCapture>, _ attribute: FactAttribute) -> some View {
        switch attribute.captureKind {
        case .wholeNumber:
            TextField(
                "\(attribute.capturePrompt) (optional)",
                text: Binding(
                    get: { row.wrappedValue[attribute] ?? "" },
                    set: { row.wrappedValue[attribute] = Self.wholeNumber(from: $0) }
                )
            )
            .keyboardType(.numberPad)
            .accessibilityIdentifier("person.relatives.\(attribute.rawValue)")

            if attribute == .observedAge, let years = row.wrappedValue.age {
                Text(Self.ageExplanation(years))
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

        case .schoolGrade:
            TextField(attribute.capturePrompt, text: binding(row, attribute))
                .accessibilityIdentifier("person.relatives.grade")

            if row.wrappedValue.statedGradeText != nil {
                Picker("School year", selection: row.schoolYearIntent) {
                    ForEach(SchoolYearIntent.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                if let reading = row.wrappedValue.gradeReading(observedOn: now, calendar: calendar) {
                    Text(reading)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(
                            row.wrappedValue.parsedGrade == nil
                                ? Theme.Colors.warning : Theme.Colors.secondaryText
                        )
                }
            }

        case .text:
            TextField("\(attribute.capturePrompt) (optional)", text: binding(row, attribute))
                .textInputAutocapitalization(.sentences)
                .accessibilityIdentifier("person.relatives.\(attribute.rawValue)")
        }
    }

    /// The escape hatch, and the reason the suggestions above are only suggestions.
    @ViewBuilder
    private func customAdder(_ row: Binding<RelativeCapture>) -> some View {
        let id = row.wrappedValue.id

        if naming == id {
            TextField("What is it? — “allergy”, “team”", text: $customLabel)
                .accessibilityIdentifier("person.relatives.customLabel")
                .onSubmit { addCustom(to: id) }

            Button("Add") { addCustom(to: id) }
                .disabled(FactAttribute.custom(customLabel) == nil)
        } else {
            Button {
                naming = id
                customLabel = ""
            } label: {
                Label("Something else…", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("person.relatives.somethingElse")
        }

        Button(role: .destructive) {
            rows.removeAll { $0.id == id }
            pending[id] = nil
        } label: {
            Label("Remove", systemImage: "trash")
        }
    }

    private func addCustom(to rowID: UUID) {
        guard let attribute = FactAttribute.custom(customLabel) else { return }
        pending[rowID, default: []].append(attribute)
        customLabel = ""
        naming = nil
    }

    private func binding(_ row: Binding<RelativeCapture>, _ attribute: FactAttribute) -> Binding<String> {
        Binding(
            get: { row.wrappedValue[attribute] ?? "" },
            set: { row.wrappedValue[attribute] = $0 }
        )
    }

    // MARK: - Derived

    private var update: PersonUpdate {
        PersonUpdate(subjectID: person.id, relatives: rows)
    }

    private var now: Date { services?.dateProvider.now ?? Date() }
    private var calendar: Calendar { services?.dateProvider.calendar ?? .current }

    /// Digits only, and within a range that catches a typo rather than making a claim about how old
    /// anybody can be. Anything unreadable records nothing instead of asserting somebody is nought.
    private static func wholeNumber(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Int(trimmed), (0...120).contains(value) else { return nil }
        return String(value)
    }

    private static func ageExplanation(_ years: Int) -> String {
        "Recorded as \(years) today. Elephruit carries it forward, and shows it as approximate "
            + "once a birthday could have passed."
    }

    // MARK: - Saving

    private func save() {
        guard let services else { return }
        let written = update

        do {
            let touched = try services.persons.apply(
                written, source: nil, observedOn: services.dateProvider.now
            )
            for relative in touched {
                services.noteChange(to: relative)
            }
            services.noteChange(to: person)
            onChange()
            dismiss()
        } catch {
            saveError = error.summary
        }
    }
}
