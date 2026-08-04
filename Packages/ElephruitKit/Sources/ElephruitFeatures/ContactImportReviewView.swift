import ElephruitCore
import ElephruitDesign
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// What the import will do, before it does any of it.
///
/// ### The default path is one press
/// The summary answers the only question most people have — *how many, and how many are already
/// here* — and **Add Contacts to People** is the primary button. Everything else on this screen is
/// for the person who wants to look: search, sorting, per-row selection, container filters, and a
/// review queue for anything ambiguous.
///
/// Ambiguous rows are **not** selected by default, so pressing the primary button can never resolve a
/// duplicate by accident. That is the one interaction rule this screen exists to enforce.
struct ContactImportReviewView: View {
    @Environment(\.services) private var services

    let model: ContactImportModel
    let onCancel: () -> Void

    @State private var reviewingProposal: ContactImportProposal?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            list
            Divider()
            footer
        }
        .accessibilityIdentifier(AccessibilityID.Records.contactReview)
        .sheet(item: $reviewingProposal) { proposal in
            ContactDuplicateResolutionView(proposal: proposal) { outcome, personID in
                model.resolve(proposal.id, as: outcome, personID: personID)
                reviewingProposal = nil
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            // The title has to agree with the buttons. Calling this "Review before adding" when
            // there is nothing to add sets up a task the sheet then refuses to let anybody do.
            Text(model.plan?.hasPendingAdditions == false ? "Nothing new to add" : "Review before adding")
                .font(Theme.Text.title)

            if let plan = model.plan {
                Text(plan.headline)
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)

                summaryChips(plan)

                if !plan.containers.isEmpty {
                    containerFilters(plan)
                }
            }

            Label(
                "This all happens on this Mac. Nothing is uploaded, and your contacts are not changed.",
                systemImage: "lock.shield"
            )
            .font(Theme.Text.metadata)
            .foregroundStyle(Theme.Colors.tertiaryText)
        }
        .padding(Theme.Spacing.medium)
    }

    private func summaryChips(_ plan: ContactImportPlan) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.small) {
                ForEach(plan.summaryLines, id: \.outcome) { line in
                    Label("\(line.count) \(line.outcome.displayName.lowercased())", systemImage: line.outcome.symbolName)
                        .font(Theme.Text.chip)
                        .foregroundStyle(
                            line.outcome.needsAttention ? Theme.Colors.warning : Theme.Colors.secondaryText
                        )
                        .padding(.horizontal, Theme.Spacing.small)
                        .padding(.vertical, Theme.Spacing.tight)
                        .background(Theme.Colors.subtleFill, in: Capsule())
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            plan.summaryLines
                .map { "\($0.count) \($0.outcome.displayName)" }
                .joined(separator: ", ")
        )
    }

    /// Which accounts to take from — only where the framework exposed them.
    private func containerFilters(_ plan: ContactImportPlan) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text("Accounts")
                .font(Theme.Text.sectionHeader)
                .foregroundStyle(Theme.Colors.secondaryText)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.small) {
                    ForEach(plan.containers) { container in
                        let isOn = model.selectedContainerIDs.isEmpty
                            || model.selectedContainerIDs.contains(container.id)

                        Toggle(isOn: Binding(
                            get: { isOn },
                            set: { _ in toggleContainer(container.id, in: plan) }
                        )) {
                            Text("\(container.name) (\(container.contactCount))")
                                .font(Theme.Text.chip)
                        }
                        .toggleStyle(.button)
                        .help(
                            container.isReadOnly
                                ? "\(container.name) — read-only, which changes nothing here because Elephruit only reads"
                                : container.name
                        )
                    }
                }
            }
        }
    }

    private func toggleContainer(_ id: String, in plan: ContactImportPlan) {
        var selection = model.selectedContainerIDs

        if selection.isEmpty {
            // "All" was implicit; turning one off means selecting the rest.
            selection = Set(plan.containers.map(\.id))
        }

        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        // Back to implicit-all when everything is on, so the label reads honestly.
        model.selectedContainerIDs = selection.count == plan.containers.count ? [] : selection
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: Theme.Spacing.medium) {
            HStack(spacing: Theme.Spacing.tight) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.Colors.tertiaryText)
                TextField("Search", text: Binding(
                    get: { model.searchText },
                    set: { model.searchText = $0 }
                ))
                .textFieldStyle(.plain)
                .accessibilityLabel("Search contacts")
            }
            .frame(maxWidth: 220)

            Picker("Sort", selection: Binding(
                get: { model.sortOrder },
                set: { model.sortOrder = $0 }
            )) {
                ForEach(ContactImportModel.SortOrder.allCases) { order in
                    Text(order.displayName).tag(order)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Sort by")

            Spacer()

            Button("Select All") { model.selectAllVisible() }
                .controlSize(.small)
                .help("Selects everything shown, which after a search is not everything found")

            Button("Deselect All") { model.deselectAllVisible() }
                .controlSize(.small)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
    }

    // MARK: - List

    private var list: some View {
        // A plain `List` over a `LazyVStack`: this is native selection, native keyboard behaviour,
        // and native row recycling, which is what keeps several thousand rows scrolling.
        List(model.visibleProposals) { proposal in
            ContactProposalRow(
                proposal: proposal,
                onToggle: { model.setSelection(!proposal.isSelected, for: proposal.id) },
                onReview: { reviewingProposal = proposal }
            )
            .listRowInsets(EdgeInsets(top: 2, leading: Theme.Spacing.small, bottom: 2, trailing: Theme.Spacing.small))
        }
        .listStyle(.inset)
        .frame(maxHeight: .infinity)
        .overlay {
            if model.visibleProposals.isEmpty {
                EmptyStateView(
                    symbolName: "magnifyingglass",
                    headline: "Nothing matches",
                    message: "Try a different search, or turn an account back on."
                )
            }
        }
    }

    // MARK: - Footer

    /// ### Two screens, not one
    /// When there is something to add, this is a review: a count of what is ticked, Cancel to
    /// abandon it, and a prominent Add.
    ///
    /// When there is nothing to add — every contact on the Mac is already linked, which is what
    /// somebody reconnecting an existing library sees — it is not a review. There is no decision to
    /// make and nothing to abandon, and the pairing of "Cancel" with a greyed-out "Add Contacts to
    /// People" reads as a task that has gone wrong. It is a confirmation that everything is already
    /// in, and the only button it needs is **Done**.
    @ViewBuilder
    private var footer: some View {
        if let plan = model.plan, !plan.hasPendingAdditions {
            nothingToAddFooter(plan)
        } else {
            reviewFooter
        }
    }

    private func nothingToAddFooter(_ plan: ContactImportPlan) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Label(
                plan.alreadyLinkedCount > 0
                    ? "Everything on this Mac is already in Records."
                    : "There is nothing here to add.",
                systemImage: plan.alreadyLinkedCount > 0 ? "checkmark.circle.fill" : "tray"
            )
            .font(Theme.Text.rowSubtitle)
            .foregroundStyle(
                plan.alreadyLinkedCount > 0 ? Theme.Colors.completed : Theme.Colors.secondaryText
            )

            Spacer()

            // Done, not Cancel. Nothing has been started, so there is nothing to call off — and it
            // is the default action, so Return and Escape both close a sheet that has no other job.
            Button("Done", action: onCancel)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(Theme.Spacing.medium)
    }

    private var reviewFooter: some View {
        HStack {
            if let plan = model.plan {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(plan.selectedActionableCount) selected")
                        .font(Theme.Text.rowSubtitle)
                    if plan.needsReviewCount > 0 {
                        Text("\(plan.needsReviewCount) need a decision before they can be added")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.warning)
                    }
                }
            }

            Spacer()

            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)

            Button("Add Contacts to Records") { model.startImport() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(model.plan?.isRunnable != true)
        }
        .padding(Theme.Spacing.medium)
    }
}

