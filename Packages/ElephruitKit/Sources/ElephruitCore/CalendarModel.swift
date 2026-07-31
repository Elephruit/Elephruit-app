import Foundation

// MARK: - Accounts and calendars

/// Where a calendar's events actually live.
///
/// Kept as a closed vocabulary rather than passing EventKit's `EKSourceType` around, because the
/// distinction the interface needs is not the framework's: a user thinks in terms of "my work
/// Exchange account" and "the holidays feed I subscribed to", and the second of those is read-only
/// for reasons that have nothing to do with permissions.
public enum CalendarAccountKind: String, Sendable, Hashable, Codable, CaseIterable {
    case local
    case iCloud
    case exchange
    case google
    case subscribed
    case birthdays
    case other

    public var displayName: String {
        switch self {
        case .local: "On My Mac"
        case .iCloud: "iCloud"
        case .exchange: "Exchange"
        case .google: "Google"
        case .subscribed: "Subscribed"
        case .birthdays: "Birthdays"
        case .other: "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .local: "internaldrive"
        case .iCloud: "icloud"
        case .exchange: "building.2"
        case .google: "globe"
        case .subscribed: "antenna.radiowaves.left.and.right"
        case .birthdays: "birthday.cake"
        case .other: "calendar"
        }
    }

    /// Whether events in this account can ever be changed, regardless of the calendar's own flag.
    ///
    /// Subscribed feeds and the generated birthday calendar are read-only at the source. Saying so
    /// up front means the editor can explain *why* rather than reporting a failure after someone has
    /// typed a title.
    public var isInherentlyReadOnly: Bool {
        self == .subscribed || self == .birthdays
    }
}

/// One calendar the user has configured, as the app understands it.
///
/// A value rather than an `EKCalendar`, on the same terms as ``CalendarEventSummary``: nothing
/// outside the integrations module depends on EventKit, and a test can build one in a line.
public struct CalendarInfo: Sendable, Hashable, Identifiable, Codable {
    /// `EKCalendar.calendarIdentifier`.
    ///
    /// Device-local and **not** stable across a calendar being removed and re-added, which is why
    /// anything persisted alongside it — a Calendar Set, a default calendar — also stores the title
    /// and account so it can be re-found. See ``CalendarReference``.
    public var id: String

    public var title: String

    /// A ``Theme.Palette`` key, never a raw colour. See ``CalendarPalette``.
    public var colorName: String

    /// `EKSource.title` — "iCloud", "Google", the Exchange account's name.
    public var accountName: String

    public var accountKind: CalendarAccountKind

    /// Whether events in this calendar may be created, edited, or deleted.
    public var allowsModification: Bool

    /// Whether this is the store's default calendar for new events.
    public var isDefaultForNewEvents: Bool

    public init(
        id: String,
        title: String,
        colorName: String = "blue",
        accountName: String = "",
        accountKind: CalendarAccountKind = .other,
        allowsModification: Bool = true,
        isDefaultForNewEvents: Bool = false
    ) {
        self.id = id
        self.title = title
        self.colorName = colorName
        self.accountName = accountName
        self.accountKind = accountKind
        self.allowsModification = allowsModification && !accountKind.isInherentlyReadOnly
        self.isDefaultForNewEvents = isDefaultForNewEvents
    }

    /// Why this calendar cannot be written to, or `nil` when it can.
    ///
    /// A sentence rather than a boolean, because "you cannot edit this" without a reason reads as a
    /// bug. A subscribed feed and a delegated calendar are refused for entirely different reasons and
    /// the user can act on only one of them.
    public var readOnlyExplanation: String? {
        guard !allowsModification else { return nil }
        switch accountKind {
        case .subscribed:
            return "This is a subscribed calendar. Its events are published by whoever maintains the feed."
        case .birthdays:
            return "Birthdays come from your contacts. Edit the person's card to change one."
        default:
            return "This calendar is read-only in \(accountName.isEmpty ? "its account" : accountName)."
        }
    }

    /// A durable way to name this calendar again after a restart or a re-added account.
    public var reference: CalendarReference {
        CalendarReference(identifier: id, title: title, accountName: accountName)
    }
}

/// A calendar named in a way that survives its identifier changing.
///
/// ### Why the identifier alone is not enough
/// `EKCalendar.calendarIdentifier` is local to a device's store. Removing a Google account and adding
/// it back produces the same calendars with different identifiers, and a Calendar Set that stored
/// only identifiers would silently empty itself — the failure being invisible until someone noticed
/// their Work set showed nothing.
///
/// So a stored reference keeps the title and account too, and resolution falls back to matching on
/// those. That fallback can be wrong in principle (two calendars called "Work" in two accounts) and
/// is disambiguated by the account name, which is the pair a user would use themselves.
public struct CalendarReference: Sendable, Hashable, Codable {
    public var identifier: String
    public var title: String
    public var accountName: String

    public init(identifier: String, title: String = "", accountName: String = "") {
        self.identifier = identifier
        self.title = title
        self.accountName = accountName
    }

