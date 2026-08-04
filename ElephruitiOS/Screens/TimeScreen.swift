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

    @ViewBuilder
    private var timerSection: some View {
        if let services {
            let timer = services.timer
            Section {
                if let running = timer.running {
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        HStack {
                            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                                Text(running.displayTitle)
                                    .font(Theme.Text.rowTitle)
                                    .lineLimit(1)
                                Text(timer.elapsedDisplay)
                                    .font(.system(.title2, design: .rounded, weight: .semibold))
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                            }
                            Spacer()
                            Button {
                                _ = timer.stop()
                            } label: {
                                Image(systemName: "stop.fill")
                                    .font(.title3)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityLabel("Stop timer")
                        }
                    }
                    .padding(.vertical, Theme.Spacing.tight)
                } else {
                    Button {
                        _ = services.timer.start(item: nil)
                    } label: {
                        Label("Start a Timer", systemImage: "play.fill")
                    }
                    .accessibilityIdentifier("time.start")
                }
            }
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
            let entries = (try? services.timeEntries.entries(in: range, limit: 500)) ?? []

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
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .tint(Theme.Colors.completed)
            }
        }
        .swipeActions(edge: .trailing) {
            Button {
                services.perform { try services.timeEntries.delete(entry) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(Theme.Colors.destructive)
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { editingEntry = entry }
            if entry.endedAt != nil {
                Button("Resume", systemImage: "play.fill") { _ = services.timer.resume(entry) }
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    services.perform { _ = try services.timeEntries.duplicate(entry) }
                }
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                services.perform { try services.timeEntries.delete(entry) }
            }
        }
    }

    // MARK: - Report

    @ViewBuilder
    private var reportSections: some View {
        if let services {
            let range = TimePeriod.window(window).range(using: services.dateProvider)
            let snapshots = (try? services.timeEntries.snapshots(in: range, limit: nil)) ?? []
            let report = TimeReporting.report(
                entries: snapshots,
                grouping: grouping,
                range: range,
                calendar: services.dateProvider.calendar,
                now: services.dateProvider.now
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
        }
    }
}

// MARK: - Entry sheets

/// Adding time that happened off the clock.
struct ManualEntrySheet: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var descriptionText = ""
    @State private var startedAt = Date().addingTimeInterval(-3600)
    @State private var endedAt = Date()

    var body: some View {
        NavigationStack {
            Form {
                TextField("What was the time spent on?", text: $descriptionText)
                DatePicker("From", selection: $startedAt)
                DatePicker("To", selection: $endedAt, in: startedAt...)
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
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func add() {
        guard let services else { return }
        services.perform {
            _ = try services.timeEntries.addManual(
                item: nil,
                project: nil,
                people: [],
                description: descriptionText.trimmingCharacters(in: .whitespaces),
                startedAt: startedAt,
                endedAt: endedAt,
                tagSlugs: [],
                isBillable: false
            )
        }
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
    @State private var isBillable = false
    @State private var hasPrepared = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Description", text: $descriptionText)
                DatePicker("From", selection: $startedAt)
                if entry.endedAt != nil {
                    DatePicker("To", selection: $endedAt, in: startedAt...)
                }
                Toggle("Billable", isOn: $isBillable)
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
                isBillable = entry.isBillable
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let services else { return }
        services.perform {
            try services.timeEntries.update(entry) { live in
                live.entryDescription = descriptionText
                live.startedAt = startedAt
                if live.endedAt != nil { live.endedAt = endedAt }
                live.isBillable = isBillable
            }
        }
        services.timer.refresh()
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
