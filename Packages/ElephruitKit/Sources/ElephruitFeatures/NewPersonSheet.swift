import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// Adding somebody by hand, in the plainest form the app has.
///
/// ### Why a form and not the command bar
/// The plus button beside Groups says "Add a person", and for a long time it opened the
/// natural-language bar instead. That bar can create people, but only if you know to type the verb
/// first — `add Sarah Chen`. A bare name parses as a search, which is not runnable, so the most
/// obvious thing to type into a box labelled *add a person* was the one thing that did nothing.
///
/// The bar is still there for anybody who wants to talk to the app in sentences. This is for
/// everybody who pressed a plus and expected fields.
///
/// ### Why it warns rather than blocks
/// Two people really can share a name, so a match is a question and never a refusal. What it must
/// not do is let somebody create a second Maya Lin without ever being told the first one exists —
/// duplicates are far cheaper to avoid here than to reconcile later.
struct NewPersonSheet: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    let navigation: NavigationModel

    @State private var name = ""
    @State private var organization = ""
    @State private var role = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var note = ""
    @State private var matches: [Item] = []
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("New person")
                .font(Theme.Text.title)

            Form {
                TextField("Name", text: $name)
                    .focused($isNameFocused)
                    .onChange(of: name) { _, newValue in findExisting(newValue) }
                    .accessibilityIdentifier("people.newPerson.name")

                TextField("Organisation (optional)", text: $organization)
                TextField("Role (optional)", text: $role)
                TextField("Email (optional)", text: $email)
                TextField("Phone (optional)", text: $phone)

                // The same question `AddRelationshipSheet` asks, for the same reason: the thing most
                // worth recording about somebody new is usually why you are recording them at all,
                // and making that a second trip to a second sheet is how it goes unrecorded.
                TextField("Anything worth remembering (optional)", text: $note)
                    .help("Kept as a quick fact on their record")
            }
            .formStyle(.grouped)

            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Label("You may already know them", systemImage: "person.crop.circle.badge.questionmark")
                        .font(Theme.Text.sectionHeader)
                        .foregroundStyle(Theme.Colors.warning)

                    ForEach(matches, id: \.id) { match in
                        Button {
                            open(match.id)
                        } label: {
                            HStack(spacing: Theme.Spacing.small) {
                                PersonAvatar(name: match.displayTitle, colorName: match.colorName, size: 22)
                                Text(match.displayTitle)
                                Spacer()
                                Text("Open")
                                    .font(Theme.Text.metadata)
                                    .foregroundStyle(Theme.Colors.secondaryText)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty)
                    .accessibilityIdentifier("people.newPerson.add")
            }
        }
        .padding(Theme.Spacing.section)
        .frame(width: 440)
        .accessibilityIdentifier(AccessibilityID.People.newPersonSheet)
        .onAppear { isNameFocused = true }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// People whose name already contains what is being typed.
    ///
    /// Two characters before it says anything, so the warning arrives when it means something rather
    /// than matching half the library on the first keystroke.
    private func findExisting(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let services, trimmed.count >= 2 else {
            matches = []
            return
        }

        let key = TextNormalizer.foldedForMatching(trimmed)
        matches = ((try? services.persons.allPeople(includingPlaceholders: true)) ?? [])
            .filter { TextNormalizer.foldedForMatching($0.displayTitle).contains(key) }
            .prefix(4)
            .map { $0 }
    }

    private func create() {
        guard let services, !trimmedName.isEmpty else { return }
        let clock = services.dateProvider

        services.perform {
            let person = try services.persons.createPerson(draft)

            let remark = note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !remark.isEmpty {
                try services.persons.record(
                    ObservationDraft(attribute: .quickFact, value: remark),
                    about: person,
                    observedOn: clock.now,
                    confidence: .stated,
                    sensitivity: .normal,
                    source: nil
                )
            }

            services.noteChange(to: person)
            navigation.select(.kind(.person))
            navigation.selectItem(person.id)
        }
        dismiss()
    }

    private var draft: PersonDraft {
        Self.draft(name: name, organization: organization, role: role, email: email, phone: phone)
    }

    /// The typed-in fields as a draft.
    ///
    /// A blank optional field has to arrive as nil rather than as an empty string: an empty role
    /// stored as `""` is a role the person is asserted to have, and it shows up in the header as a
    /// gap where a job title goes.
    static func draft(
        name: String, organization: String, role: String, email: String, phone: String
    ) -> PersonDraft {
        func cleaned(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return PersonDraft(
            fullName: name.trimmingCharacters(in: .whitespacesAndNewlines),
            roleTitle: cleaned(role),
            organizationName: cleaned(organization),
            emails: cleaned(email).map { [LabelledValue(label: "email", value: $0)] } ?? [],
            phones: cleaned(phone).map { [LabelledValue(label: "phone", value: $0)] } ?? []
        )
    }

    private func open(_ personID: UUID) {
        navigation.select(.kind(.person))
        navigation.selectItem(personID)
        dismiss()
    }
}
