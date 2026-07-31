import ElephruitCore
import ElephruitDesign
import SwiftUI

/// The calendar's preferences.
///
/// Everything here is per-device: which calendar the app may read, what zone the grid is drawn in,
/// which zones are worth showing beside it, and whether week numbers appear. None of it is content,
/// so none of it is in the store — see `docs/03-storage-matrix.md`.
public struct CalendarPreferencesSection: View {
    private let services: AppServices

    @AppStorage("calendar.showsWeekNumbers") private var showsWeekNumbers = false

    @State private var isShowingZonePicker = false
    @State private var cacheStatistics: (events: Int, lastIndexedAt: Date?)?

    public init(services: AppServices) {
        self.services = services
    }

    public var body: some View {
        Group {
            CalendarSettingsSection(calendar: services.calendar)

            if services.calendar.isEnabled, services.calendar.authorization.canRead {
                Toggle("Show week numbers", isOn: $showsWeekNumbers)

                Picker("Weeks start on", selection: firstWeekdayBinding) {
                    Text("Follow my region").tag(0)
                    ForEach(1...7, id: \.self) { weekday in
                        Text(weekdayName(weekday)).tag(weekday)
                    }
                }

                timeZones
                travelMode
                cache
            }
        }
        .task { await refreshStatistics() }
    }

    // MARK: Time zones

    private var timeZones: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Picker("Show times in", selection: displayZoneBinding) {
                Text("Wherever I am").tag("")
                ForEach(zoneChoices, id: \.self) { identifier in
                    Text(EventPhraseParser.shortZoneName(identifier)).tag(identifier)
                }
            }

            Picker("Second time zone", selection: secondaryZoneBinding) {
                Text("None").tag("")
                ForEach(zoneChoices, id: \.self) { identifier in
                    Text(EventPhraseParser.shortZoneName(identifier)).tag(identifier)
                }
            }

            HStack {
                Text("Favorite zones")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)

                Spacer()

