import ElephruitCore
import ElephruitDesign
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// Records that might be the same person.
///
/// ### Why nothing here happens automatically
/// Three profiles for one person is untidy and completely recoverable. Two people merged into one
/// destroys the boundary between two sets of private notes and cannot be undone by hand. So every
/// row is an offer with its reasoning attached, and the reasoning is words — "Same email address" —
/// rather than a score, because the user is being asked to agree with it.
struct DuplicatesView: View {
    @Environment(\.services) private var services

    let navigation: NavigationModel

    @State private var matches: [IdentityMatch] = []
    @State private var pendingPlan: MergePlan?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Possible duplicates")
                .font(Theme.Text.title)
                .padding(Theme.Spacing.medium)

            Divider()

            if matches.isEmpty {
                EmptyStateView(
                    symbolName: "person.crop.circle.badge.checkmark",
                    headline: "Nothing to reconcile",
                    message: """
                        Records sharing a Contacts entry, an email address, or a phone number are \
                        offered here. Nothing is ever merged without you looking at it first.
                        """,
                    tone: .accomplished
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                        ForEach(matches) { match in
                            DuplicateRow(match: match) { plan in
                                pendingPlan = plan
                            } onOpen: {
                                navigation.selectItem($0)
                            }
                        }
                    }
                    .padding(Theme.Spacing.medium)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.People.duplicates)
        .task { reload() }
        .sheet(item: $pendingPlan) { plan in
            MergeConfirmationSheet(plan: plan) { confirmed in
                pendingPlan = nil
                if confirmed { merge(plan) }
            }
        }
    }

    private func reload() {
        matches = (try? services?.personIdentity.duplicates()) ?? []
    }

    private func merge(_ plan: MergePlan) {
        guard let services else { return }
        services.perform { try services.personIdentity.merge(plan) }
        services.refreshDerivedState()
        reload()
    }
}

struct DuplicateRow: View {
    @Environment(\.services) private var services

