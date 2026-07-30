import ElephruitCore
import ElephruitDesign
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// Home: what today is.
///
/// ### Why this is not just Today with extras
/// Today answers "what is due". Home answers "what is happening" — which includes work that is due,
/// but also the meetings that will take the time to do it in, the day's own note, and what is waiting
/// on someone else. Those are different questions, and a list sorted by due date cannot express the
/// second one.
///
/// Everything here is a **summary with a way through to the real thing**. Nothing is edited on this
/// screen, because a dashboard that is also an editor becomes a worse version of both.
public struct HomeView: View {
    @Environment(\.services) private var services

    private let navigation: NavigationModel

    @State private var dueToday: [Item] = []
    @State private var overdue: [Item] = []
    @State private var events: [CalendarEventSummary] = []
    @State private var dailyEntry: Item?
    @State private var followUps: [FollowUpSuggestion] = []
    @State private var runningTimerTitle: String?
    @State private var reloadTick = 0

    public init(navigation: NavigationModel) {
        self.navigation = navigation
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                greeting

                if !overdue.isEmpty {
                    section("Overdue", count: overdue.count, tone: .attention) {
                        ForEach(overdue.prefix(5), id: \.id) { item in
                            homeRow(item)
                        }
                    }
                }

                if !events.isEmpty {
                    section("Today's calendar", count: events.count) {
                        ForEach(events) { event in
                            CalendarEventRow(
                                event: event,
                                dateProvider: services?.dateProvider ?? SystemDateProvider(),
                                onLink: nil
                            )
                        }
                    }
                }

                if !dueToday.isEmpty {
                    section("Due today", count: dueToday.count) {
                        ForEach(dueToday.prefix(8), id: \.id) { item in
                            homeRow(item)
                        }
                    }
                }

                dailyEntrySection

                if !followUps.isEmpty {
                    followUpSection
                }

                if isEmpty {
                    EmptyStateView(
                        symbolName: "sun.max",
                        headline: "Nothing needs you right now",
                        message: "No overdue work, nothing due today, and no meetings. "
                            + "A good moment to pick something from Upcoming.",
                        tone: .accomplished
                    )
                    .padding(.top, Theme.Spacing.section)
                }
            }
            .padding(Theme.Spacing.large)
        }
        .navigationTitle("Home")
        .navigationSubtitle(subtitle)
        .task(id: reloadTick) { await reload() }
        .accessibilityIdentifier(AccessibilityID.Home.root)
    }

    // MARK: - Sections

    private var greeting: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(dateDescription)
                .font(.system(.largeTitle, design: .rounded, weight: .medium))

            if let runningTimerTitle {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "record.circle")
                        .foregroundStyle(Theme.Colors.destructive)
                    Text("Timing “\(runningTimerTitle)”")
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                    Text(services?.timer.elapsedDisplay ?? "")
                        .font(Theme.Text.rowSubtitle)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }
        }
    }

    @ViewBuilder
    private var dailyEntrySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionHeader("Today's note", count: nil)

            if let dailyEntry {
                Button {
                    navigation.selectItem(dailyEntry.id)
                } label: {
                    VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                        Text(dailyEntry.body.isEmpty ? "Empty so far" : TextNormalizer.excerpt(from: dailyEntry.body))
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(dailyEntry.body.isEmpty
                                ? Theme.Colors.tertiaryText
                                : Theme.Colors.primaryText)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } else {
                // Created on request, never automatically. An app that silently makes a note every
                // morning fills a library with empty days.
                Button("Start today's note") { createDailyEntry() }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier(AccessibilityID.Home.startDailyNote)
            }
        }
    }

    /// Suggestions, and nothing more.
    ///
    /// No task is created, no reminder scheduled, no notification sent. It says what is true and
    /// offers a way to act — the standing rule that a suggestion never makes the decision.
    private var followUpSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionHeader("Might be worth a word", count: followUps.count)

            ForEach(followUps.prefix(3)) { suggestion in
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "person")
                        .foregroundStyle(Theme.Colors.tertiaryText)

                    Button(suggestion.displayName) { navigation.selectItem(suggestion.personID) }
                        .buttonStyle(.link)

                    Text("\(suggestion.daysSinceContact) days")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)

                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(suggestion.message)
            }
        }
        .accessibilityIdentifier(AccessibilityID.Home.followUps)
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        count: Int?,
        tone: SectionTone = .normal,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                SectionHeader(title, count: count)
                if tone == .attention {
                    Image(systemName: "exclamationmark.circle")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.overdue)
                        .accessibilityHidden(true)
                }
            }
            content()
        }
    }

    private enum SectionTone {
        case normal
        case attention
    }

    private func homeRow(_ item: Item) -> some View {
        Button {
            navigation.selectItem(item.id)
        } label: {
            ItemRow(
                item: item,
                dateProvider: services?.dateProvider ?? SystemDateProvider(),
                showsParent: true,
                onToggleStatus: item.kind.supportsStatus ? { toggle(item) } : nil
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    private var isEmpty: Bool {
        overdue.isEmpty && dueToday.isEmpty && events.isEmpty && followUps.isEmpty
    }

    private var dateDescription: String {
        let clock = services?.dateProvider ?? SystemDateProvider()
        return clock.now.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private var subtitle: String {
        var parts: [String] = []
        if !overdue.isEmpty { parts.append("\(overdue.count) overdue") }
        if !dueToday.isEmpty { parts.append("\(dueToday.count) due today") }
        if !events.isEmpty { parts.append(events.count == 1 ? "1 meeting" : "\(events.count) meetings") }
        return parts.isEmpty ? "Clear" : parts.joined(separator: " · ")
    }

    private func reload() async {
        guard let services else { return }
        let clock = services.dateProvider

        services.perform {
            // `ItemQuery.today` already includes anything overdue — that is what makes Today a
            // usable list — so the split happens here rather than as two store queries.
            let todayAndOverdue = try services.items.items(matching: .today(using: clock))
            overdue = todayAndOverdue.filter { $0.isOverdue(using: clock) }

            let overdueIDs = Set(overdue.map(\.id))
            dueToday = todayAndOverdue.filter { !overdueIDs.contains($0.id) }

            dailyEntry = try services.people.dailyEntry(for: clock.now, creatingIfNeeded: false)

            followUps = services.showsFollowUpSuggestions
                ? try services.people.followUpSuggestions(thresholdDays: services.followUpThresholdDays)
                : []
        }

        runningTimerTitle = services.timer.running?.displayTitle

        if services.calendar.isEnabled {
            await services.calendar.load(range: clock.startOfToday..<clock.startOfDay(daysFromToday: 1))
            events = services.calendar.events(on: clock.startOfToday)
        } else {
            events = []
        }
    }

    // MARK: - Actions

    private func createDailyEntry() {
        guard let services else { return }
        services.perform {
            let entry = try services.people.dailyEntry(for: services.dateProvider.now, creatingIfNeeded: true)
            if let entry { navigation.selectItem(entry.id) }
        }
        reloadTick += 1
    }

    private func toggle(_ item: Item) {
        guard let services else { return }
        services.perform { try services.items.toggleCompletion(item) }
        services.noteChange(to: item)
        reloadTick += 1
    }
}
