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

                if let report = services.reminders.lastReport {
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
            set: { services.reminders.setParticipating($0, listID: list.id) }
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
