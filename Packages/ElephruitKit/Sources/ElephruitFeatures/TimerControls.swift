import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// The bar at the top of the Time view: what is running, and the one button that changes it.
struct TimerBar: View {
    @Environment(\.services) private var services

    let onStart: () -> Void
    let onStop: () -> Void
    let onOpenSubject: (UUID) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            if let running = services?.timer.running {
                Image(systemName: "record.circle")
                    .foregroundStyle(Theme.Colors.destructive)
                    .symbolEffect(.pulse, options: .repeating)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 0) {
                    if let itemID = running.itemID {
                        Button(running.displayTitle) { onOpenSubject(itemID) }
                            .buttonStyle(.link)
                            .font(Theme.Text.rowTitleEmphasised)
                    } else {
                        Text(running.displayTitle)
                            .font(Theme.Text.rowTitleEmphasised)
                    }

                    Text("started \(running.startedAt.formatted(date: .omitted, time: .shortened))")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }

                Spacer()

                Text(services?.timer.elapsedDisplay ?? "0:00")
                    .font(.system(.title2, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .accessibilityLabel("Elapsed \(TimeFormatting.spelled(services?.timer.elapsed ?? 0))")

                Button("Stop", systemImage: "stop.fill", action: onStop)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(AccessibilityID.Time.stopButton)
            } else {
                Image(systemName: "timer")
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .accessibilityHidden(true)

                Text("No timer running")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)

                Spacer()

                Button("Start", systemImage: "play.fill", action: onStart)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(AccessibilityID.Time.startButton)
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .frame(minHeight: 52)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Time.timerBar)
    }
}

/// The start/stop button that lives on an item.
///
/// One button, not two. It shows what pressing it will do: a play triangle when this item is not
/// being timed, a stop square when it is. Timing something else switches rather than refusing —
/// a button that reports an error when pressed is not one anyone presses twice.
public struct ItemTimerButton: View {
    @Environment(\.services) private var services

    private let item: Item
    private let showsElapsed: Bool

    public init(item: Item, showsElapsed: Bool = false) {
        self.item = item
        self.showsElapsed = showsElapsed
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            if showsElapsed, isTimingThisItem, let services {
                Text(services.timer.elapsedDisplay)
                    .font(Theme.Text.metadata)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.destructive)
            }

            Button {
                services?.timer.toggle(item: item)
            } label: {
                Image(systemName: isTimingThisItem ? "stop.circle.fill" : "play.circle")
                    .foregroundStyle(isTimingThisItem ? Theme.Colors.destructive : Theme.Colors.secondaryText)
            }
            .buttonStyle(.plain)
            .help(isTimingThisItem ? "Stop timing" : "Start timing “\(item.displayTitle)”")
            .accessibilityLabel(isTimingThisItem ? "Stop timing" : "Start timing")
            .accessibilityIdentifier(AccessibilityID.Time.itemToggle(id: item.id.uuidString))
        }
    }

    private var isTimingThisItem: Bool {
        services?.timer.running?.itemID == item.id
    }
}

// MARK: - Menu bar

/// The menu bar timer.
///
/// ### Why this exists
/// The point of a timer is that it runs while you are doing something *else* — in another app,
/// usually. A timer you can only see by switching to Elephruit is one you forget is running, and a
/// forgotten timer is how eleven hours get billed to a task that took two.
///
/// The title is the elapsed time, so the answer is visible without a click.
public struct TimerMenuBarContent: View {
    private let services: AppServices

    /// Opens the floating capture panel. `nil` in a preview, where there is no panel to open.
    private let openQuickJot: (() -> Void)?

    public init(services: AppServices, openQuickJot: (() -> Void)? = nil) {
        self.services = services
        self.openQuickJot = openQuickJot
    }

    public var body: some View {
        Group {
            if let running = services.timer.running {
                Text(running.displayTitle)
                Text("Started \(running.startedAt.formatted(date: .omitted, time: .shortened))")

                Divider()

                Button("Stop Timer") { services.timer.stop() }
                    .shortcut(.toggleTimer, in: services.shortcuts)
            } else {
                Text("No timer running")

                Divider()

                ForEach(recentSubjects, id: \.id) { subject in
                    Button("Start “\(subject.title)”") {
                        guard let item = try? services.items.item(id: subject.id) else { return }
                        services.timer.switchTo(item: item)
                    }
                }

                Button("Start Untitled Timer") { services.timer.switchTo(item: nil) }
                    .shortcut(.toggleTimer, in: services.shortcuts)
            }

            Divider()

            // Capture belongs here as much as the timer does. Both are things wanted while looking
            // at something else, and this menu is the only part of Elephruit visible then.
            if let openQuickJot {
                Button("Quick Jot…") { openQuickJot() }
                    .shortcut(.quickCapture, in: services.shortcuts)
            }

            Button("Open Elephruit") {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }

    /// A few things worth continuing, so the common case is one click from anywhere.
    private var recentSubjects: [(id: UUID, title: String)] {
        guard let recent = try? services.timeEntries.recentEntries(limit: 12) else { return [] }

        var seen = Set<UUID>()
        var subjects: [(id: UUID, title: String)] = []
        for entry in recent {
            guard let item = entry.item, seen.insert(item.id).inserted else { continue }
            subjects.append((item.id, item.displayTitle))
            if subjects.count == 3 { break }
        }
        return subjects
    }
}

/// What the menu bar shows when it is not open.
public struct TimerMenuBarLabel: View {
    private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    public var body: some View {
        if services.timer.isRunning {
            // Elapsed time in the title, not just an icon: the whole reason to be in the menu bar is
            // to answer "how long has this been going" without a click.
            Label(services.timer.elapsedDisplay, systemImage: "record.circle")
                .monospacedDigit()
        } else {
            Label("Elephruit", systemImage: "timer")
        }
    }
}
