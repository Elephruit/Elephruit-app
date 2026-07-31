import Foundation

/// Everything a person's record can be asked to do, and what it can actually support.
///
/// ### Why this is in `ElephruitCore` and not in the view that draws the buttons
/// It was in the view that draws the buttons. The consequence is the ordinary one: the People
/// workspace, the command bar, the context menu on a list row and the meeting brief each decided for
/// themselves whether Email was available, and they were four opportunities to disagree. There is
/// one rule — *does this person have an address of the kind this channel consumes* — and it belongs
/// with the data, next to ``ContactDestinationPolicy``, where it can be asserted against a record
/// with two mobiles and no email rather than reviewed in a screenshot.
///
/// ### Why the order changes with the person
/// Priority here is contextual, not a fixed list. Call is the first thing you want for somebody with
/// a phone number and pointless for somebody without one, so an action that cannot run does not
/// merely grey out — it sinks, and the actions that *can* run come forward to fill the row. A row
/// whose first two buttons are permanently unusable is a row that has taught the user to look past
/// its first two buttons.
public struct PersonActionAvailability: Sendable, Hashable, Identifiable {
    /// What the action is, in terms the app can act on.
    public enum Kind: Sendable, Hashable {
        /// Reaches another person through a system app.
        case contact(ContactChannel)
        /// Writes something down here. Always available: there is nothing to be missing.
        case addNote
        /// Records that a conversation happened, with a summary.
        case logInteraction
        /// Creates a task about this person.
        case addTask
        /// Reads back what is worth knowing before the next conversation.
        case meetingBrief
        /// Adds or edits a connection to somebody else.
        case addRelationship
    }

    public var kind: Kind
    public var isAvailable: Bool

    /// Why not, in a sentence a tooltip can carry. `nil` when it is available.
    public var unavailabilityReason: String?

    /// What will happen, when the label alone does not say — "mobile · 512-555-0192".
    public var detail: String?

    /// Higher survives longer in a narrowing row.
    public var rank: Int

    public var id: String {
        switch kind {
        case .contact(let channel): "contact.\(channel.rawValue)"
        case .addNote: "addNote"
        case .logInteraction: "logInteraction"
        case .addTask: "addTask"
        case .meetingBrief: "meetingBrief"
        case .addRelationship: "addRelationship"
        }
    }

    /// The verb, describing the result rather than the app it opens.
    public var title: String {
        switch kind {
        case .contact(let channel): channel.displayName
        case .addNote: "Add Note"
        case .logInteraction: "Log Interaction"
        case .addTask: "Add Task"
        case .meetingBrief: "Brief"
        case .addRelationship: "Add Relationship"
        }
    }

    public var symbolName: String {
        switch kind {
        case .contact(let channel): channel.symbolName
        case .addNote: "square.and.pencil"
        case .logInteraction: "text.bubble"
        case .addTask: "checkmark.circle"
        case .meetingBrief: "list.bullet.rectangle"
        case .addRelationship: "person.2.badge.plus"
        }
    }

    /// Whether taking this reaches somebody outside the app, and so has to be confirmed first.
    public var isExternallyVisible: Bool {
        switch kind {
        case .contact(let channel): channel.isExternallyVisible
        case .addNote, .logInteraction, .addTask, .meetingBrief, .addRelationship: false
        }
    }
}

extension PersonActionAvailability {
    /// Every action for one person, ranked, with the unavailable ones explained and demoted.
    ///
    /// - Parameters:
    ///   - destinations: everything stored that could be dialled, written to or opened.
    ///   - hasRelationships: whether this person is already connected to anybody, which changes
    ///     *Add Relationship* from an edit into a first step.
    ///   - hasHistory: whether there is anything to brief from. A meeting brief assembled from
    ///     nothing is a heading and three empty sections, which is worse than the action being off.
    public static func all(
        destinations: [ContactDestination],
        hasRelationships: Bool = false,
        hasHistory: Bool = false
    ) -> [PersonActionAvailability] {
        // Base ranks state the editorial order for somebody with everything filled in: reach them,
        // then write something down, then plan. An action that cannot run drops below all of them.
        let contactRanks: [ContactChannel: Int] = [
            .call: 100,
            .message: 95,
            .email: 90,
            .facetimeVideo: 70,
            .facetimeAudio: 65,
            .maps: 45,
            .web: 40,
        ]

        var out: [PersonActionAvailability] = ContactChannel.allCases.map { channel in
            let candidates = ContactDestinationPolicy.candidates(for: channel, from: destinations)
            let base = contactRanks[channel] ?? 50

            guard let chosen = candidates.first else {
                return PersonActionAvailability(
                    kind: .contact(channel),
                    isAvailable: false,
                    unavailabilityReason: "No \(channel.destinationNoun) recorded",
                    detail: nil,
                    // Below every available action, so the row leads with what works. It stays in
                    // the list rather than vanishing, because "there is no number for her" is
                    // information, and an action that silently disappears cannot say it.
                    rank: base - 1000
                )
            }

            return PersonActionAvailability(
                kind: .contact(channel),
                isAvailable: true,
                unavailabilityReason: nil,
                // Which one it will use, so pressing Call is not a guess about whose phone rings.
                // Several candidates means the app has no basis for choosing and will ask.
                detail: candidates.count == 1 ? chosen.displayText : "\(candidates.count) to choose from",
                rank: base
            )
        }

        out.append(
            PersonActionAvailability(
                kind: .addNote,
                isAvailable: true,
                rank: 85
            )
        )

        out.append(
            PersonActionAvailability(
                kind: .logInteraction,
                isAvailable: true,
                detail: "Records that you spoke, with what was said",
                rank: 80
            )
        )

        out.append(
            PersonActionAvailability(
                kind: .addTask,
                isAvailable: true,
                rank: 60
            )
        )

        out.append(
            PersonActionAvailability(
                kind: .meetingBrief,
                isAvailable: hasHistory,
                unavailabilityReason: hasHistory ? nil : "Nothing recorded about them yet",
                detail: hasHistory ? "What to remember before speaking to them" : nil,
                rank: hasHistory ? 55 : -900
            )
        )

        out.append(
            PersonActionAvailability(
                kind: .addRelationship,
                isAvailable: true,
                detail: hasRelationships ? "Connect them to somebody else" : "Who are they to you?",
                rank: 35
            )
        )

        return out.sorted { left, right in
            left.rank == right.rank ? left.id < right.id : left.rank > right.rank
        }
    }
}
