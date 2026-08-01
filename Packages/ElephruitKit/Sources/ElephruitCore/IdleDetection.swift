import Foundation

/// A stretch during which a timer ran and the machine saw nobody.
///
/// ### Why this is not the same as crash recovery
/// ``TimerRecovery`` answers *the app was not running, what happened to the timer?* This answers a
/// question the existing machinery cannot see at all: the app **was** running, faithfully writing
/// its heartbeat every thirty seconds, and nobody touched the keyboard for two hours. Every one of
/// those heartbeats is true and every one of them is beside the point. A timer left going over
/// lunch is the ordinary way an hour of work becomes three, and it is invisible to a check that
/// only asks whether the process survived.
///
/// A value rather than a decision, on the same terms as ``TimerRecovery``: presented, never
/// resolved on the user's behalf. The machine cannot tell reading a document from being at lunch,
/// and guessing wrong destroys either an hour of real work or an hour of honest billing.
public struct IdleObservation: Sendable, Hashable, Identifiable {
    /// The entry that was running throughout.
    public var id: UUID

    public var entryDescription: String
    public var itemTitle: String?

    /// The last moment the machine saw input — where the timer would stop if the gap is discarded.
    public var idleSince: Date

    /// When input resumed.
    public var idleUntil: Date

    public init(
        id: UUID,
        entryDescription: String,
        itemTitle: String?,
        idleSince: Date,
        idleUntil: Date
    ) {
        self.id = id
        self.entryDescription = entryDescription
        self.itemTitle = itemTitle
        self.idleSince = idleSince
        self.idleUntil = idleUntil
    }

    public var duration: TimeInterval {
        max(0, idleUntil.timeIntervalSince(idleSince))
    }

    public var displayTitle: String {
        if let itemTitle, !itemTitle.isEmpty { return itemTitle }
        if !entryDescription.isEmpty { return entryDescription }
        return "an untitled timer"
    }
}

/// The four things a user may do about time that passed with nobody at the machine.
///
/// Four rather than two, and the two extra ones carry their weight. *Discard and continue* is the
/// answer to lunch — the gap goes, the work resumes, and the alternative is stopping and starting a
/// timer by hand while remembering what it was called. *Keep as a separate entry* is the answer to
/// a phone call: the machine genuinely saw nothing, the time genuinely happened, and it belongs in
/// the log as its own row rather than silently inside the work either side of it.
public enum IdleChoice: String, Sendable, Hashable, CaseIterable {
    /// Stop the timer where the input stopped. The gap never happened.
    case discard

    /// Stop it there, and start the same timer again now.
    case discardAndContinue

    /// The gap was work. Nothing changes.
    case keep

    /// Split the gap out as its own row, and carry on timing.
    case keepAsSeparateEntry

    public var displayName: String {
        switch self {
        case .discard: "Discard"
        case .discardAndContinue: "Discard and Continue"
        case .keep: "Keep"
        case .keepAsSeparateEntry: "Keep Separately"
        }
    }

    public var hint: String {
        switch self {
        case .discard: "Stop the timer where the typing stopped."
        case .discardAndContinue: "Stop it there and start the same timer again now."
        case .keep: "Count the whole gap as worked."
        case .keepAsSeparateEntry: "Give the gap its own row and keep timing."
        }
    }
}

/// What the description on a split-out idle entry says.
///
/// It has to differ from the entry it was split from, and that is not cosmetic: the log collapses
/// rows that match on description, subject and tags, so an idle stretch carrying the same
/// description as the work either side of it would fold straight back into that work and undo the
/// separation the user just asked for. See ``TimeLog``.
public let idleEntryDescription = "Away"
