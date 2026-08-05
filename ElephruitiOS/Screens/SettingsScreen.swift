import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// Settings: the three system integrations, the way out (export), and the honest
/// statement of what this app is — local, per device, no network.
struct SettingsScreen: View {
    @Environment(\.services) private var services

    @AppStorage(SyncSetting.enabledKey) private var syncEnabled = false

    @State private var exportedArchive: URL?
    @State private var exportError: String?

    /// The working day as this screen has it, once it has been edited here.
    @State private var editedWorkday: WorkdayHours?

    var body: some View {
        List {
            workdaySection
            syncSection
            integrationsSection
            remindersListsSection
            exportSection
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
            Text(
                """
                Sync keeps this iPhone and your Mac looking at one library, through your \
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

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version") {
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            }
            LabeledContent("Library") {
                Text("On this iPhone")
            }
        } header: {
            Text("About")
        } footer: {
            Text("Your library is yours: no account with us, no analytics, no third-party service. With sync off, the network is never used at all; with it on, your own iCloud is the only place anything goes.")
        }
    }
}