    /// The best match for this reference among the calendars that currently exist.
    ///
    /// Identifier first, then title-and-account, then title alone. Returns `nil` when nothing
    /// matches, which the interface reports as "unavailable" rather than dropping from the set — a
    /// calendar that is merely offline should come back when it returns.
    public func resolve(among calendars: [CalendarInfo]) -> CalendarInfo? {
        if let exact = calendars.first(where: { $0.id == identifier }) { return exact }

        if !title.isEmpty {
            if let pair = calendars.first(where: { $0.title == title && $0.accountName == accountName }) {
                return pair
            }
            // Only when the title is unambiguous. Picking one of two calendars called "Work" would
            // put somebody's private appointments in front of their colleagues.
            let byTitle = calendars.filter { $0.title == title }
            if byTitle.count == 1 { return byTitle.first }
        }

        return nil
    }
}

// MARK: - Colour

/// Maps a calendar's own colour onto the app's named palette.
///
/// ### Why the real colour is not used
/// A raw `CGColor` from EventKit is a fixed triple. It is wrong in at least one of light mode, dark
/// mode, and Increase Contrast — the same argument that makes `Theme.Colors` semantic throughout —
/// and `SourceHygieneTests.coloursComeFromTheDesignSystem` exists to stop exactly that value reaching
/// a view. So the colour is read once, at the boundary, and reduced to the nearest palette *name*,
/// which then resolves through AppKit in every appearance.
///
/// The cost is fidelity: a calendar the user tinted a particular teal becomes "teal". The benefit is
/// that their calendar is legible at night, which matters more.
public enum CalendarPalette {
    /// Every palette name this can return, in the order hues are searched.
    ///
    /// Mirrors `Theme.Palette` deliberately rather than importing it: this module knows nothing about
    /// SwiftUI, and `PaletteNamesAreRealTests` fails if the two lists ever disagree.
    public static let names = [
        "red", "orange", "yellow", "green", "mint", "teal",
        "cyan", "blue", "indigo", "purple", "pink", "brown", "graphite",
    ]

    /// Representative hue angles, in degrees, for each named colour.
    ///
    /// Spaced by where the *name* stops being right rather than by where the system colour happens
    /// to sit. `systemBlue` is nearer 212°, but pure blue is 240° and nobody calls that indigo, so
    /// blue's anchor is pulled up to keep the boundary between the two where a person would put it.
    private static let hues: [(name: String, hue: Double)] = [
        ("red", 0),
        ("orange", 30),
        ("yellow", 55),
        ("green", 120),
        ("mint", 155),
        ("teal", 178),
        ("cyan", 195),
        ("blue", 225),
        ("indigo", 262),
        ("purple", 290),
        ("pink", 330),
    ]

    /// The nearest palette name to an sRGB colour.
    ///
    /// Saturation and brightness are consulted before hue: an almost-grey colour has no meaningful
    /// hue at all, and rounding it to "red" because its red channel happens to lead would be worse
    /// than admitting it is grey.
    public static func name(red: Double, green: Double, blue: Double) -> String {
        let clamped = (r: clamp(red), g: clamp(green), b: clamp(blue))
        let maximum = max(clamped.r, clamped.g, clamped.b)
        let minimum = min(clamped.r, clamped.g, clamped.b)
        let delta = maximum - minimum

        guard delta > 0.08, maximum > 0.15 else { return "graphite" }

        var hue: Double
        if maximum == clamped.r {
            hue = 60 * (((clamped.g - clamped.b) / delta).truncatingRemainder(dividingBy: 6))
        } else if maximum == clamped.g {
            hue = 60 * (((clamped.b - clamped.r) / delta) + 2)
        } else {
            hue = 60 * (((clamped.r - clamped.g) / delta) + 4)
        }
        if hue < 0 { hue += 360 }

        // Brown is a dark, desaturated orange, and calling it orange loses the one distinction a
        // user would notice.
        if (15...45).contains(hue), maximum < 0.6, delta < 0.5 { return "brown" }

        let nearest = hues.min { left, right in
            angularDistance(hue, left.hue) < angularDistance(hue, right.hue)
        }
        return nearest?.name ?? "blue"
    }

