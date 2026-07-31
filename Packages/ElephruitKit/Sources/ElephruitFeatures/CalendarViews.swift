import ElephruitCore
import ElephruitDesign
import ElephruitIntegrations
import SwiftUI

/// One event in a day's plan.
///
/// ### Distinct by shape, not by colour alone
/// An event is a *fixed* block of time; a task is something you choose when to do. The row says so
/// structurally — a time range on the leading edge where a task has a status circle — so the
/// difference survives colour-blindness, greyscale, and a glance.
struct CalendarEventRow: View {
    let event: CalendarEventSummary
    let dateProvider: any DateProvider
    let onLink: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            timeColumn

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                HStack(spacing: Theme.Spacing.small) {
                    Text(event.displayTitle)
                        .font(Theme.Text.rowTitle)
                        .strikethrough(event.isCancelled, color: Theme.Colors.tertiaryText)
                        .foregroundStyle(event.isCancelled ? Theme.Colors.secondaryText : Theme.Colors.primaryText)
                        .lineLimit(1)

                    if event.isRecurring {
                        Image(systemName: "repeat")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .accessibilityHidden(true)
                    }
                }

                if let context = contextLine {
                    Text(context)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Theme.Spacing.small)

            if let onLink {
                Button(action: onLink) {
                    Image(systemName: "link")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.secondaryText)
                .help("Make a note about this")
                .accessibilityLabel("Make a note about this event")
            }
        }
        .frame(minHeight: Theme.Size.rowHeight)
        .opacity(event.isCancelled ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityIdentifier(AccessibilityID.Calendar.eventRow(id: event.id))
    }

    /// All-day events get a band rather than a time, because "00:00–23:59" is noise pretending to be
    /// information.
    @ViewBuilder
    private var timeColumn: some View {
        if event.isAllDay {
            Text("All day")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
                .padding(.horizontal, Theme.Spacing.tight)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill(Theme.Colors.subtleFill)
                )
                .frame(width: 62, alignment: .leading)
        } else {
            Text(event.startAt.formatted(date: .omitted, time: .shortened))
                .font(Theme.Text.metadata)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.secondaryText)
                .frame(width: 62, alignment: .leading)
        }
    }

    private var contextLine: String? {
        var parts: [String] = []
        if !event.isAllDay {
            parts.append("until \(event.endAt.formatted(date: .omitted, time: .shortened))")
        }
        if let location = event.locationName, !location.isEmpty { parts.append(location) }
        if let calendar = event.calendarName, !calendar.isEmpty { parts.append(calendar) }
        if event.isCancelled { parts.append("cancelled") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibilityDescription: String {
        var parts = [event.displayTitle]
        parts.append(event.isAllDay
            ? "all day"
            : "\(event.startAt.formatted(date: .omitted, time: .shortened)) to \(event.endAt.formatted(date: .omitted, time: .shortened))")
        if event.isRecurring { parts.append("repeating") }
        if event.isCancelled { parts.append("cancelled") }
        if let location = event.locationName, !location.isEmpty { parts.append("at \(location)") }
        return parts.joined(separator: ", ")
    }
}

/// The events for a day, above the work.
///
/// A separate section rather than interleaved with tasks. Events are when you are *not* free; tasks
/// are what you might do with the rest. Mixing them into one ordered list implies a sequence that
/// does not exist, and makes it harder to see how much of the day is already spoken for.
struct DayEventsSection: View {
    let events: [CalendarEventSummary]
    let dateProvider: any DateProvider
    let onLink: ((CalendarEventSummary) -> Void)?

    var body: some View {
        if !events.isEmpty {
            Section {
                ForEach(events) { event in
                    CalendarEventRow(
                        event: event,
                        dateProvider: dateProvider,
                        onLink: onLink.map { handler in { handler(event) } }
                    )
                }
            } header: {
                SectionHeader("Calendar", count: events.count)
            }
        }
    }
}

/// The banner offering to turn the calendar on, or explaining why it is not showing.
///
/// Only ever appears in Today and Upcoming, where a calendar would actually add something — a note
/// about a permission is noise everywhere else.
struct CalendarStatusBanner: View {
    let authorization: IntegrationAuthorization
    let isEnabled: Bool
    let onEnable: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        if let message {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "calendar")
                    .foregroundStyle(Theme.Colors.secondaryText)

                Text(message)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)

                Spacer(minLength: Theme.Spacing.small)

                if !isEnabled {
                    Button("Show My Calendar", action: onEnable)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                } else if !authorization.isWorthAsking, !authorization.canRead {
                    // Asking again would show no prompt, so the only honest button sends the user
                    // where the decision actually lives.
                    Button("Open System Settings", action: onOpenSettings)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
            .background(Theme.Colors.subtleFill)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.Calendar.statusBanner)
        }
    }

    /// Nothing at all when the calendar is working, which is most of the time.
    private var message: String? {
        guard isEnabled else {
            return "Elephruit can show your events here. It only ever reads your calendar."
        }
        return authorization.explanation
    }
}

/// The calendar switch in Settings.
///
/// The only place the feature is turned on, and deliberately so: a permission prompt belongs where
/// someone has gone looking for the feature, not in the middle of their day.
public struct CalendarSettingsSection: View {
    private let calendar: CalendarService

    public init(calendar: CalendarService) {
        self.calendar = calendar
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Toggle("Show my calendar", isOn: enabledBinding)
                .accessibilityIdentifier(AccessibilityID.Calendar.enableToggle)

            Text(explanation)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if calendar.isEnabled, !calendar.authorization.canRead, !calendar.authorization.isWorthAsking {
                Button("Open System Settings") {
                    guard let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
                    ) else { return }
                    NSWorkspace.shared.open(url)
                }
                .controlSize(.small)
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { calendar.isEnabled },
            set: { wanted in
                if wanted {
                    Task { await calendar.enable() }
                } else {
                    calendar.disable()
                }
            }
        )
    }

    /// Says what the permission actually covers.
    ///
    /// It used to say the app never writes, which was true and is no longer: the calendar module
    /// creates and edits events. What is still true, and what somebody deciding on this prompt
    /// actually needs to know, is the other half — that their notes about a meeting stay in
    /// Elephruit and are never put into an event other people can read.
    private var explanation: String {
        if let refusal = calendar.authorization.explanation, calendar.isEnabled {
            return refusal
        }
        return """
            Your events appear in Elephruit, and you can create and change them here. Anything you \
            write *about* a meeting — linked people, your own notes, what you promised — stays in \
            Elephruit and is never added to the calendar event.
            """
    }
}
