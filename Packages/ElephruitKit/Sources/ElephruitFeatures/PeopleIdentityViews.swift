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

/// Managing the address-book connection.
///
/// ### What this screen is for
/// Turning the integration on, seeing whether it is working, refreshing on demand, resolving any
/// disagreement between a value the user changed and a newer one from Contacts, and starting the
/// import again. The explanation of *what the app will and will not do* lives in the onboarding flow,
/// which this can reopen — one place to write it, one place to keep it honest.
public struct ContactsSettingsSection: View {
    @Environment(\.services) private var services

    @State private var coordinator: ContactRefreshCoordinator?
    @State private var isShowingOnboarding = false
    @State private var refreshSummary: String?

    public init() {}

    public var body: some View {
        Section("Contacts") {
            if let contacts = services?.contacts {
                Toggle("Use my address book", isOn: enabledBinding)
                    .accessibilityHint("Links people in Elephruit to your existing contacts")

                Text("""
                    Elephruit can use the contacts already on this Mac as the starting point for \
                    People. It only ever reads them. Your notes, reflections, relationship history, \
                    tasks, and tags stay here and are never written into Contacts.
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
        .task {
            guard coordinator == nil, let services else { return }
            let created = ContactRefreshCoordinator(services: services)
            created.refreshCounts()
            coordinator = created
        }
        .sheet(isPresented: $isShowingOnboarding) {
            ContactOnboardingView(navigation: NavigationModel())
        }
    }

    @ViewBuilder
    private func authorizationState(_ contacts: ContactsService) -> some View {
        switch contacts.authorization {
        case .authorized:
            statusRows(contacts)
            accountRows(contacts)
            conflictRows()
            actionRow(contacts)

        case .denied, .restricted:
            // macOS records the answer permanently, so a "try again" button here would show no
            // prompt and read as broken. Saying where the switch actually is respects the user's
            // time more than a button that cannot work.
            Label(
                contacts.authorization == .restricted
                    ? "Contacts access is managed on this Mac and cannot be turned on here."
                    : "Access was refused. You can change it in System Settings ▸ Privacy & Security ▸ Contacts.",
                systemImage: "exclamationmark.triangle"
            )
            .font(Theme.Text.metadata)
            .foregroundStyle(Theme.Colors.warning)
            .fixedSize(horizontal: false, vertical: true)

            if let coordinator, coordinator.linkedCount > 0 {
                Text("""
                    \(coordinator.linkedCount) linked \(coordinator.linkedCount == 1 ? "person is" : "people are") \
                    kept, with everything you recorded about them. Their contact details can no \
                    longer refresh.
                    """)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if contacts.authorization == .denied {
                Button("Open System Settings") { ContactPrivacySettings.open() }
            }

        case .notRequested, .unavailable:
            Button("Set up Contacts…") { isShowingOnboarding = true }
        }
    }

    @ViewBuilder
    private func statusRows(_ contacts: ContactsService) -> some View {
        if let coordinator {
            LabeledContent("Status") {
                Text(coordinator.statusSummary)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
        }

        LabeledContent("Last refresh") {
            Text(
                contacts.lastRefreshedAt
                    .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never"
            )
            .font(Theme.Text.metadata)
            .foregroundStyle(Theme.Colors.secondaryText)
        }

        if let refreshSummary {
            Text(refreshSummary)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.completed)
        }
    }

    @ViewBuilder
    private func accountRows(_ contacts: ContactsService) -> some View {
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
                            .help("Read-only. Elephruit never writes to any account, so this changes nothing.")
                    }
                }
                .font(Theme.Text.rowSubtitle)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(account.name), \(account.contactCount) contacts")
            }
        }
    }

    @ViewBuilder
    private func conflictRows() -> some View {
        if let coordinator, !coordinator.conflicts.isEmpty {
            Text("Values you changed here that Contacts now disagrees with")
                .font(Theme.Text.sectionHeader)
                .foregroundStyle(Theme.Colors.secondaryText)

            ForEach(coordinator.conflicts) { conflict in
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text("\(conflict.personName) — \(conflict.summary)")
                        .font(Theme.Text.metadata)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: Theme.Spacing.small) {
                        Button("Keep mine") { coordinator.keepLocalValue(for: conflict.id) }
                            .controlSize(.small)
                        Button("Use the one from Contacts") { coordinator.takeSystemValue(for: conflict.id) }
                            .controlSize(.small)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Disagreement for \(conflict.personName). \(conflict.summary)")
            }
        }
    }

    @ViewBuilder
    private func actionRow(_ contacts: ContactsService) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Button("Refresh Contacts") { refresh() }
                .disabled(coordinator?.isRunning == true)

            Button("Import Contacts…") { isShowingOnboarding = true }
                .help("Nothing already added will be added twice")

            if coordinator?.isRunning == true {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func refresh() {
        guard let coordinator else { return }
        Task {
            let report = await coordinator.refresh()
            refreshSummary = report.summary
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { services?.contacts.isEnabled ?? false },
            set: { isOn in
                guard let contacts = services?.contacts else { return }
                if isOn {
                    // The explanation first, then the prompt — never the other way round.
                    isShowingOnboarding = true
                } else {
                    contacts.disable()
                    // Links stay; they simply stop refreshing, and every one says so.
                    try? services?.contactSync.markAllUnreadable()
                    coordinator?.refreshCounts()
                }
            }
        )
    }
}
