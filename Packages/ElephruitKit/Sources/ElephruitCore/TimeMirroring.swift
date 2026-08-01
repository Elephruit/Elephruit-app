import Foundation

/// What a stretch of tracked time becomes when it is written into a calendar.
///
/// ### Why a mirror at all
/// A calendar is the one surface that already answers *what was I doing at three o'clock* — and it
/// answers it for everybody who has to reconstruct a week, not just for the person who tracked it.
/// Writing finished entries into a calendar of their own puts the day that actually happened beside
/// the day that was planned, which is the comparison nobody can make today.
///
/// ### What is deliberately never written
/// The mirror is **outbound and lossy on purpose**. A calendar event is not a private place: it
/// syncs to every device on the account, it is visible to anybody a calendar is shared with, and on
/// a work account it may be visible to an administrator. So three things never cross, whatever the
/// settings say:
///
/// - **People.** An hour with somebody is a fact about *them* as much as about you, and putting
///   their name in an event publishes it to an audience they never agreed to.
/// - **Notes and bodies.** Whatever an item says is the reason it lives in Elephruit rather than in
///   a calendar.
/// - **Billability and rates.** What you charge is not something to leave lying in a shared diary.
///
/// ``TimeMirrorFields`` has nowhere to put any of them, which is what makes this a property of the
/// type rather than a rule somebody has to remember — the same construction that keeps
/// ``EventDraft`` from inventing an attendee.
public struct TimeMirrorFields: Sendable, Hashable {
    /// The event's title.
    public var title: String

    /// The event's notes. Only ever a tag list and the app's own marker — never anything written.
    public var notes: String

    public var startedAt: Date
    public var endedAt: Date

