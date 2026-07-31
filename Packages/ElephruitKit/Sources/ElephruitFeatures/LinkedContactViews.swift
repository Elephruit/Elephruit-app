import ElephruitCore
import ElephruitDesign
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The address-book link on a person's page.
///
/// ### Progressive disclosure, because none of this is the point of the page
/// Collapsed, it is one line: which account, and when it last refreshed. Expanded, it is the
/// provenance of every imported value and the actions — refresh, unlink, relink. Somebody reading
/// about a friend should not have to scroll past synchronisation status to reach what they wrote
/// about them.
///
/// The user sees **one person**, not an iCloud version and a CRM version. This section explains where
/// some of the details came from; it is not a second copy of them.
struct LinkedContactSection: View {
    @Environment(\.services) private var services

    let person: Item

    @State private var link: SystemContactLink?
    @State private var isExpanded = false
    @State private var isRelinking = false
    @State private var feedback: String?
    @State private var isRefreshing = false

    var body: some View {
        Group {
            if let link {
                content(link)
            } else {
                unlinkedRow
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .accessibilityIdentifier(AccessibilityID.People.linkedContactSection)
        .task(id: person.id) { reload() }
        .sheet(isPresented: $isRelinking) {
            RelinkContactSheet(person: person) { didLink in
                isRelinking = false
                if didLink { reload() }
            }
        }
    }

    // MARK: - Linked

    @ViewBuilder
    private func content(_ link: SystemContactLink) -> some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                if link.state != .linked {
                    Label(link.state.explanation, systemImage: link.state.symbolName)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, Theme.Spacing.tight)
                }

                importedValues(link)

                if let feedback {
                    Label(feedback, systemImage: "checkmark.circle")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.completed)
                }

                actions(link)
            }
            .padding(.top, Theme.Spacing.small)
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: link.state.symbolName)
                    .foregroundStyle(
                        link.state == .linked ? Theme.Colors.secondaryText : Theme.Colors.warning
                    )
                    .frame(width: Theme.Size.rowGlyph)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Linked to Contacts")
                        .font(Theme.Text.rowSubtitle)
                    Text(link.summary(relativeTo: services?.dateProvider.now ?? Date()))
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }

                Spacer()

                if isRefreshing { ProgressView().controlSize(.small) }
            }
            .contentShape(.rect)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Linked to Contacts. \(link.summary(relativeTo: services?.dateProvider.now ?? Date()))"
        )
    }

    /// Where each detail came from.
    private func importedValues(_ link: SystemContactLink) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            ForEach(link.currentValues.prefix(12), id: \.id) { value in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    Text(value.displayField)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .frame(width: 120, alignment: .leading)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(value.value)
                            .font(Theme.Text.metadata)
                            .textSelection(.enabled)

                        if value.origin != .imported {
                            Text(value.origin.displayName)
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.secondaryText)
                        }

                        if value.hasConflict, let systemValue = value.conflictingSystemValue {
                            Text("Contacts now says “\(systemValue)”")
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.warning)
                        }
                    }

                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(value.displayField): \(value.value). \(value.provenanceSentence(relativeTo: services?.dateProvider.now ?? Date()))"
                )
            }

            if link.currentValues.count > 12 {
                Text("…and \(link.currentValues.count - 12) more.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
    }

    private func actions(_ link: SystemContactLink) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Button("Refresh") { refresh(link) }
                .controlSize(.small)
                .disabled(isRefreshing || services?.contacts.authorization.canRead != true)
                .help(
                    services?.contacts.authorization.canRead == true
                        ? "Re-read this contact now"
                        : "Contacts access is off"
                )

            Button(link.state == .unavailable ? "Link to another contact…" : "Change link…") {
                isRelinking = true
            }
            .controlSize(.small)

            Spacer()

            Button("Unlink", role: .destructive) { unlink() }
                .controlSize(.small)
                .help("Keeps this person and their details, and stops refreshing them")
        }
        .padding(.top, Theme.Spacing.tight)
    }

    // MARK: - Unlinked

    private var unlinkedRow: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "person.crop.circle.badge.plus")
                .foregroundStyle(Theme.Colors.tertiaryText)
                .frame(width: Theme.Size.rowGlyph)

            Text("Not linked to Contacts")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)

            Spacer()

            Button("Link…") { isRelinking = true }
                .controlSize(.small)
                .disabled(services?.contacts.authorization.canRead != true)
                .help(
                    services?.contacts.authorization.canRead == true
                        ? "Connect this person to a contact so their details refresh"
                        : "Turn on Contacts in Settings first"
                )
        }
    }

    // MARK: - Actions

    private func reload() {
        guard let services else { return }
        link = try? services.contactImports.link(for: person)
    }

    private func refresh(_ link: SystemContactLink) {
        guard let services else { return }
        isRefreshing = true

        Task {
            let coordinator = ContactRefreshCoordinator(services: services)
            let outcome = await coordinator.refresh(link)
            feedback = outcome.message
            isRefreshing = false
            reload()
        }
    }

    private func unlink() {
        guard let services else { return }
        services.perform { try services.contactImports.unlink(person) }
        feedback = "Unlinked. Everything recorded here is kept."
        reload()
    }
}