    private static func angularDistance(_ first: Double, _ second: Double) -> Double {
        let raw = abs(first - second).truncatingRemainder(dividingBy: 360)
        return min(raw, 360 - raw)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

// MARK: - Availability

/// How an event affects the time it occupies.
public enum EventAvailability: String, Sendable, Hashable, Codable, CaseIterable {
    case busy
    case free
    case tentative
    case unavailable

    /// What the calendar's account does not offer. Never chosen; only reported.
    case notSupported

    public var displayName: String {
        switch self {
        case .busy: "Busy"
        case .free: "Free"
        case .tentative: "Tentative"
        case .unavailable: "Out of office"
        case .notSupported: "Not supported"
        }
    }

    /// The options an editor may offer. `notSupported` is deliberately absent.
    public static var selectable: [EventAvailability] {
        [.busy, .free, .tentative, .unavailable]
    }

    /// Whether time marked this way should read as spoken for in a day's plan.
    public var occupiesTime: Bool {
        self == .busy || self == .unavailable
    }
}

// MARK: - Alarms

/// A reminder attached to an event.
///
/// Either relative to the start — the usual shape, and the one that survives the event being
/// moved — or absolute, which EventKit also supports and which a synced event may arrive carrying.
public struct EventAlarm: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID

    /// Seconds relative to the event's start. **Negative means before**, which is EventKit's own
    /// convention and is preserved rather than flipped, so nothing has to remember which way round
    /// the sign goes at each boundary.
    public var relativeOffset: TimeInterval?

    /// A fixed instant, when the alarm is not relative to anything.
    public var absoluteDate: Date?

    public init(id: UUID = UUID(), relativeOffset: TimeInterval? = nil, absoluteDate: Date? = nil) {
        self.id = id
        self.relativeOffset = relativeOffset
        self.absoluteDate = absoluteDate
    }

    /// An alarm a given number of minutes before the event.
    public static func minutesBefore(_ minutes: Int) -> EventAlarm {
        EventAlarm(relativeOffset: TimeInterval(-minutes * 60))
    }

    public static func at(_ date: Date) -> EventAlarm {
        EventAlarm(absoluteDate: date)
    }

    /// The presets an editor offers, in the order people reach for them.
    public static let commonOffsets: [Int] = [0, 5, 10, 15, 30, 60, 120, 1_440, 2_880, 10_080]

    public var displayName: String {
        if let absoluteDate {
            return absoluteDate.formatted(date: .abbreviated, time: .shortened)
        }
        guard let relativeOffset else { return "At the time of the event" }

        let minutes = Int((-relativeOffset / 60).rounded())
        switch minutes {
        case ..<0: return Self.durationPhrase(-minutes) + " after"
        case 0: return "At the time of the event"
        default: return Self.durationPhrase(minutes) + " before"
        }
    }

    static func durationPhrase(_ minutes: Int) -> String {
        switch minutes {
        case ..<60:
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        case ..<1_440:
            let hours = minutes / 60
            let remainder = minutes % 60
            let base = "\(hours) hour\(hours == 1 ? "" : "s")"
            return remainder == 0 ? base : "\(base) \(remainder) min"
        case ..<10_080:
            let days = minutes / 1_440
            return "\(days) day\(days == 1 ? "" : "s")"
        default:
            let weeks = minutes / 10_080
            return "\(weeks) week\(weeks == 1 ? "" : "s")"
        }
    }

    /// When this alarm would fire for an event starting at `start`.
    public func fireDate(forEventStartingAt start: Date) -> Date? {
        if let absoluteDate { return absoluteDate }
        guard let relativeOffset else { return nil }
        return start.addingTimeInterval(relativeOffset)
    }
}

// MARK: - Attendees

/// Somebody's part in a meeting.
public enum EventAttendeeRole: String, Sendable, Hashable, Codable, CaseIterable {
    case required
    case optional
    case chair
    case nonParticipant
    case unknown

    public var displayName: String {
        switch self {
        case .required: "Required"
        case .optional: "Optional"
        case .chair: "Chair"
        case .nonParticipant: "Informed"
        case .unknown: "Attendee"
        }
    }
}

/// One person on an event's invitation list.
///
/// **Read-only.** EventKit exposes attendees but offers no supported way to add or remove one — an
/// `EKParticipant` cannot be constructed and `EKEvent.attendees` has no setter. So this type carries
/// what a synced invitation already holds, and the editor displays it without pretending it can be
/// changed. See `docs/25-calendar-module-record.md`.
public struct EventAttendee: Sendable, Hashable, Identifiable, Codable {
    /// The email address where there is one, otherwise the name — enough to be stable within an
    /// event, which is all this identifies.
    public var id: String

    public var name: String
    public var emailAddress: String?
    public var participation: EventParticipation
    public var role: EventAttendeeRole
    public var isOrganizer: Bool
    public var isCurrentUser: Bool

    public init(
        name: String,
        emailAddress: String? = nil,
        participation: EventParticipation = .unknown,
        role: EventAttendeeRole = .unknown,
        isOrganizer: Bool = false,
        isCurrentUser: Bool = false
    ) {
        self.id = emailAddress?.lowercased() ?? name.lowercased()
        self.name = name
        self.emailAddress = emailAddress
        self.participation = participation
        self.role = role
        self.isOrganizer = isOrganizer
        self.isCurrentUser = isCurrentUser
    }

    public var displayName: String {
        if !name.isEmpty { return name }
        return emailAddress ?? "Unknown"
    }

    /// Initials for an avatar, when no photo is available.
    public var initials: String {
        let source = name.isEmpty ? (emailAddress ?? "") : name
        let words = source
            .split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "@" })
            .prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }
        return letters.joined().uppercased()
    }
}