    public init(title: String, notes: String, startedAt: Date, endedAt: Date) {
        self.title = title
        self.notes = notes
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// How the mirror is set up.
public struct TimeMirrorPolicy: Sendable, Hashable, Codable {
    /// Whether finished entries are written at all.
    public var isEnabled: Bool

    /// The calendar written to. Nothing is ever written without one.
    ///
    /// A calendar of its own is strongly the intended shape, and the settings screen says so: a
    /// mirror pouring into the calendar that holds actual meetings makes both unreadable, and there
    /// is no undo for that beyond deleting events one at a time.
    public var calendarIdentifier: String?

    /// Whether the subject's title leads the event title.
    public var includesSubject: Bool

    /// Whether tags are listed in the notes.
    public var includesTags: Bool

    /// The shortest entry worth writing.
    ///
    /// Defaults to five minutes. A day of two-minute interruptions written out in full is a calendar
    /// nobody can read, and the entries it would add are exactly the ones that carry no information.
    public var minimumDuration: TimeInterval

    /// Whether mirrored events mark the time as busy.
    ///
    /// Off by default. These describe time that has *already been spent*; marking it busy tells
    /// everybody's scheduling assistant that yesterday afternoon is unavailable, which is both
    /// useless and wrong.
    public var marksAsBusy: Bool

    public static let disabled = TimeMirrorPolicy(
        isEnabled: false,
        calendarIdentifier: nil,
        includesSubject: true,
        includesTags: false,
        minimumDuration: 5 * 60,
        marksAsBusy: false
    )

    public init(
        isEnabled: Bool,
        calendarIdentifier: String?,
        includesSubject: Bool = true,
        includesTags: Bool = false,
        minimumDuration: TimeInterval = 5 * 60,
        marksAsBusy: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.calendarIdentifier = calendarIdentifier
        self.includesSubject = includesSubject
        self.includesTags = includesTags
        self.minimumDuration = max(0, minimumDuration)
        self.marksAsBusy = marksAsBusy
    }

    /// Whether the mirror is both turned on and pointed somewhere.
    public var isUsable: Bool {
        guard isEnabled, let calendarIdentifier else { return false }
        return !calendarIdentifier.isEmpty
    }
}

/// What the mirror should do about one entry.
///
/// A decision, produced by a pure function and applied by a service, so *"a running timer is never
/// written"* and *"a deleted entry takes its event with it"* are testable without a calendar.
public enum TimeMirrorAction: Sendable, Hashable {
    /// Write a new event and remember its identifier.
    case create(TimeMirrorFields)

    /// Rewrite the event already written for this entry.
    case update(identifier: String, fields: TimeMirrorFields)

    /// Remove the event already written for this entry.
    ///
    /// What happens when an entry is deleted, or shrinks below the minimum, or when the description
    /// it was written from is emptied — anything that means the event should no longer exist. Never
    /// used for an entry that was never mirrored.
    case remove(identifier: String)

    /// Leave the calendar alone.
    case none
}

/// The rules for turning tracked time into calendar events.
public enum TimeMirroring {
    /// The marker written into every mirrored event's notes.
    ///
    /// So that an event this app created can be recognised as one *by a human reading the calendar*,
    /// which matters the first time somebody wonders where two hundred events came from. The app
    /// itself never relies on it — it matches by the identifier it stored, because notes are
    /// editable and a match on text would eventually delete somebody's real meeting.
    public static let marker = "Tracked in Elephruit"

    /// What to do about one entry.
    ///
    /// - Parameters:
    ///   - entry: the entry as it now stands.
    ///   - existingIdentifier: the event previously written for it, if any.
    ///   - isDeleted: whether the entry has been thrown away.
    public static func action(
        for entry: TimeEntrySnapshot,
        existingIdentifier: String?,
        isDeleted: Bool,
        policy: TimeMirrorPolicy,
        now: Date
    ) -> TimeMirrorAction {
        // A mirror that is off does not tidy up after itself. Turning it off must not delete a
        // month of events somebody may be relying on — that is a decision with its own button, and
        // it is not one a toggle should make silently.
        guard policy.isUsable else { return .none }

        guard !isDeleted, let endedAt = entry.endedAt else {
            return existingIdentifier.map { .remove(identifier: $0) } ?? .none
        }

        let duration = max(0, endedAt.timeIntervalSince(entry.startedAt))
        guard duration >= policy.minimumDuration, duration > 0 else {
            return existingIdentifier.map { .remove(identifier: $0) } ?? .none
        }

        // Nothing is written for time that has not happened yet: a start date typed wrong by a year
        // would otherwise put a phantom afternoon in next spring's calendar.
        guard entry.startedAt <= now else {
            return existingIdentifier.map { .remove(identifier: $0) } ?? .none
        }

        let fields = TimeMirrorFields(
            title: title(for: entry, policy: policy),
            notes: notes(for: entry, policy: policy),
            startedAt: entry.startedAt,
            endedAt: endedAt
        )

        if let existingIdentifier {
            return .update(identifier: existingIdentifier, fields: fields)
        }
        return .create(fields)
    }

    /// What the event is called.
    ///
    /// The subject leads and the description follows it, which is the order the log itself uses: an
    /// hour against *Draft the brief* is that, and what you typed is a note about this particular
    /// stretch of it. An entry with neither is called after the time it took rather than "Untitled",
    /// because a calendar full of Untitled is a calendar that gets deleted.
    public static func title(for entry: TimeEntrySnapshot, policy: TimeMirrorPolicy) -> String {
        let subject = policy.includesSubject ? (entry.itemTitle ?? "") : ""
        let description = entry.entryDescription.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (subject.isEmpty, description.isEmpty) {
        case (false, false) where subject == description:
            return subject
        case (false, false):
            return "\(subject) — \(description)"
        case (false, true):
            return subject
        case (true, false):
            return description
        case (true, true):
            return "Tracked time"
        }
    }

    /// What goes in the notes: the marker, and the tags if they are wanted.
    ///
    /// Nothing else can ever appear here — see the note on ``TimeMirrorFields``.
    public static func notes(for entry: TimeEntrySnapshot, policy: TimeMirrorPolicy) -> String {
        guard policy.includesTags, !entry.tagSlugs.isEmpty else { return marker }
        return "\(entry.tagSlugs.sorted().map { "#\($0)" }.joined(separator: " "))\n\n\(marker)"
    }
}
