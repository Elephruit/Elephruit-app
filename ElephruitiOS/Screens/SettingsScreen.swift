import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import ElephruitTransfer
import SwiftUI
import UniformTypeIdentifiers

/// Settings: the three system integrations, the way in and out, and the honest
/// statement of what this app is — local, per device, no network.
struct SettingsScreen: View {
    @Environment(\.services) private var services

    @AppStorage(SyncSetting.enabledKey) private var syncEnabled = false

    @State private var exportedArchive: URL?
    @State private var exportError: String?

    @State private var isChoosingImport = false
    @State private var importSummary: String?
    @State private var importWarnings: [String] = []

    var body: some View {
        List {
            syncSection
            integrationsSection
            remindersListsSection
            exportSection
            importSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sync

    /// The same switch, the same words, as the Mac's Sync settings — one behavior,
    /// promised in two places.
    private var syncSection: some View {
        Section {
            Toggle(isOn: $syncEnabled) {
                Label("Sync with iCloud", systemImage: "arrow.triangle.2.circlepath.icloud")
            }

            if needsRelaunch {
                Label(
                    syncEnabled
                        ? "Takes effect the next time Elephruit opens."
                        : "Stops at the next launch. Nothing is deleted, here or in iCloud.",
                    systemImage: "arrow.counterclockwise"
                )
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
            }

            LabeledContent("Status") {
                Text(services?.syncStatus.summary ?? SyncStatus.disabled.summary)
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text(
                """
                Sync keeps this \(DeviceName.thisDevice) and your Mac looking at one library, through your \
                own private iCloud database. Apple's CloudKit is the only thing this app \
                talks to on the network — no account with us, no analytics, no third-party \
                service.
                """
            )
        }
    }

    /// The toggle and the running container disagree — the launch boundary is between them.
    private var needsRelaunch: Bool {
        guard let services else { return false }
        return syncEnabled != services.stack.isSyncEnabled
    }

    // MARK: - Integrations

    @ViewBuilder
    private var integrationsSection: some View {
        if let services {
            Section {
                integrationRow(
                    title: "Calendar",
                    symbol: "calendar",
                    isEnabled: services.calendar.isEnabled,
                    authorization: services.calendar.authorization,
                    enable: { _ = await services.calendar.enable() },
                    disable: { services.calendar.disable() }
                )
                integrationRow(
                    title: "Reminders",
                    symbol: "checklist",
                    isEnabled: services.reminders.isEnabled,
                    authorization: services.reminders.authorization,
                    enable: { _ = await services.reminders.enable() },
                    disable: { services.reminders.disable() }
                )
                integrationRow(
                    title: "Contacts",
                    symbol: "person.crop.circle",
                    isEnabled: services.contacts.isEnabled,
                    authorization: services.contacts.authorization,
                    enable: { _ = await services.contacts.enable() },
                    disable: { services.contacts.disable() }
                )
            } header: {
                Text("Integrations")
            } footer: {
                Text("Each integration is off until you turn it on, and asks the system for permission only then. Turning one off leaves your Elephruit records exactly as they are.")
            }
        }
    }

    private func integrationRow(
        title: String,
        symbol: String,
        isEnabled: Bool,
        authorization: IntegrationAuthorization,
        enable: @escaping () async -> Void,
        disable: @escaping () -> Void
    ) -> some View {
        Toggle(isOn: Binding(
            get: { isEnabled },
            set: { turnOn in
                if turnOn {
                    Task { await enable() }
                } else {
                    disable()
                }
            }
        )) {
            Label {
                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    Text(title)
                    if isEnabled, let status = statusLine(authorization) {
                        Text(status)
                            .font(Theme.Text.metadata)
                            .foregroundStyle(
                                authorization == .denied
                                    ? Theme.Colors.warning : Theme.Colors.secondaryText
                            )
                    }
                }
            } icon: {
                Image(systemName: symbol)
            }
        }
    }

    private func statusLine(_ authorization: IntegrationAuthorization) -> String? {
        switch authorization {
        case .authorized: nil
        case .notRequested: "Waiting for permission"
        case .denied: "Denied — allow in Settings › Privacy"
        case .restricted: "Restricted on this device"
        case .unavailable: "Unavailable"
        }
    }

    /// Which Reminders lists take part — opt-in per list, never "all", which is the
    /// sync engine's own safety rule surfaced as UI.
    @ViewBuilder
    private var remindersListsSection: some View {
        if let services, services.reminders.isEnabled, !services.reminders.lists.isEmpty {
            Section {
                ForEach(services.reminders.lists, id: \.id) { list in
                    Toggle(isOn: Binding(
                        get: { services.reminders.participatingListIDs.contains(list.id) },
                        set: { participating in
                            services.reminders.setParticipating(participating, listID: list.id)
                        }
                    )) {
                        Label {
                            Text(list.title)
                        } icon: {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(Theme.Palette.color(named: list.colorName))
                        }
                    }
                }
            } header: {
                Text("Reminders lists")
            } footer: {
                Text("Only the lists you choose here are read or written.")
            }
        }
    }

    // MARK: - Export

    private var exportSection: some View {
        Section {
            Button {
                exportArchive()
            } label: {
                Label("Export Library…", systemImage: "square.and.arrow.up")
            }

            if let exportedArchive {
                ShareLink(item: exportedArchive) {
                    Label("Share \(exportedArchive.lastPathComponent)", systemImage: "doc.zipper")
                }
            }

            if let exportError {
                Label(exportError, systemImage: "exclamationmark.triangle")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.warning)
            }
        } header: {
            Text("Your data")
        } footer: {
            Text("A complete JSON archive — every item, link, tag, and time entry, with identifiers preserved. It round-trips: the Mac app imports it losslessly.")
        }
    }

    private func exportArchive() {
        guard let services else { return }
        exportError = nil
        do {
            let stamp = Date().formatted(.iso8601.year().month().day())
            let destination = FileManager.default.temporaryDirectory
                .appending(path: "Elephruit-\(stamp).json")
            _ = try services.exporter.write(format: .jsonArchive, to: destination)
            exportedArchive = destination
        } catch {
            exportError = error.summary
        }
    }

    // MARK: - Import

    /// The way back in.
    ///
    /// The export section has always promised the archive round-trips — "the Mac app imports it
    /// losslessly" — and until now that promise ran one way: a phone could write a library it
    /// could not read. The same `Importer` the Mac uses does the reading, with the same duplicate
    /// policy, so an archive means the same thing on both platforms.
    private var importSection: some View {
        Section {
            Button {
                isChoosingImport = true
            } label: {
                Label("Import Archive…", systemImage: "square.and.arrow.down")
            }

            if let importSummary {
                Label(importSummary, systemImage: "checkmark.circle")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            // Non-fatal problems are said out loud rather than swallowed: an import that quietly
            // dropped a record is an import you cannot trust the next time.
            ForEach(importWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.warning)
            }
        } footer: {
            Text("Adds the archive's records to this library. Anything already here is left alone — importing the same file twice changes nothing.")
        }
        .fileImporter(
            isPresented: $isChoosingImport,
            allowedContentTypes: [.json],
            allowsMultipleSelection: true
        ) { result in
            importArchives(result)
        }
    }

    private func importArchives(_ result: Result<[URL], any Error>) {
        guard let services else { return }
        importSummary = nil
        importWarnings = []

        switch result {
        case .failure(let error):
            importWarnings = [error.localizedDescription]

        case .success(let urls):
            var reports: [ImportReport] = []
            for url in urls {
                // A file chosen from another app's container is only readable inside a
                // security-scoped access, and the access must be balanced however this exits.
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }

                guard let data = try? Data(contentsOf: url) else {
                    importWarnings.append("“\(url.lastPathComponent)” could not be read.")
                    continue
                }

                // Skip rather than overwrite: an import is not an undoable operation, and
                // replacing a record somebody has since edited is the one outcome they cannot
                // recover from by hand.
                let didImport = services.perform {
                    reports.append(try services.importer.importArchive(data, policy: .skip))
                }
                guard didImport else { return }
            }

            importSummary = reports.map(\.summary).joined(separator: "; ")
            importWarnings.append(contentsOf: reports.flatMap(\.warnings))
            services.refreshDerivedState()
            Task { await services.invalidateAndWarmIndex() }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version") {
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            }
            LabeledContent("Library") {
                Text("On this \(DeviceName.thisDevice)")
            }
        } header: {
            Text("About")
        } footer: {
            Text("Your library is yours: no account with us, no analytics, no third-party service. With sync off, the network is never used at all; with it on, your own iCloud is the only place anything goes.")
        }
    }
}
