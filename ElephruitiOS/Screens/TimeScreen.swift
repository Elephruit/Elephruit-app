import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// Tracked time: the timer, the log, and the report — two surfaces under one segmented
/// control, because two destinations do not earn a sidebar. (That is a rule from the Mac
/// audit, and this screen is where it is kept.)
struct TimeScreen: View {
    @Environment(\.services) private var services
    @Environment(MobileShellModel.self) private var shell

    enum Surface: String, CaseIterable {
        case log = "Log"
        case report = "Report"
    }

    @State private var surface: Surface = .log
    @State private var window: TimeWindow = .today
    @State private var grouping: TimeGrouping = .item
    /// Report-only, and never applied to the store: an entry that ran for fifty-one minutes ran
    /// for fifty-one minutes. See `docs/29` — rounding is a way of *reading* time, not a way of
    /// recording it.
    @State private var rounding: TimeRounding = .exact
    @State private var isAddingEntry = false
    @State private var editingEntry: TimeEntry?

    var body: some View {
        List {
            timerSection
            recoverySection

            switch surface {
            case .log: logSections
            case .report: reportSections
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Time")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Surface", selection: $surface) {
                    ForEach(Surface.allCases, id: \.self) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Period", selection: $window) {
                        ForEach(TimeWindow.allCases, id: \.self) { window in
                            Text(window.displayName).tag(window)
                        }
                    }
                    if surface == .report {
                        Picker("Group by", selection: $grouping) {
                            Text("Item").tag(TimeGrouping.item)
                            Text("Project").tag(TimeGrouping.project)
                            Text("Tag").tag(TimeGrouping.tag)
                            Text("Day").tag(TimeGrouping.day)
                            Text("Person").tag(TimeGrouping.person)
                        }
                        .accessibilityIdentifier(AccessibilityID.Time.groupingPicker)

                        Picker("Rounding", selection: $rounding) {
                            ForEach(TimeRounding.allCases, id: \.self) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .accessibilityIdentifier(AccessibilityID.Time.reportRoundingPicker)
                    }
                    Divider()
                    Button("Add Entry", systemImage: "plus") { isAddingEntry = true }
                } label: {
                    Label("Options", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(isPresented: $isAddingEntry) {
            ManualEntrySheet()
        }
        .sheet(item: $editingEntry) { entry in
            EditEntrySheet(entry: entry)
        }
    }

    // MARK: - Timer

    private var timerSection: some View {
        // The whole tracker, not a summary of it: naming, filing, pausing and discarding are
        // what turn a stretch of time into a record worth keeping, and a phone that could only
        // start and stop produced entries somebody had to reconstruct at a desk later.
        Section {
            MobileTimerCard()
        }
    }

    /// A timer found running from a previous session, waiting for the user's decision.
    /// Never resolved by the app — the three choices destroy different things.
    @ViewBuilder
    private var recoverySection: some View {
        if let services, let recovery = services.timer.pendingRecovery {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    Label {
                        Text("A timer was running when the app last stopped")
                            .font(Theme.Text.rowTitle)
                    } icon: {
                        Image(systemName: "clock.badge.questionmark")
                            .foregroundStyle(Theme.Colors.warning)
                    }
                    Text("“\(recovery.entryDescription.isEmpty ? (recovery.itemTitle ?? "Untitled") : recovery.entryDescription)” — unaccounted for \(TimeFormatting.spelled(recovery.unaccountedFor)).")
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)

                    HStack {
                        Button("Stop at Last Activity") {
                            services.timer.resolveRecovery(.stopAtLastActivity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Keep Running") {
                            services.timer.resolveRecovery(.keepRunning)
                        }
                        .buttonStyle(.bordered)
                        Button("Discard", role: .destructive) {
                            services.timer.resolveRecovery(.discard)
                        }
                        .buttonStyle(.bordered)
                    }
                    .font(Theme.Text.metadata)
                }
                .padding(.vertical, Theme.Spacing.tight)
            }
        }
    }

    // MARK: - Log

    @ViewBuilder
    private var logSections: some View {
        if let services {
            let range = TimePeriod.window(window).range(using: services.dateProvider)
            let entries = loggedEntries(in: range, services: services)

            Section {
                ForEach(entries, id: \.id) { entry in
                    logRow(entry, services: services)
                }
                if entries.isEmpty {
                    EmptyStateView(
                        symbolName: "clock",
                        headline: "Nothing tracked \(window.displayName.lowercased())",
                        message: "Start a timer above, or add an entry from the menu."
                    )
                    .listRowBackground(Color.clear)
                }
            } header: {
                if !entries.isEmpty {
                    let total = entries.reduce(0.0) { $0 + $1.duration(at: services.dateProvider.now) }
                    Text("\(window.displayName) · \(TimeFormatting.short(total))")
                }
            }
        }
    }

    /// The day's entries, re-read whenever anything could have changed them.
    ///
    /// ### Why the two reads above the fetch are load-bearing
    /// A fetch is a plain function call. SwiftUI has no way to know its answer went stale, so a
    /// list built from one only refreshes when something *else* the body read changes. This body
    /// used to read the timer's ticking `elapsedDisplay`, which invalidated it every second — so
    /// the log looked live while costing a full re-read of the day once a second, and stopped
    /// looking live the moment the clock moved into the card. Reading the change token and the
    /// running entry's identity says exactly what this list actually depends on: a write
    /// somebody made, and a timer starting or stopping.
    private func loggedEntries(in range: Range<Date>, services: AppServices) -> [TimeEntry] {
        _ = services.changeToken
        _ = services.timer.running?.id
        return (try? services.timeEntries.entries(in: range, limit: 500)) ?? []
    }

    /// The same subscription the log takes out, for the same reason.
    private func reportSnapshots(in range: Range<Date>, services: AppServices) -> [TimeEntrySnapshot] {
        _ = services.changeToken
        _ = services.timer.running?.id
        return (try? services.timeEntries.snapshots(in: range, limit: nil)) ?? []
    }

    private func logRow(_ entry: TimeEntry, services: AppServices) -> some View {
        let snapshot = entry.snapshot(at: services.dateProvider.now)
        return HStack(spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(snapshot.displayTitle)
                    .font(Theme.Text.rowTitle)
                    .lineLimit(1)
                HStack(spacing: Theme.Spacing.tight) {
                    Text(entry.startedAt.formatted(date: .omitted, time: .shortened))
                    if let ended = entry.endedAt {
                        Text("– \(ended.formatted(date: .omitted, time: .shortened))")
                    } else {
                        Text("– running")
                            .foregroundStyle(Theme.Colors.selection)
                    }
                    if let project = snapshot.projectTitle {
                        Text("· \(project)")
                    }
                }
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
            }
            Spacer()
            Text(TimeFormatting.short(snapshot.duration(at: services.dateProvider.now)))
                .font(Theme.Text.metadata)
                .monospacedDigit()
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture { editingEntry = entry }
        .swipeActions(edge: .leading) {
            if entry.endedAt != nil {
                Button {
                    _ = services.timer.resume(entry)
                    services.noteTimeChange()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .tint(Theme.Colors.completed)
            }
        }
        .swipeActions(edge: .trailing) {
            Button {
                services.perform { try services.timeEntries.delete(entry) }
                services.noteTimeChange()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(Theme.Colors.destructive)
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { editingEntry = entry }
            if entry.endedAt != nil {
                Button("Resume", systemImage: "play.fill") {
                    _ = services.timer.resume(entry)
                    services.noteTimeChange()
                }
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    services.perform { _ = try services.timeEntries.duplicate(entry) }
                    services.noteTimeChange()
                }
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                services.perform { try services.timeEntries.delete(entry) }
                services.noteTimeChange()
            }
        }
    }

    // MARK: - Report

    @ViewBuilder
    private var reportSections: some View {
        if let services {
            let range = TimePeriod.window(window).range(using: services.dateProvider)
            let snapshots = reportSnapshots(in: range, services: services)
            let report = TimeReporting.report(
                entries: snapshots,
                grouping: grouping,
                range: range,
                calendar: services.dateProvider.calendar,
                now: services.dateProvider.now,
                rounding: rounding
            )

            Section {
                if report.isEmpty {
                    EmptyStateView(
                        symbolName: "chart.bar",
                        headline: "Nothing to report",
                        message: "Tracked time in \(window.displayName.lowercased()) will be summed here."
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(report.rows, id: \.key) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                                Text(row.title)
                                    .font(Theme.Text.rowTitle)
                                    .lineLimit(1)
                                // A quiet proportion bar; the number beside it carries
                                // the exact value, so the bar never has to.
                                GeometryReader { proxy in
                                    Capsule()
                                        .fill(Theme.Colors.selection.opacity(0.35))
                                        .frame(
                                            width: max(
                                                4,
                                                proxy.size.width * (report.peak > 0 ? row.total / report.peak : 0)
                                            ),
                                            height: 4
                                        )
                                }
                                .frame(height: 4)
                            }
                            Spacer()
                            Text(TimeFormatting.short(row.total))
                                .font(Theme.Text.metadata)
                                .monospacedDigit()
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let itemID = row.itemID {
                                shell.push(.item(itemID))
                            }
                        }
                    }
                }
            } header: {
                if !report.isEmpty {
                    Text("\(window.displayName) · \(TimeFormatting.short(report.total)) total")
                }
            }

            if !report.isEmpty {
                exportSection(report: report, snapshots: snapshots, services: services)
            }
        }
    }

