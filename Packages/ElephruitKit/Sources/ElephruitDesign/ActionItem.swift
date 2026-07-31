import SwiftUI

/// One thing the user can do to whatever is on screen, described rather than drawn.
///
/// ### Why availability is carried here and not decided in the view
/// Because it was decided in the views, in each of them separately, and that is how an app ends up
/// offering Call to somebody with no phone number in one place and hiding it in another. The rule —
/// *what can this person's data actually support* — belongs to the data. What a view gets is the
/// answer plus the sentence explaining it, and its only job is to draw both.
///
/// ### Why there is always a reason
/// A disabled control that is merely grey is indistinguishable from a broken one. Every action that
/// cannot run carries ``unavailabilityReason``, which becomes the tooltip *and* the accessibility
/// hint, so "why can I not press this" is answered by hovering rather than by guessing.
public struct ActionItem: Identifiable {
    /// How strongly this should be kept on screen as the space runs out.
    ///
    /// Not a visual weight. Every action in a group is drawn the same way — same size, same border,
    /// same hover — because a row where one button shouts is a row where the others are hard to
    /// read. This decides only *order of survival*.
    public enum Priority: Int, Sendable, Comparable {
        /// Goes last. The action somebody opened this screen to take.
        case essential = 3
        /// Common enough to expect a label.
        case common = 2
        /// Reached deliberately; happy in a menu.
        case occasional = 1

        public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let id: String

    /// A verb describing the result — "Call", "Add Note", "Log Interaction".
    ///
    /// Not a noun and not the name of the thing it opens. "Message" is what happens; "Messages" is an
    /// application, and naming the application makes the user translate.
    public let title: String

    public let symbolName: String
    public let priority: Priority
    public let isEnabled: Bool

    /// Why it cannot be used. `nil` when it can.
    public let unavailabilityReason: String?

    /// Extra context the label does not carry — which number will be dialled, what will open.
    public let detail: String?

    /// Rendered into the tooltip, e.g. `"⌘⇧N"`.
    public let shortcut: String?

    public let role: ButtonRole?

    public let perform: @MainActor () -> Void

    public init(
        id: String,
        title: String,
        symbolName: String,
        priority: Priority = .common,
        isEnabled: Bool = true,
        unavailabilityReason: String? = nil,
        detail: String? = nil,
        shortcut: String? = nil,
        role: ButtonRole? = nil,
        perform: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.priority = priority
        self.isEnabled = isEnabled && unavailabilityReason == nil
        self.unavailabilityReason = unavailabilityReason
        self.detail = detail
        self.shortcut = shortcut
        self.role = role
        self.perform = perform
    }

    /// What the pointer reveals after the system's own delay.
    ///
    /// A tooltip that spells the label back is a delay followed by nothing, so this is only ever the
    /// things the label could not say: why it is off, what it will actually do, which keys run it.
    public var tooltip: String? {
        let parts = [unavailabilityReason ?? detail, shortcut].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What VoiceOver hears when the label alone is not the whole story.
    public var accessibilityHint: String? {
        [unavailabilityReason, detail].compactMap { $0 }.first
    }
}

// MARK: - Ordering

extension Array where Element == ActionItem {
    /// Highest priority first, and stable within a priority so the row does not reshuffle itself
    /// when one action becomes available.
    ///
    /// A row of buttons that reorders as data arrives is a row nobody can build muscle memory for,
    /// which is most of what a row of buttons is for.
    public func rankedForDisplay() -> [ActionItem] {
        enumerated()
            .sorted { left, right in
                left.element.priority == right.element.priority
                    ? left.offset < right.offset
                    : left.element.priority > right.element.priority
            }
            .map(\.element)
    }

    /// Actions the user can actually take, in order.
    public var enabledOnly: [ActionItem] { filter(\.isEnabled) }
}