    let match: IdentityMatch
    let onMerge: (MergePlan) -> Void
    let onOpen: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.medium) {
                personButton(match.leftID)
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(Theme.Colors.tertiaryText)
                personButton(match.rightID)
                Spacer()
            }

            Label(match.explanation, systemImage: match.isCertain ? "checkmark.seal" : "questionmark.circle")
                .font(Theme.Text.metadata)
                .foregroundStyle(match.isCertain ? Theme.Colors.completed : Theme.Colors.secondaryText)

            HStack {
                Spacer()
                Button("Merge…") { buildPlan() }
                    .controlSize(.small)
            }
        }
        .padding(Theme.Spacing.medium)
        .background(Theme.Colors.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Possible duplicate. \(match.explanation)")
    }

    @ViewBuilder
    private func personButton(_ id: UUID) -> some View {
        if let person = try? services?.persons.person(id: id) {
            Button {
                onOpen(id)
            } label: {
                HStack(spacing: Theme.Spacing.tight) {
                    PersonAvatar(name: person.displayTitle, colorName: person.colorName, size: 22)
                    Text(person.displayTitle)
                        .font(Theme.Text.rowSubtitle)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private func buildPlan() {
        guard let services,
              let primary = try? services.persons.person(id: match.leftID),
              let secondary = try? services.persons.person(id: match.rightID),
              let plan = try? services.personIdentity.plan(merging: secondary, into: primary)
        else { return }
        onMerge(plan)
    }
}

/// Exactly what a merge will do, before it does it.
struct MergeConfirmationSheet: View {
    let plan: MergePlan
    let onDecide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Label("Merge these two", systemImage: "arrow.triangle.merge")
                .font(Theme.Text.title)

            Text(plan.summary)
                .font(Theme.Text.rowSubtitle)
                .fixedSize(horizontal: false, vertical: true)

            if !plan.conflicts.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text("Both values are kept")
                        .font(Theme.Text.sectionHeader)
                        .foregroundStyle(Theme.Colors.secondaryText)

                    ForEach(plan.conflicts, id: \.field) { conflict in
                        Text("\(conflict.field): “\(conflict.primaryValue)” stays; “\(conflict.secondaryValue)” is kept as an unconfirmed note.")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Label(
                "“\(plan.secondaryName)” goes to the Trash rather than being deleted, so this can be walked back.",
                systemImage: "trash"
            )
            .font(Theme.Text.metadata)
            .foregroundStyle(Theme.Colors.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDecide(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Merge") { onDecide(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Spacing.section)
        .frame(width: 480)
    }
}

// MARK: - Contacts settings

/// Turning the address book on, and linking records to it.
///
/// The permission is explained in plain language *before* it is requested, and the explanation says
/// what the app cannot do as well as what it will — because Contacts grants read and write together
/// and the user has no way to give less.
struct ContactsSettingsSection: View {
    @Environment(\.services) private var services

    @State private var searchText = ""
    @State private var isSearching = false

    var body: some View {
        Section("Contacts") {
            if let contacts = services?.contacts {
                Toggle("Use my address book", isOn: enabledBinding)
                    .accessibilityHint("Links people in Elephruit to your existing contacts")

                Text("""
                    Elephruit can link the people you keep notes about to your existing contacts, so \
                    you do not type their details twice. It only ever reads them. Your notes, \
                    reflections, and relationship history stay here and are never written back.
                    """)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if contacts.isEnabled {
                    authorizationState(contacts)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.People.contactsSettings)
    }

    @ViewBuilder
    private func authorizationState(_ contacts: ContactsService) -> some View {
        switch contacts.authorization {
        case .authorized:
            if contacts.accounts.isEmpty {
                Text("No accounts found.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            } else {
                ForEach(contacts.accounts) { account in
                    HStack {
                        Label(account.name, systemImage: "person.crop.rectangle.stack")
                        Spacer()
                        Text("\(account.contactCount)")
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .monospacedDigit()
                        if account.isReadOnly {
                            Image(systemName: "lock")
                                .foregroundStyle(Theme.Colors.tertiaryText)
                                .help("Read-only account")
                        }
                    }
                    .font(Theme.Text.rowSubtitle)
                }
            }

            ContactImportRow(searchText: $searchText)

        case .denied, .restricted:
            // macOS records the answer permanently, so a "try again" button here would show no
            // prompt and read as broken. Saying where the switch actually is respects the user's
            // time more than a button that cannot work.
            Label(
                contacts.authorization.explanation
                    ?? "Access was refused. Turn it on in System Settings ▸ Privacy & Security ▸ Contacts.",
                systemImage: "exclamationmark.triangle"
            )
            .font(Theme.Text.metadata)
            .foregroundStyle(Theme.Colors.warning)
            .fixedSize(horizontal: false, vertical: true)

        case .notRequested, .unavailable:
            ProgressView()
                .controlSize(.small)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { services?.contacts.isEnabled ?? false },
            set: { isOn in
                guard let contacts = services?.contacts else { return }
                if isOn {
                    Task { await contacts.enable() }
                } else {
                    contacts.disable()
                }
            }
        )
    }
}

/// Finding a system contact and linking or importing it.
struct ContactImportRow: View {
    @Environment(\.services) private var services

    @Binding var searchText: String

    @State private var results: [ContactSummary] = []
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            TextField("Find a contact by name", text: $searchText)
                .onSubmit { search() }

            ForEach(results) { contact in
                HStack(spacing: Theme.Spacing.small) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(contact.fullName)
                            .font(Theme.Text.rowSubtitle)
                        if let organization = contact.organizationName {
                            Text(organization)
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                    }

                    Spacer()

                    if let existing = existingMatch(for: contact) {
                        Button("Link") { link(contact, to: existing) }
                            .controlSize(.small)
                            .help("Attaches this contact to a person you already have")
                    } else {
                        Button("Import") { importContact(contact) }
                            .controlSize(.small)
                    }
                }
            }

            if let feedback {
                Label(feedback, systemImage: "checkmark.circle")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.completed)
            }
        }
    }

    private func search() {
        guard let services else { return }
        Task {
            await services.contacts.search(searchText)
            results = services.contacts.searchResults
        }
    }

    /// Whether the library already holds somebody this contact plausibly is.
    ///
    /// Offering *Link* rather than *Import* here is the whole point of the identity layer: importing
    /// blindly is how one person becomes three profiles.
    private func existingMatch(for contact: ContactSummary) -> UUID? {
        guard let services else { return nil }
        let candidate = ContactsService.candidate(from: contact)
        return try? services.personIdentity.existingMatch(for: candidate)?.rightID
    }

    private func importContact(_ contact: ContactSummary) {
        guard let services else { return }
        services.perform {
            let person = try services.persons.createPerson(ContactsService.draft(from: contact))
            services.noteChange(to: person)
        }
        feedback = "Imported \(contact.fullName)."
    }

    private func link(_ contact: ContactSummary, to personID: UUID) {
        guard let services, let person = try? services.persons.person(id: personID) else { return }
        services.perform {
            try services.personIdentity.link(
                person, toContactsIdentifier: contact.id, accountName: contact.accountName
            )
            try services.persons.addDetails(to: person, from: ContactsService.draft(from: contact))
            services.noteChange(to: person)
        }
        feedback = "Linked to \(person.displayTitle)."
    }
}
