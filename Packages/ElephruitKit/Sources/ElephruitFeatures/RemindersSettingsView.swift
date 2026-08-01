import ElephruitCore
import ElephruitDesign
import ElephruitPersistence
import SwiftUI

/// Where Apple Reminders is turned on, explained, and scoped.
///
/// ### The explanation comes before the prompt, always
/// macOS records a permission decision **permanently**. A prompt that arrives before the user knows
/// what it is for is a decision they cannot revisit inside the app — the only way back is System
/// Settings, and most people never find it. So the five paragraphs are on screen first, and the
/// button that triggers the prompt is beneath them.
public struct RemindersSettingsSection: View {
    @Environment(\.services) private var services
    @State private var isWorking = false

    public init() {}

    public var body: some View {
        Section {
            if let services {
                content(services)
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text(services?.reminders.permissionAdvice ?? "")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
        }
        .task { await services?.reminders.refresh() }
    }

    @ViewBuilder
    private func content(_ services: AppServices) -> some View {
        if services.reminders.isEnabled, services.reminders.authorization.canRead {
            connected(services)
        } else {
            explanation(services)
        }
    }

    // MARK: - Before

    private func explanation(_ services: AppServices) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            ForEach(RemindersService.explanation, id: \.headline) { paragraph in
                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    Text(paragraph.headline)
                        .font(.system(.body, design: .default, weight: .medium))
                    Text(paragraph.detail)
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: Theme.Spacing.medium) {
                Button("Connect Reminders…") {
                    Task {
                        isWorking = true
                        defer { isWorking = false }
                        await services.reminders.enable()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || services.reminders.authorization == .denied)
                .accessibilityIdentifier("settings.reminders.connect")

                if services.reminders.authorization == .denied {
                    Button("Open Privacy Settings") { openPrivacySettings() }
                        .buttonStyle(.borderless)
                        .help("macOS keeps this decision, so it can only be changed there")
                }
            }
        }
        .padding(.vertical, Theme.Spacing.small)
    }

    // MARK: - After

    private func connected(_ services: AppServices) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if services.reminders.lists.isEmpty {
                Label(
                    "No reminder lists were found on this Mac.",
                    systemImage: "tray"
                )
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
            } else {
                Text("Lists that take part")
                    .font(.system(.body, design: .default, weight: .medium))

                ForEach(services.reminders.lists) { list in
                    Toggle(isOn: participationBinding(for: list, services: services)) {
                        HStack(spacing: Theme.Spacing.tight) {
                            Text(list.title)
                            Text(list.accountName)
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                            if list.isReadOnly {
                                Label("Read-only", systemImage: "lock")
                                    .labelStyle(.titleAndIcon)
                                    .font(Theme.Text.metadata)
                                    .foregroundStyle(Theme.Colors.secondaryText)
                            }
                        }
                    }
                    .accessibilityIdentifier("settings.reminders.list.\(list.id)")
                }
            }

            appOnlyFields

            HStack(spacing: Theme.Spacing.medium) {
                Button("Sync Now") {
                    Task { await services.reminders.sync(using: services.reminderSync) }
                }
                .disabled(services.reminders.isSyncing)

                // Three different things, said differently, because they mean different things:
                // a pass in flight, a pass that failed, and the last one that worked. Showing only
                // the summary — which is what this did — leaves a failed sync looking identical to
                // a quiet one, and leaves a working integration with nothing to say it is working.
                if services.reminders.isSyncing {
                    HStack(spacing: Theme.Spacing.tight) {
                        ProgressView().controlSize(.small)
                        Text("Syncing…")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Syncing")
                } else if let failure = services.reminders.lastReport?.failures.first {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.warning)
                        .lineLimit(2)
                } else if let report = services.reminders.lastReport {
                    Text(report.summary)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }

                Spacer()

                Button("Disconnect", role: .destructive) { services.reminders.disable() }
                    .help("Stops syncing. Tasks already linked keep their notes, links, and history.")
            }
        }
        .padding(.vertical, Theme.Spacing.small)
    }

    /// The honest version of "some things will not sync": a list the user can read.
    private var appOnlyFields: some View {
        DetailDisclosure(
            title: "What stays in Elephruit",
            count: ReminderFieldMapping.appOnlyFields.count,
            systemImage: "lock.shield"
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                ForEach(ReminderFieldMapping.appOnlyFields, id: \.field) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                        Text(entry.field)
                            .font(Theme.Text.rowSubtitle)
                            .frame(width: 200, alignment: .leading)
                        Text(entry.reason)
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func participationBinding(
        for list: ReminderListSummary,
        services: AppServices
    ) -> Binding<Bool> {
        Binding(
            get: { services.reminders.participatingListIDs.contains(list.id) },
            set: { isParticipating in
                services.reminders.setParticipating(isParticipating, listID: list.id)

                // Ticking a list is the request. Leaving the import until somebody also finds "Sync
                // Now" makes the switch look broken — it reports the list as taking part while none
                // of its reminders are anywhere to be seen.
                //
                // Only on the way *on*. Unticking a list is not a reason to run a pass, and
                // certainly not a reason to remove anything: tasks already imported from it keep
                // their links, exactly as they do when the whole integration is switched off.
                guard isParticipating else { return }
                Task { await services.reminders.sync(using: services.reminderSync) }
            }
        )
    }

    private func openPrivacySettings() {
        // The one place a recorded decision can actually be changed. Offering anything else would be
        // a button that does nothing.
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
