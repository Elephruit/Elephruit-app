import Foundation

/// What is true about a person right now.
///
/// ### Derived, never stored
/// Every field here is computed from links that already exist. Nothing about a relationship is
/// entered twice: "when did we last speak" is the newest interaction, "what is open with them" is
/// the tasks that mention them. A stored `lastContactedAt` would be a second source of truth that
/// silently goes stale the moment someone edits a note.
///
/// A value type, so it can be built in a test without a store and rendered without one either.
public struct PersonContext: Sendable, Hashable {
    public var personID: UUID
    public var displayName: String

    /// The most recent time you actually spoke — a meeting or a recorded interaction.
    ///
    /// **Notes and tasks do not count.** Writing a task about someone is not contact with them, and
    /// letting it count would make "you last spoke three months ago" quietly false for anyone whose
    /// name appears in your work. That distinction is the difference between a follow-up suggestion
    /// that is trustworthy and one that is noise.
    public var lastContact: ContactMoment?

    /// The most recent anything that references them, including notes and tasks.
    ///
    /// Useful for "what was I last doing about this person", which is a different question from
    /// "when did we last speak".
    public var lastMention: ContactMoment?

    /// The next meeting they are part of.
    public var nextContact: ContactMoment?

    /// Open tasks that mention them.
    public var openItemIDs: [UUID]

    /// How many things reference them at all.
    public var mentionCount: Int

    public init(
        personID: UUID,
        displayName: String,
        lastContact: ContactMoment? = nil,
        lastMention: ContactMoment? = nil,
        nextContact: ContactMoment? = nil,
        openItemIDs: [UUID] = [],
        mentionCount: Int = 0
    ) {
        self.personID = personID
        self.displayName = displayName
        self.lastContact = lastContact
        self.lastMention = lastMention
        self.nextContact = nextContact
        self.openItemIDs = openItemIDs
        self.mentionCount = mentionCount
    }

    /// A single line for the top of a person's page.
    ///
    /// Says what is *true*, never what to do about it — see ``FollowUpSuggestion`` for the part that
    /// makes a recommendation, which is opt-in and separate on purpose.
    public func summary(using dateProvider: any DateProvider) -> String {
        var parts: [String] = []

        if let lastContact {
            parts.append("Last \(lastContact.kindDescription) \(lastContact.relativeDescription(using: dateProvider))")
        } else if let lastMention {
            // Never spoken, but they appear in the work — say that rather than "nothing recorded",
            // which would be untrue and would make the page look empty when it is not.
            parts.append("Mentioned \(lastMention.relativeDescription(using: dateProvider)), not yet spoken")
        } else {
            parts.append("Nothing recorded yet")
        }

        if let nextContact {
            parts.append("next \(nextContact.relativeDescription(using: dateProvider))")
        }

        if !openItemIDs.isEmpty {
            parts.append(openItemIDs.count == 1 ? "1 open item" : "\(openItemIDs.count) open items")
        }

        return parts.joined(separator: " · ")
    }

    /// How long since the last contact, if there was one.
    public func daysSinceLastContact(using dateProvider: any DateProvider) -> Int? {
        guard let lastContact else { return nil }
        let days = dateProvider.calendar.dateComponents(
            [.day],
            from: dateProvider.calendar.startOfDay(for: lastContact.date),
            to: dateProvider.startOfToday
        ).day
        return days.map { max(0, $0) }
    }
}

/// One moment of contact — a meeting, a recorded interaction, or a note that mentions someone.
public struct ContactMoment: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: ItemKind
    public var title: String
    public var date: Date

    public init(id: UUID, kind: ItemKind, title: String, date: Date) {
        self.id = id
        self.kind = kind
        self.title = title
        self.date = date
    }

    public var kindDescription: String {
        switch kind {
        case .meeting: "met"
        case .interaction: "spoke"
        default: "mentioned"
        }
    }

    /// Whether this counts as having actually been in touch.
    ///
    /// A meeting or a recorded conversation, and nothing else. This is the one place the rule lives,
    /// so a follow-up suggestion and a person's summary line can never disagree about it.
    public var isContact: Bool {
        kind == .meeting || kind == .interaction
    }

    /// "yesterday", "3 weeks ago", "on Tuesday" — whichever reads best at that distance.
    public func relativeDescription(using dateProvider: any DateProvider) -> String {
        let calendar = dateProvider.calendar
        let today = dateProvider.startOfToday
        let day = calendar.startOfDay(for: date)

        guard let days = calendar.dateComponents([.day], from: day, to: today).day else {
            return date.formatted(date: .abbreviated, time: .omitted)
        }

        switch days {
        case ..<(-1): return "in \(-days) days"
        case -1: return "tomorrow"
        case 0: return "today"
        case 1: return "yesterday"
        case 2...6: return "\(days) days ago"
        case 7...13: return "last week"
        case 14...59: return "\(days / 7) weeks ago"
        default: return "\(days / 30) months ago"
        }
    }
}

// MARK: - Follow-up

/// A suggestion that it might be time to get back to someone.
///
/// ### Why this is a suggestion and nothing more
/// It never creates a task, never schedules a reminder, and never notifies. It appears on a person's
/// page and waits to be noticed — the standing rule that suggestions and recovery states do not make
/// consequential decisions on their own.
///
/// It is also **off by default**. An app that starts telling you who you have neglected, unprompted,
/// is a different and worse product than one that answers when asked.
public struct FollowUpSuggestion: Sendable, Hashable, Identifiable {
    public var personID: UUID
    public var displayName: String
    public var daysSinceContact: Int
    public var lastContact: ContactMoment?

    public var id: UUID { personID }

    public init(personID: UUID, displayName: String, daysSinceContact: Int, lastContact: ContactMoment? = nil) {
        self.personID = personID
        self.displayName = displayName
        self.daysSinceContact = daysSinceContact
        self.lastContact = lastContact
    }

    public var message: String {
        "You last spoke with \(displayName) \(daysSinceContact) days ago."
    }
}

/// Decides when a follow-up is worth mentioning.
///
/// Deliberately dull: a threshold in days, applied to people the user has actually recorded contact
/// with. No scoring, no inference about how important someone is, no learning from behaviour — all
/// of which would produce confident suggestions nobody can explain or correct.
public enum FollowUpPolicy {
    /// The default gap. Six weeks is long enough that a nudge is not nagging, and short enough that
    /// it arrives while getting back in touch is still natural.
    public static let defaultThresholdDays = 42

    /// Which people are worth mentioning, most-overdue first.
    ///
    /// Someone with **no recorded contact at all** is never suggested. There is nothing to follow up
    /// on, and treating an empty record as "overdue by forever" would fill the list with everyone
    /// the user has ever typed a name for.
    public static func suggestions(
        from contexts: [PersonContext],
        thresholdDays: Int = defaultThresholdDays,
        using dateProvider: any DateProvider
    ) -> [FollowUpSuggestion] {
        contexts.compactMap { context -> FollowUpSuggestion? in
            guard let days = context.daysSinceLastContact(using: dateProvider), days >= thresholdDays else {
                return nil
            }
            return FollowUpSuggestion(
                personID: context.personID,
                displayName: context.displayName,
                daysSinceContact: days,
                lastContact: context.lastContact
            )
        }
        .sorted { $0.daysSinceContact > $1.daysSinceContact }
    }
}
