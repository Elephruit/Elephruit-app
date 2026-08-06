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

    init(person: Item, initialKind: RelationshipKind? = nil, onFinish: @escaping () -> Void) {
        self.person = person
        self.initialKind = initialKind
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        Text("Add")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.secondaryText)

                        RelativeQuickAddBar { kind, label in
                            rows.append(RelativeQuickAdd.row(kind: kind, label: label))
                        }
                    }

                    if rows.isEmpty {
                        emptyState
                    } else {
                        ForEach($rows) { $row in
                            RelativeRowEditor(row: $row, subjectID: person.id) {
                                rows.removeAll { $0.id == row.id }
                            }
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
            rows.append(RelativeQuickAdd.row(kind: initialKind, label: nil))
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

    private var emptyState: some View {
        Text("Nobody yet. Press a word above — “Son” on its own is already worth recording.")
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
                        Text(
                            row.summarySentence(
                                subjectName: person.displayTitle,
                                observedOn: now,
                                calendar: calendar
                            )
                        )
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    if update.recordableRelatives.contains(where: { $0.kind == .child }) {
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

    // MARK: - What will happen

    private var update: PersonUpdate {
        PersonUpdate(subjectID: person.id, relatives: rows)
    }

    private var addButtonTitle: String {
        let count = update.recordableRelatives.count
        return count <= 1 ? "Add" : "Add \(count) people"
    }

    private var now: Date { services?.dateProvider.now ?? Date() }
    private var calendar: Calendar { services?.dateProvider.calendar ?? .current }

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
