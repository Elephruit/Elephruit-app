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

        if row.wrappedValue.kind == .child {
            TextField(
                "Age (optional)",
                text: Binding(
                    get: { row.wrappedValue.age.map(String.init) ?? "" },
                    set: { row.wrappedValue.age = Self.age(from: $0) }
                )
            )
            .keyboardType(.numberPad)

            TextField(
                "Grade — “8th”, “senior”",
                text: Binding(
                    get: { row.wrappedValue.gradeText ?? "" },
                    set: { row.wrappedValue.gradeText = $0 }
                )
            )
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

            TextField(
                "School (optional)",
                text: Binding(
                    get: { row.wrappedValue.school ?? "" },
                    set: { row.wrappedValue.school = $0 }
                )
            )
            .textInputAutocapitalization(.words)

            if let years = row.wrappedValue.age {
                Text(Self.ageExplanation(years))
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
        }

        TextField(
            "Worth remembering (optional)",
            text: Binding(get: { row.wrappedValue.note ?? "" }, set: { row.wrappedValue.note = $0 })
        )

        Button(role: .destructive) {
            let id = row.wrappedValue.id
            rows.removeAll { $0.id == id }
        } label: {
            Label("Remove", systemImage: "trash")
        }
    }

    // MARK: - Derived

    private var update: PersonUpdate {
        PersonUpdate(subjectID: person.id, relatives: rows)
    }

    private var now: Date { services?.dateProvider.now ?? Date() }
    private var calendar: Calendar { services?.dateProvider.calendar ?? .current }

    /// The age typed in, when it is a plausible one. Nil rather than zero for anything unparseable,
    /// so a stray keystroke records nothing instead of asserting that somebody is nought.
    private static func age(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let years = Int(trimmed), (0...120).contains(years) else { return nil }
        return years
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
