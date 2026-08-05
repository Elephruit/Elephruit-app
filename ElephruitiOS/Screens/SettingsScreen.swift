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

    /// The working day as this screen has it, once it has been edited here.
    @State private var editedWorkday: WorkdayHours?
    @State private var isChoosingImport = false
    @State private var importSummary: String?
    @State private var importWarnings: [String] = []

    var body: some View {
        List {
            workdaySection
            travelSection
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

    // MARK: - The working day

    /// When the day starts, when it ends, and which days count.
    ///
    /// ### Why this is the first section
    /// Because it is the only setting here that changes a number the app already shows. Today says
    /// how much of the day is free, and until this existed that was measured against nine-to-five,
    /// Monday-to-Friday — an assumption the phone had no way to state and no way to correct.
    ///
    /// A calendar set overrides it while one is active, and the section says so rather than
    /// accepting an edit that would have no effect.
    @ViewBuilder
    private var workdaySection: some View {
        if let services {
            // Held in state as well as written, because the store is not observed here: the record
            // is read once per assembly by the briefing, not published, so a section reading
            // `services.workday` on every pass would show the old hours until something else
            // redrew it.
            let workday = editedWorkday ?? services.workday

            Section {
                if case .calendarSet(let name) = workday.source {
                    LabeledContent("Hours") { Text(workday.summary) }
                    Label(
                        "The “\(name)” calendar set sets these while it is active.",
                        systemImage: "calendar.badge.checkmark"
                    )
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                } else {
                    DatePicker(
                        "Starts",
                        selection: minutesBinding(\.startMinutes, of: workday.hours),
                        displayedComponents: .hourAndMinute
                    )
                    .accessibilityIdentifier(AccessibilityID.Settings.workdayStart)
                    DatePicker(
                        "Ends",
                        selection: minutesBinding(\.endMinutes, of: workday.hours),
                        displayedComponents: .hourAndMinute
                    )
                    .accessibilityIdentifier(AccessibilityID.Settings.workdayEnd)
                    weekdayPicker(workday.hours)
                }
            } header: {
                Text("Working day")
                    .accessibilityIdentifier(AccessibilityID.Settings.workdaySection)
            } footer: {
                Text(
                    workday.source.isChosen
                        ? "How much of your day is free is measured against these hours."
                        : """
                        How much of your day is free is measured against these hours. Nobody has \
                        set them yet, so Elephruit is assuming \(workday.summary).
                        """
                )
            }
        }
    }

    /// How long the app should assume a journey takes, until it is told otherwise about a place.
    ///
    /// ### The number here is the floor, not the fallback
    /// It needs no permission and no network, it is never wrong in a way its owner cannot fix, and
    /// it is what every journey is measured against until somebody switches on route estimates in
    /// Integrations. Even then it is what answers for a place that will not geocode — which, in a
    /// calendar full of meeting rooms, is most of them. So it stays first on this screen.
    ///
    /// The footer changes when estimates are on, because the sentence it used to end with —
    /// "nothing about where you are ever leaves this device" — stops being true at that moment, and
    /// a privacy claim that survives the feature contradicting it is worse than no claim.
    @ViewBuilder
    private var travelSection: some View {
        if let services {
            @Bindable var travel = services.travel

            Section {
                Picker("Allow", selection: $travel.defaultMinutes) {
                    ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { minutes in
                        Text(DurationPhrase.exact(TimeInterval(minutes * 60))).tag(minutes)
                    }
                }
                .accessibilityIdentifier("settings.travel.default")

                // Only when something is actually routing, because until then there is nothing for
                // the answer to be about: a number somebody typed is the same number whether they
                // walked or drove to earn it.
                if travel.isEstimating {
                    Picker("Usually", selection: $travel.transport) {
                        ForEach(RouteTransport.allCases, id: \.self) { transport in
                            Label(transport.label, systemImage: transport.symbolName).tag(transport)
                        }
                    }
                    .accessibilityIdentifier("settings.travel.transport")
                }

                if travel.rememberedPlaceCount > 0 {
                    Button("Forget remembered places", role: .destructive) {
                        travel.forgetAllPlaces()
                    }
                    .accessibilityIdentifier("settings.travel.forget")
                }
            } header: {
                Text("Getting there")
            } footer: {
                Text(travelFooter(travel))
            }
        }
    }

    private func travelFooter(_ travel: TravelPreferences) -> String {
        let remembered = travel.rememberedPlaceCount > 0
            ? "It remembers what you allow for each place — \(travel.rememberedPlaceCount) so far."
            : "It remembers what you allow for each place."

        guard travel.isEstimating else {
            return """
                Used to say when to leave for a meeting somewhere. \(remembered) Nothing about where \
                you are or where you are going ever leaves this device.
                """
        }

        return """
            Used for a place Elephruit could not look up — a meeting room, or anywhere without an \
            address. \(remembered) Everywhere else, the time comes from Apple Maps; see Route \
            estimates below.
            """
    }

    /// Seven toggles, as a row of initials rather than a list of seven switches.
    ///
    /// Weekday numbering is the calendar's own — 1 is Sunday — and so are the names, so this is not
    /// the one screen in the app that only speaks English.
    private func weekdayPicker(_ hours: WorkingHours) -> some View {
        HStack(spacing: Theme.Spacing.tight) {
            ForEach(1...7, id: \.self) { weekday in
                let isOn = hours.includes(weekday: weekday)
                Button {
                    var weekdays = hours.weekdays
                    if isOn { weekdays.remove(weekday) } else { weekdays.insert(weekday) }
                    save(WorkingHours(
                        startMinutes: hours.startMinutes,
                        endMinutes: hours.endMinutes,
                        weekdays: weekdays
                    ))
                } label: {
                    Text(WorkdayHours.shortName(weekday))
                        .font(Theme.Text.metadata)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(
                            isOn ? Theme.Colors.selection.opacity(0.18) : Theme.Colors.subtleFill,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        )
                        .foregroundStyle(isOn ? Theme.Colors.selection : Theme.Colors.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(WorkdayHours.shortName(weekday))
                .accessibilityValue(isOn ? "Working" : "Not working")
            }
        }
        .padding(.vertical, Theme.Spacing.tight)
    }

    /// A time picker over minutes-from-midnight.
    ///
    /// `DatePicker` wants a `Date` and `WorkingHours` holds minutes, deliberately — minutes carry no
    /// day, no zone, and no daylight saving, which is what makes "the working day starts at nine"
    /// mean the same thing in March and in November. The conversion is anchored to today's midnight
    /// and is thrown away again immediately.
    private func minutesBinding(
        _ keyPath: WritableKeyPath<WorkingHours, Int>,
        of hours: WorkingHours
    ) -> Binding<Date> {
        let midnight = Calendar.current.startOfDay(for: Date())
        return Binding(
            get: { midnight.addingTimeInterval(TimeInterval(hours[keyPath: keyPath] * 60)) },
            set: { chosen in
                let components = Calendar.current.dateComponents([.hour, .minute], from: chosen)
                let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                var start = hours.startMinutes
                var end = hours.endMinutes

                if keyPath == \WorkingHours.startMinutes {
                    start = minutes
                    // Dragging the start past the end pushes the end along rather than collapsing
                    // the day to nothing, which is what the initialiser's clamp would otherwise do
                    // — and a zero-length working day silently reads as "no time free at all".
                    end = max(end, start + 60)
                } else {
                    end = max(minutes, start + 15)
                }

                save(WorkingHours(startMinutes: start, endMinutes: end, weekdays: hours.weekdays))
            }
        )
    }

    private func save(_ hours: WorkingHours) {
        guard let services else { return }
        editedWorkday = WorkdayHours(hours: hours, source: .appDefault)
        services.perform { try services.workdayHours.setAppDefault(hours) }
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
            // This used to end "Apple's CloudKit is the only thing this app talks to on the
            // network", which stopped being true the day route estimates shipped. Rewritten to be
            // true in *both* states rather than to follow the switch: a claim about privacy that
            // changes as you toggle something is a claim you have to watch, and the point of one is
            // that you do not.
            Text(
                """
                Sync keeps this \(DeviceName.thisDevice) and your Mac looking at one library, through your \
                own private iCloud database. No account with us, no analytics, no third-party \
                service: the only things this app ever talks to are your own iCloud, and Apple \
                Maps if you switch on route estimates.
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
                // Last, and set apart by its own footnote, because it is the only one that is not
                // a permission to read something already on the phone. This one sends an address
                // somewhere, and a row that looked exactly like Calendar's would be hiding that.
                integrationRow(
                    title: "Route estimates",
                    symbol: "location",
                    isEnabled: services.travel.isEstimating,
                    authorization: services.travel.authorization,
                    enable: { _ = await services.travel.enableEstimates() },
                    disable: { services.travel.disableEstimates() }
                )
                .accessibilityIdentifier("settings.integration.routes")
            } header: {
                Text("Integrations")
            } footer: {
                Text("""
                    Each integration is off until you turn it on, and asks the system for permission \
                    only then. Turning one off leaves your Elephruit records exactly as they are.

                    Route estimates is the only one that uses the network. With it on, Elephruit \
                    asks Apple Maps how long it takes to get to a meeting, sending the meeting's \
                    address and your location — and nothing else. Never its name, never who is \
                    coming, never your notes. Your location is not saved, and nothing is looked up \
                    unless Elephruit is open in front of you.
                    """)
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
            // "With sync off, the network is never used at all" was true until route estimates
            // gave it a second way to be used. Both conditions are now named, because the sentence
            // is worth nothing if a reader has to know which features count.
            Text("""
                Your library is yours: no account with us, no analytics, no third-party service. \
                With sync and route estimates both off, the network is never used at all. With \
                sync on, your own iCloud is the only place your library goes; with route estimates \
                on, an address and your location go to Apple Maps and nothing else does.
                """)
        }
    }
}