    /// Both shapes of the same period, because they answer different questions: the rows are what
    /// a client asks for when they want to see the work, and the summary is what goes at the
    /// bottom of an invoice. The Mac offers both from its report toolbar; a phone shares them.
    private func exportSection(
        report: TimeReport,
        snapshots: [TimeEntrySnapshot],
        services: AppServices
    ) -> some View {
        Section {
            ShareLink(
                item: csv(
                    TimeExport.rows(for: snapshots, rounding: rounding, now: services.dateProvider.now),
                    named: TimeExport.filename(for: window.displayName, kind: "entries")
                ),
                preview: SharePreview("Tracked time — every entry")
            ) {
                Label("Share Every Entry", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier(AccessibilityID.Time.reportExportButton)

            ShareLink(
                item: csv(
                    TimeExport.summary(for: report, grouping: grouping),
                    named: TimeExport.filename(for: window.displayName, kind: "summary")
                ),
                preview: SharePreview("Tracked time — totals")
            ) {
                Label("Share the Totals", systemImage: "square.and.arrow.up")
            }
        } footer: {
            Text("CSV, rounded as shown above. The store always keeps the exact time.")
        }
    }

    /// A CSV written where the share sheet can reach it.
    ///
    /// In the temporary directory rather than the container: an export is a copy handed to
    /// another application, and keeping one afterwards would leave the library's contents lying
    /// about in a second place that nothing ever tidies.
    private func csv(_ contents: String, named name: String) -> URL {
        let url = URL.temporaryDirectory.appending(path: name, directoryHint: .notDirectory)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

// MARK: - Entry sheets

/// Adding time that happened off the clock.
///
/// It files exactly as a timer does. An hour typed in on the train is the same hour as an hour
/// measured at a desk, and a sheet that could only record its length would put it in the log as
/// something nobody can report on — which is how a month's totals end up with a category called
/// "untitled" that is larger than any real one.
struct ManualEntrySheet: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var descriptionText = ""
    @State private var startedAt = Date().addingTimeInterval(-3600)
    @State private var endedAt = Date()
    @State private var filing = TimeEntryFiling()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What was the time spent on?", text: $descriptionText)
                    DatePicker("From", selection: $startedAt)
                    DatePicker("To", selection: $endedAt, in: startedAt...)
                }

                TimeFilingSection(filing: $filing)
            }
            .navigationTitle("Add Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(endedAt <= startedAt)
                        .accessibilityIdentifier(AccessibilityID.Time.manualAddButton)
                }
            }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier(AccessibilityID.Time.manualSheet)
    }

    private func add() {
        guard let services else { return }
        services.perform {
            _ = try services.timeEntries.addManual(
                item: filing.subject.flatMap { filing.item($0, in: services) },
                project: filing.project.flatMap { filing.item($0, in: services) },
                people: filing.people.compactMap { filing.item($0, in: services) },
                description: descriptionText.trimmingCharacters(in: .whitespaces),
                startedAt: startedAt,
                endedAt: endedAt,
                tagSlugs: filing.tagSlugs,
                isBillable: filing.isBillable
            )
        }
        services.noteTimeChange()
        dismiss()
    }
}

