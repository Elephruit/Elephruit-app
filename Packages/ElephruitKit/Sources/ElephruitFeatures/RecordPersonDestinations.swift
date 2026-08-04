import ElephruitCore
import ElephruitDesign
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import SwiftUI

// MARK: - Celebrations

/// Birthdays, anniversaries, memorials, and whatever the user has decided to mark.
///
/// A dedicated view rather than a filter on the people list, because the question is temporal — what
/// is coming up — and a list sorted by name answers it badly.
struct CelebrationsView: View {
    @Environment(\.services) private var services

    let navigation: NavigationModel

    @State private var upcoming: [UpcomingCelebration] = []
    @State private var horizonDays = 90

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Celebrations")
                    .font(Theme.Text.title)
                Spacer()
                Picker("Ahead", selection: $horizonDays) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("A year").tag(365)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("How far ahead to look")
            }
            .padding(Theme.Spacing.medium)

            Divider()

            if upcoming.isEmpty {
                EmptyStateView(
                    symbolName: "birthday.cake",
                    headline: "Nothing coming up",
                    message: """
                        Record a birthday or an anniversary on somebody's page and it will appear \
                        here. A birthday with no year is fine — the day is what matters.
                        """
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                        ForEach(months, id: \.month) { group in
                            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                                Text(group.month.formatted(.dateTime.month(.wide).year()))
                                    .font(Theme.Text.sectionHeader)
                                    .foregroundStyle(Theme.Colors.secondaryText)

                                ForEach(group.celebrations) { entry in
                                    CelebrationRow(entry: entry) { navigation.selectItem($0) }
                                }
                            }
                        }
                    }
                    .padding(Theme.Spacing.medium)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.Records.celebrations)
        .task(id: horizonDays) { reload() }
    }

    private var months: [(month: Date, celebrations: [UpcomingCelebration])] {
        CelebrationCalendar.byMonth(upcoming, calendar: services?.dateProvider.calendar ?? .autoupdatingCurrent)
    }

    private func reload() {
        guard let services else { return }
        let all = (try? services.persons.allCelebrations()) ?? []
        upcoming = CelebrationCalendar.upcoming(
            from: all,
            within: horizonDays,
            asOf: services.dateProvider.now,
            calendar: services.dateProvider.calendar
        )
    }
}

struct CelebrationRow: View {
    @Environment(\.services) private var services

    let entry: UpcomingCelebration
    let onOpen: (UUID) -> Void

    @State private var giftIdeas: [String] = []

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            Image(systemName: entry.celebration.kind.symbolName)
                .foregroundStyle(entry.isImminent ? Theme.Colors.dueToday : Theme.Colors.secondaryText)
                .frame(width: Theme.Size.rowGlyph)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 1) {
                Button {
                    onOpen(entry.celebration.personID)
                } label: {
                    Text(entry.summary)
                        .font(entry.isImminent ? Theme.Text.rowTitleEmphasised : Theme.Text.rowTitle)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)

                Text(entry.occursOn.formatted(date: .complete, time: .omitted))
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)

                if entry.isShiftedFromLeapDay {
                    Label("Born on 29 February — shown on the 28th this year.", systemImage: "calendar.badge.exclamationmark")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }

                // Gift ideas, but never on a memorial. An app that suggests buying a present on the
                // anniversary of a death has failed at the only thing this module is for.
                if entry.celebration.kind.isCelebratory, !giftIdeas.isEmpty {
                    Label(giftIdeas.joined(separator: " · "), systemImage: "gift")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.tight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.summary), \(entry.occursOn.formatted(date: .complete, time: .omitted))")
        .task { loadGiftIdeas() }
    }

    private func loadGiftIdeas() {
        guard let services,
              entry.celebration.kind.isCelebratory,
              let person = try? services.persons.person(id: entry.celebration.personID),
              let ledger = try? services.persons.ledger(for: person)
        else { return }
        giftIdeas = ledger.current(.giftIdea).map(\.value)
    }
}

