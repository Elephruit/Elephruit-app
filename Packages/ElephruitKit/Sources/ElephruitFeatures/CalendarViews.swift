import AppKit
import ElephruitCore
import ElephruitDesign
import ElephruitIntegrations
import SwiftUI

/// Where a decision about calendar access can actually be changed.
///
/// One helper rather than a URL beside each banner: once macOS has recorded a refusal, asking again
/// shows no prompt, so the only honest button sends the user to the one place the decision lives —
/// and a second copy of that URL is a second chance to send them somewhere that does nothing.
enum CalendarSettingsLink {
    static func open() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The banner offering to turn the calendar on, or explaining why it is not showing.
///
/// Only ever appears on Today, where a calendar would actually add something — a note about a
/// permission is noise everywhere else.
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

                // ### Every state that shows a message also offers a way out of it
                // There used to be a gap here, and Today sat in it. The two branches were "not
                // enabled" and "enabled, asked, refused"; the state in between — enabled, never
                // asked — matched neither, so `message` returned the "Elephruit can show your
                // calendar alongside your work" line and nothing was drawn beside it. A strip with
                // an icon and an offer and no control, at the top of the day's list, which does not
                // respond to being clicked.
                //
                // A banner that describes a capability the user cannot reach from it is worse than
                // no banner. If there is something to say, there is something to press.
                if !isEnabled {
                    Button("Show My Calendar", action: onEnable)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if authorization.isWorthAsking {
                    // Enabled, but macOS has never been asked. Asking is the whole remaining step.
                    Button("Allow Access…", action: onEnable)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if !authorization.canRead {
                    // Asking again would show no prompt, so the only honest button sends the user
                    // where the decision actually lives.
                    Button("Open System Settings", action: onOpenSettings)
                        .buttonStyle(.bordered)
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
            write *about* a meeting — linked people, your own notes, and related tasks — stays in \
            Elephruit and is never added to the calendar event.
            """
    }
}
