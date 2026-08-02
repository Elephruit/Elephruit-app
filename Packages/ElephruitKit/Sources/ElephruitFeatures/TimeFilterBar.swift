import ElephruitCore
import ElephruitDesign
import SwiftUI

/// Log or Reports, switched at the top of the content it switches.
///
/// Tabs in the view rather than a segmented control in the toolbar. The toolbar version was the
/// second attempt: the first swapped the whole sidebar for two buttons, which cost the user their
/// map, and the toolbar put the choice next to the window's *title* — a control floating beside
/// "Time Reports" with nothing visibly connecting it to the page it changes. Two ways of looking at
/// one body of work is exactly what a project workspace has, and it answers with a tab row at the
/// top of the content — see `ProjectViewTabBar`. Time now does the same, in the same clothes, so
/// the choice sits on the thing it chooses and the toolbar is left to genuine commands.
struct TimeSurfaceTabs: View {
    let navigation: NavigationModel

    var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            ForEach(TimeSurface.allCases, id: \.self) { surface in
                tab(surface)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.top, Theme.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("time.surfaceSwitcher")
    }

    private func tab(_ surface: TimeSurface) -> some View {
        let isActive = navigation.timeSurface == surface
        return Button {
            navigation.timeSurface = surface
        } label: {
            HStack(spacing: Theme.Spacing.tight) {
                Image(systemName: surface.symbolName)
                    .foregroundStyle(isActive ? Theme.Colors.selection : Theme.Colors.secondaryText)
                Text(surface.displayName)
            }
            .font(Theme.Text.rowTitle)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.tight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .fill(isActive ? Theme.Colors.selection.opacity(0.14) : .clear)
            )
        }
        .buttonStyle(.plain)
        .help(surface.hint)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("time.surface.\(surface.rawValue)")
    }
}

/// The two questions both Time surfaces are asked: over what period, and cut how.
///
/// ### Why this is one component and not two similar ones
/// Because it was three copies of the same idea and they had already drifted. The Log carried its
/// period and grouping in the *sidebar*, as two sections of checkmark rows, **and** in its toolbar as
/// two menus; Reports carried them in the view as a chip rail and a segmented control. Three places
/// to change, three places to forget, and two of them hid their options behind a click on the
/// surface where flipping between periods is the whole activity.
///
/// One element, used by both, so a change to how a period is chosen is a change to how a period is
/// chosen. What is *not* shared is the state: the Log's window lives on ``NavigationModel`` and the
/// report's on its own preference, deliberately — "the period a report covers is usually a month
/// somebody is invoicing and the period the log shows is usually today, and one setting serving both
/// means changing it in one place to answer a question in the other." A shared control does not
/// imply a shared answer, and this one takes both as arguments.
///
/// ### Why the two surfaces offer different windows
/// The Log offers ``ElephruitCore/TimeWindow/logWindows`` and no custom range; Reports offers every
/// window and a custom one. That distinction predates this component and is the reason the window
/// list is a parameter: a log is a place you correct yesterday from, and a year of it is a list
/// nobody can correct anything from.
struct TimeFilterBar: View {
    /// The windows offered as chips, in the order they are shown.
    let windows: [TimeWindow]

    /// Which window is current, or `nil` when a custom range is in force.
    let selectedWindow: TimeWindow?

    let onSelectWindow: (TimeWindow) -> Void

    /// The custom-range affordance, for the surface that has one. `nil` on the Log.
    var custom: CustomRange?

    let groupings: [TimeGrouping]
    let grouping: TimeGrouping
    let onSelectGrouping: (TimeGrouping) -> Void

    /// Everything the custom-range chip and its two date fields need.
    ///
    /// A value rather than four loose parameters, because the four are only meaningful together —
    /// a surface either offers a custom range or it does not, and half of one is a chip that
    /// selects a range nobody can set.
    struct CustomRange {
        var isActive: Bool
        var from: Binding<Date>
        var through: Binding<Date>

        /// Called when the chip is pressed, so the surface can switch to its custom period.
        var onActivate: () -> Void
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
                Text("PERIOD")
                    .font(Theme.Text.sectionHeader)
                    .kerning(Theme.Text.Tracking.caps)
                    .foregroundStyle(Theme.Colors.tertiaryText)

                Spacer(minLength: Theme.Spacing.medium)

                // Segmented rather than chips, because six is a small closed set and that is the
                // control macOS uses for one. The periods are a rail because nine is not.
                Picker("Grouped by", selection: groupingBinding) {
                    ForEach(groupings, id: \.self) { grouping in
                        Text(grouping.displayName).tag(grouping)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
                .help("What the breakdown is cut by")
                .accessibilityLabel("Grouped by")
                .accessibilityIdentifier(AccessibilityID.Time.groupingPicker)
            }

            // Wrapping rather than scrolling or truncating: the rail is as many rows as the width
            // it is given needs, and every option stays legible at every window size.
            ElephruitDesign.FlowLayout(spacing: Theme.Spacing.tight, lineSpacing: Theme.Spacing.tight) {
                ForEach(windows, id: \.self) { window in
                    FilterChip(
                        window.displayName,
                        hint: window.hint,
                        isOn: selectedWindow == window
                    ) {
                        onSelectWindow(window)
                    }
                }

                if let custom {
                    FilterChip(
                        "Custom…",
                        hint: "Any two dates, for the invoice that does not follow the calendar.",
                        isOn: custom.isActive,
                        action: custom.onActivate
                    )
                    .accessibilityIdentifier(AccessibilityID.Time.reportPeriodPicker)
                }
            }

            if let custom, custom.isActive {
                HStack(spacing: Theme.Spacing.small) {
                    DatePicker("From", selection: custom.from, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()

                    Text("to")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)

                    DatePicker("To", selection: custom.through, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Time.filterBar)
    }

    /// Written as a closure rather than passed as one.
    ///
    /// `Binding`'s setter is `@Sendable`, and handing it `onSelectGrouping` directly asks the
    /// compiler to promote a plain view closure into one — which it will do with a warning about
    /// data races it cannot rule out. Wrapping it keeps the call on the main actor, where every
    /// caller of this view already is.
    private var groupingBinding: Binding<TimeGrouping> {
        Binding(get: { grouping }, set: { onSelectGrouping($0) })
    }
}