                Button("Add…") { isShowingZonePicker = true }
                    .buttonStyle(.borderless)
                    .font(Theme.Text.metadata)
            }

            if services.calendar.timeZoneDisplay.favouriteZoneIdentifiers.isEmpty {
                Text("None yet. A favorite zone appears in the pickers here, in the editor, and in the ruler.")
                    .font(Theme.Text.keyHint)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(services.calendar.timeZoneDisplay.favouriteZoneIdentifiers, id: \.self) { identifier in
                    HStack {
                        Text(EventPhraseParser.shortZoneName(identifier))
                            .font(Theme.Text.metadata)
                        Text(offsetLabel(identifier))
                            .font(Theme.Text.keyHint)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .monospacedDigit()

                        Spacer()

                        Button {
                            services.calendar.toggleFavourite(zoneIdentifier: identifier)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .accessibilityLabel("Remove \(EventPhraseParser.shortZoneName(identifier))")
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingZonePicker) {
            TimeZonePicker { identifier in
                services.calendar.toggleFavourite(zoneIdentifier: identifier)
                isShowingZonePicker = false
            } onCancel: {
                isShowingZonePicker = false
            }
        }
    }

    /// "GMT+9", read at today rather than as a constant.
    private func offsetLabel(_ identifier: String) -> String {
        guard let zone = TimeZone(identifier: identifier) else { return "" }
        let hours = Double(zone.secondsFromGMT(for: services.dateProvider.now)) / 3_600
        return hours == 0 ? "GMT" : String(format: "GMT%+g", hours)
    }

    // MARK: Travel

    private var travelMode: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Toggle("Travel mode", isOn: travellingBinding)

            Text("""
                Draws the calendar in the zone you are travelling to and says so at the top of the \
                grid. **No event moves.** Turning it off puts the labels back; nothing was changed \
                while it was on.
                """)
            .font(Theme.Text.keyHint)
            .foregroundStyle(Theme.Colors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: The cache

    private var cache: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            if let cacheStatistics {
                LabeledContent("Cached events", value: "\(cacheStatistics.events)")
                if let indexed = cacheStatistics.lastIndexedAt {
                    LabeledContent(
                        "Last read",
                        value: indexed.formatted(date: .abbreviated, time: .shortened)
                    )
                }
            }

            Button("Rebuild Calendar Index") {
                Task {
                    await services.calendarSearch.invalidate()
                    await services.calendarSearch.prepare()
                    await refreshStatistics()
                }
            }
            .controlSize(.small)

            Text("""
                The cache is what makes searching your calendar fast and what the app shows when it \
                cannot reach EventKit. Everything in it comes from your calendar, so rebuilding it \
                cannot lose anything.
                """)
            .font(Theme.Text.keyHint)
            .foregroundStyle(Theme.Colors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refreshStatistics() async {
        cacheStatistics = await services.calendarSearch.statistics()
    }

    // MARK: Bindings

    private func weekdayName(_ weekday: Int) -> String {
        let symbols = services.calendar.displayCalendar.weekdaySymbols
        guard weekday - 1 < symbols.count else { return "" }
        return symbols[weekday - 1]
    }

    private var firstWeekdayBinding: Binding<Int> {
        Binding(
            get: { services.calendar.firstWeekdayOverride ?? 0 },
            set: { services.calendar.firstWeekdayOverride = $0 == 0 ? nil : $0 }
        )
    }

    private var zoneChoices: [String] {
        var choices = services.calendar.timeZoneDisplay.favouriteZoneIdentifiers
        let device = services.calendar.timeZoneDisplay.deviceZoneIdentifier
        if !choices.contains(device) { choices.insert(device, at: 0) }
        return choices
    }

    private var displayZoneBinding: Binding<String> {
        Binding(
            get: { services.calendar.timeZoneDisplay.displayZoneIdentifier ?? "" },
            set: { services.calendar.showTimes(in: $0.isEmpty ? nil : $0) }
        )
    }

    private var secondaryZoneBinding: Binding<String> {
        Binding(
            get: { services.calendar.timeZoneDisplay.secondaryZoneIdentifier ?? "" },
            set: { identifier in
                var display = services.calendar.timeZoneDisplay
                display.secondaryZoneIdentifier = identifier.isEmpty ? nil : identifier
                services.calendar.timeZoneDisplay = display
            }
        )
    }

    private var travellingBinding: Binding<Bool> {
        Binding(
            get: { services.calendar.timeZoneDisplay.isTravelling },
            set: { travelling in
                services.calendar.setTravelling(
                    travelling,
                    destinationZone: travelling
                        ? services.calendar.timeZoneDisplay.favouriteZoneIdentifiers.first
                        : nil
                )
            }
        )
    }
}

/// Choosing a time zone by city.
struct TimeZonePicker: View {
    var onChoose: (String) -> Void
    var onCancel: () -> Void

    @State private var query = ""

    /// Every zone the system knows, filtered as you type.
    ///
    /// Bounded to fifty results, because the unfiltered list is several hundred rows and a picker
    /// nobody can find anything in is a picker that gets closed again.
    private var matches: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        guard !query.isEmpty else { return Array(all.prefix(50)) }

        let folded = TextNormalizer.foldedForMatching(query)
        return Array(
            all.filter { TextNormalizer.foldedForMatching($0.replacingOccurrences(of: "_", with: " ")).contains(folded) }
                .prefix(50)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Add a time zone")
                .font(Theme.Text.title)

            TextField("Search cities", text: $query)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches, id: \.self) { identifier in
                        Button { onChoose(identifier) } label: {
                            HStack {
                                Text(identifier.replacingOccurrences(of: "_", with: " "))
                                    .font(Theme.Text.rowSubtitle)
                                Spacer(minLength: 0)
                                Text(offsetLabel(identifier))
                                    .font(Theme.Text.keyHint)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                            }
                            .contentShape(.rect)
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(extending: Theme.Spacing.small)
                    }
                }
            }
            .frame(height: 260)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 380)
    }

    private func offsetLabel(_ identifier: String) -> String {
        guard let zone = TimeZone(identifier: identifier) else { return "" }
        let hours = Double(zone.secondsFromGMT(for: Date())) / 3_600
        return hours == 0 ? "GMT" : String(format: "GMT%+g", hours)
    }
}