/// Correcting an entry: what, when, and how long.
struct EditEntrySheet: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    let entry: TimeEntry

    @State private var descriptionText = ""
    @State private var startedAt = Date()
    @State private var endedAt = Date()
    @State private var filing = TimeEntryFiling()
    @State private var hasPrepared = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Description", text: $descriptionText)
                    DatePicker("From", selection: $startedAt)
                    if entry.endedAt != nil {
                        DatePicker("To", selection: $endedAt, in: startedAt...)
                    }
                }

                TimeFilingSection(filing: $filing)
            }
            .navigationTitle("Edit Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .task {
                guard !hasPrepared else { return }
                hasPrepared = true
                descriptionText = entry.entryDescription
                startedAt = entry.startedAt
                endedAt = entry.endedAt ?? Date()
                filing = TimeEntryFiling(entry)
            }
        }
        .presentationDetents([.large])
    }

    private func save() {
        guard let services else { return }
        services.perform {
            try services.timeEntries.update(entry) { live in
                live.entryDescription = descriptionText
                live.startedAt = startedAt
                if live.endedAt != nil { live.endedAt = endedAt }
                live.isBillable = filing.isBillable
                live.item = filing.subject.flatMap { filing.item($0, in: services) }
            }
            // Each through its own method rather than inside the block above: a project has to
            // be refused when it is not one, people are filtered to records, and tags are
            // coined if they do not exist yet. All three rules live in the repository.
            try services.timeEntries.setProject(
                filing.project.flatMap { filing.item($0, in: services) },
                on: entry
            )
            try services.timeEntries.setPeople(
                filing.people.compactMap { filing.item($0, in: services) },
                on: entry
            )
            try services.timeEntries.setTags(filing.tagSlugs, on: entry)
        }
        services.timer.refresh()
        services.noteTimeChange()
        dismiss()
    }
}

// MARK: - The accessory above the tab bar

/// The running timer, visible from every tab. Tap for Time; the stop button is right
/// there, because "stop tracking" should never require a journey.
struct TimerAccessoryView: View {
    @Environment(\.services) private var services
    @Environment(MobileShellModel.self) private var shell

    var body: some View {
        if let services, let running = services.timer.running {
            Button {
                shell.push(.time)
            } label: {
                HStack(spacing: Theme.Spacing.small) {
                    // No pulse: a repeating symbol effect keeps the display link alive for
                    // the whole session, and the timer's ticking digits already say "live".
                    Image(systemName: "record.circle")
                        .foregroundStyle(Theme.Colors.recording)
                    Text(running.displayTitle)
                        .font(Theme.Text.rowSubtitle)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Spacing.small)
                    Text(services.timer.elapsedDisplay)
                        .font(Theme.Text.rowSubtitle)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Button {
                        _ = services.timer.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop timer")
                }
                .padding(.horizontal, Theme.Spacing.medium)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Timer running: \(running.displayTitle), \(services.timer.elapsedDisplay)")
        }
    }
}