/// One row: who, what will happen, and why.
struct ContactProposalRow: View {
    let proposal: ContactImportProposal
    let onToggle: () -> Void
    let onReview: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Toggle(isOn: Binding(get: { proposal.isSelected }, set: { _ in onToggle() })) {
                EmptyView()
            }
            .labelsHidden()
            .disabled(!proposal.outcome.changesTheDatabase)
            .accessibilityLabel("Include \(proposal.contact.displayName)")

            PersonAvatar(name: proposal.contact.displayName, colorName: nil, size: 26)

            VStack(alignment: .leading, spacing: 0) {
                Text(proposal.contact.displayName.isEmpty ? "No name" : proposal.contact.displayName)
                    .font(Theme.Text.rowTitle)
                    .lineLimit(1)

                if !proposal.subtitle.isEmpty {
                    Text(proposal.subtitle)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Theme.Spacing.small)

            if proposal.outcome.needsAttention {
                Button("Review…", action: onReview)
                    .controlSize(.small)
            }

            Label(outcomeLabel, systemImage: proposal.outcome.symbolName)
                .font(Theme.Text.chip)
                .foregroundStyle(outcomeColour)
                .labelStyle(.titleAndIcon)
                .frame(minWidth: 120, alignment: .trailing)
        }
        .padding(.vertical, Theme.Spacing.tight)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(proposal.isSelected ? .isSelected : [])
        .contextMenu {
            if proposal.outcome.changesTheDatabase {
                Button(proposal.isSelected ? "Deselect" : "Select", action: onToggle)
            }
            if proposal.outcome.needsAttention {
                Button("Review…", action: onReview)
            }
        }
    }

    private var outcomeLabel: String {
        guard proposal.outcome == .linkToExisting || proposal.outcome == .alreadyLinked,
              let name = proposal.matchedPersonName
        else { return proposal.outcome.displayName }

        return proposal.outcome == .alreadyLinked ? "Already \(name)" : "Link to \(name)"
    }

    private var outcomeColour: Color {
        switch proposal.outcome {
        case .needsReview: Theme.Colors.warning
        case .unusable: Theme.Colors.tertiaryText
        case .alreadyLinked: Theme.Colors.completed
        default: Theme.Colors.secondaryText
        }
    }

    /// One sentence, so a screen reader does not have to assemble it from four fragments.
    private var accessibilityDescription: String {
        var parts = [proposal.contact.displayName.isEmpty ? "No name" : proposal.contact.displayName]
        if !proposal.subtitle.isEmpty { parts.append(proposal.subtitle) }
        parts.append(outcomeLabel)
        if let explanation = proposal.explanation { parts.append(explanation) }
        if !proposal.outcome.changesTheDatabase { parts.append("nothing will be added") }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Duplicate resolution

/// One ambiguous contact, and the four things that can be done about it.
///
/// ### The evidence is shown, and it is words
/// "Same phone number" is something a person can agree or disagree with. A score is not — and the
/// decision being asked for here is exactly the one that must not be made by a threshold, because
/// merging two people who are not the same person destroys the boundary between two sets of private
/// notes and cannot be undone by hand.
struct ContactDuplicateResolutionView: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    let proposal: ContactImportProposal
    let onDecide: (ContactImportOutcome, UUID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Is this someone you already have?")
                .font(Theme.Text.title)

            HStack(alignment: .top, spacing: Theme.Spacing.section) {
                sideBySide(
                    title: "From Contacts",
                    name: proposal.contact.displayName,
                    details: contactDetails
                )

                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .padding(.top, Theme.Spacing.section)

                sideBySide(
                    title: "Already in Records",
                    name: proposal.matchedPersonName ?? "—",
                    details: existingDetails
                )
            }

            if let explanation = proposal.explanation {
                Label(explanation, systemImage: "questionmark.circle")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label(
                """
                Nothing is merged here. Linking connects this contact to that person so their details \
                refresh; it never combines two people's notes.
                """,
                systemImage: "info.circle"
            )
            .font(Theme.Text.metadata)
            .foregroundStyle(Theme.Colors.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

            Spacer()

            VStack(spacing: Theme.Spacing.small) {
                Button {
                    onDecide(.linkToExisting, proposal.matchedPersonID)
                } label: {
                    Label(
                        "Link to \(proposal.matchedPersonName ?? "them")",
                        systemImage: "link"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(proposal.matchedPersonID == nil)

                Button {
                    onDecide(.createPerson, nil)
                } label: {
                    Label("They are a different person", systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    onDecide(.skipped, nil)
                } label: {
                    Label("Decide later", systemImage: "clock")
                        .frame(maxWidth: .infinity)
                }

                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.Spacing.section)
        .frame(width: 560, height: 460)
        .accessibilityIdentifier(AccessibilityID.Records.contactDuplicate)
    }

    private func sideBySide(title: String, name: String, details: [String]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(title)
                .font(Theme.Text.sectionHeader)
                .foregroundStyle(Theme.Colors.secondaryText)

            Text(name)
                .font(Theme.Text.rowTitleEmphasised)

            ForEach(details, id: \.self) { detail in
                Text(detail)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.medium)
        .background(Theme.Colors.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(name). \(details.joined(separator: ". "))")
    }

    private var contactDetails: [String] {
        var details: [String] = []
        if !proposal.contact.organizationName.isEmpty { details.append(proposal.contact.organizationName) }
        details.append(contentsOf: proposal.contact.emailAddresses.map { "\($0.label): \($0.value)" })
        details.append(contentsOf: proposal.contact.phoneNumbers.map { "\($0.label): \($0.value)" })
        if let container = proposal.contact.containerName { details.append(container) }
        return details
    }

    private var existingDetails: [String] {
        guard let services,
              let personID = proposal.matchedPersonID,
              let person = try? services.persons.person(id: personID),
              let profile = person.personProfile
        else { return [] }

        var details: [String] = []
        if let organization = profile.organizationName { details.append(organization) }
        details.append(contentsOf: profile.emails.map { "\($0.label): \($0.value)" })
        details.append(contentsOf: profile.phones.map { "\($0.label): \($0.value)" })
        return details
    }
}