/// Choosing which system contact a person is.
struct RelinkContactSheet: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    let person: Item
    let onFinish: (Bool) -> Void

    @State private var query = ""
    @State private var results: [ContactSummary] = []
    @State private var isSearching = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Link \(person.displayTitle) to a contact")
                .font(Theme.Text.title)

            Text("""
                Their standard details will refresh from the contact you choose. Notes, facts, \
                relationships, and history stay exactly as they are.
                """)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Search your contacts", text: $query)
                .onSubmit { search() }
                .accessibilityLabel("Search your contacts")

            if isSearching {
                ProgressView().controlSize(.small)
            }

            List(results) { contact in
                Button {
                    link(to: contact)
                } label: {
                    HStack(spacing: Theme.Spacing.small) {
                        PersonAvatar(name: contact.fullName, colorName: nil, size: 24)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(contact.fullName)
                                .font(Theme.Text.rowSubtitle)
                            if let detail = contact.emailAddresses.first?.value
                                ?? contact.phoneNumbers.first?.value {
                                Text(detail)
                                    .font(Theme.Text.metadata)
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
            .frame(minHeight: 160)
            .overlay {
                if results.isEmpty, !isSearching {
                    Text(query.isEmpty ? "Type a name to search." : "Nothing matches.")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    onFinish(false)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.Spacing.section)
        .frame(width: 460, height: 420)
    }

    private func search() {
        guard let services else { return }
        isSearching = true

        Task {
            await services.contacts.search(query)
            results = services.contacts.searchResults
            isSearching = false
        }
    }

    private func link(to contact: ContactSummary) {
        guard let services else { return }

        Task {
            guard let full = await services.contacts.systemContact(withIdentifier: contact.id) else {
                onFinish(false)
                dismiss()
                return
            }

            services.perform { try services.contactImports.relink(person, to: full) }
            services.noteChange(to: person)
            onFinish(true)
            dismiss()
        }
    }
}

// MARK: - A subtle source indicator

/// A small mark on a row saying its details come from the address book.
///
/// Deliberately quiet — a glyph and a tooltip. Somebody scanning their People list is looking for a
/// person, not an audit of where each row came from.
struct ContactSourceBadge: View {
    let state: ContactSyncState

    var body: some View {
        Image(systemName: state == .linked ? "person.crop.rectangle.stack" : state.symbolName)
            .font(.system(size: 9))
            .rowTint(state == .linked ? Theme.Colors.tertiaryText : Theme.Colors.warning)
            .help(state == .linked ? "Details come from your address book" : state.displayName)
            .accessibilityLabel(state == .linked ? "Linked to Contacts" : state.displayName)
    }
}
