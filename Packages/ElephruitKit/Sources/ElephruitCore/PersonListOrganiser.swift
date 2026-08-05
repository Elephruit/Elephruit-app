import Foundation

/// How a list of people is ordered.
public enum PersonListSort: String, Sendable, Hashable, CaseIterable, Codable, Identifiable {
    case firstName
    case lastName
    case organization
    case recentInteraction

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .firstName: "First Name"
        case .lastName: "Last Name"
        case .organization: "Organization"
        case .recentInteraction: "Recent Interaction"
        }
    }

    /// Whether this order can be cut into alphabetical sections at all.
    ///
    /// Ordering by when you last spoke to somebody cannot: the sections would be letters in an order
    /// that has nothing to do with letters, and a jump control over them would move the list somewhere
    /// arbitrary. That order gets time sections instead — see ``PersonListOrganiser``.
    public var isAlphabetical: Bool {
        self != .recentInteraction
    }

    /// What the quick-jump rail jumps *by*, said in one word.
    ///
    /// For the tooltip and the VoiceOver label, which have to be specific: "jump to a section" leaves
    /// somebody who cannot see the list to guess which part of a name a letter refers to, and in this
    /// app the answer changes with the order. Under family-name order the M's are the Mendozas;
    /// under first-name order they are the Mayas; under organisation they are not names at all.
    public var jumpLabel: String {
        switch self {
        case .firstName: "first name"
        case .lastName: "surname"
        case .organization: "company"
        case .recentInteraction: "period"
        }
    }
}

/// One person, reduced to what ordering and sectioning need.
///
/// A value rather than the stored record, so the whole of this file is testable without a database
/// and so sectioning eight thousand people does not mean touching eight thousand managed objects.
public struct PersonListEntry: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var organizationName: String?

    /// When this person was last interacted with, for ``PersonListSort/recentInteraction``.
    public var lastInteraction: Date?

    /// Carried here so a row can draw its star and its avatar tint without touching the record.
    ///
    /// An entry is everything a list row *shows*, computed once when the list is built. The row
    /// used to read these two — and the organisation, which meant faulting the profile
    /// relationship — straight off the live model, which put a store read inside every row body
    /// and made appearing rows the most expensive thing a scroll did.
    public var isFavorite: Bool
    public var colorName: String?

    /// What sort of record this is, so a row can tell a person from a car.
    ///
    /// A monogram is the right picture of a human being and the wrong picture of a Toyota: "TC" in
    /// a circle says *somebody called T— C—*. Records that are not people keep their type's glyph,
    /// and the decision is made here, once, from a value the list already had to compute.
    public var recordType: RecordType

    /// The linked `CNContact.identifier`, when the person has one.
    ///
    /// Here for the same reason the tint is: a photograph is fetched by identifier, and asking the
    /// record for it inside a row body would fault the contact-link relationship on every row that
    /// scrolled past — which is precisely the cost the two properties above were moved here to
    /// avoid. The identifier is a pointer, not a picture; nothing is read from the address book
    /// until a row is actually on screen. See `ContactPhotoStore`.
    public var contactIdentifier: String?

    public init(
        id: UUID,
        displayName: String,
        organizationName: String? = nil,
        lastInteraction: Date? = nil,
        isFavorite: Bool = false,
        colorName: String? = nil,
        recordType: RecordType = .person,
        contactIdentifier: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.organizationName = organizationName
        self.lastInteraction = lastInteraction
        self.isFavorite = isFavorite
        self.colorName = colorName
        self.recordType = recordType
        self.contactIdentifier = contactIdentifier
    }
}

/// A run of people under one heading.
public struct PersonListSection: Sendable, Hashable, Identifiable {
    /// What the header and the jump control both show — "A", "#", "日", "This week".
    public var title: String
    public var entries: [PersonListEntry]

    public var id: String { title }

    public init(title: String, entries: [PersonListEntry]) {
        self.title = title
        self.entries = entries
    }
}

/// Cuts a list of people into headed sections, in whichever order was asked for.
///
/// ### Why the index is built from the data rather than from A to Z
/// A fixed A–Z strip is a promise about the alphabet, and the alphabet is a property of the language
/// the names are in. Swedish has three letters after Z; Greek and Japanese and Hebrew have none of
/// these letters at all; and an address book of Berlin colleagues has no Q, X or Y in it, so a strip
/// showing them is three targets that do nothing. Building the strip from the sections that exist
/// means it is always as long as it needs to be, always in the reading order the locale gives, and
/// never contains a letter that leads nowhere.
///
/// ### What this does not claim
/// Section titles come from the first character of the folded sort name. That is right for the Latin
/// alphabets, right for Greek and Cyrillic, and only approximately right for Japanese, where the
/// conventional index is by kana reading and a name written in kanji has no first *letter* to take.
/// Those names section under their own first character, which keeps them findable and in a stable
/// place; it is not the index a Japanese address book would build, and pretending otherwise by
/// romanising them would be worse. Ordering *within* and *between* sections is always
/// ``Foundation/String/compare(_:options:range:locale:)`` with the caller's locale, so ä sorts with a
/// in German and after z in Swedish without this file knowing either fact.
public enum PersonListOrganiser {
    /// Everything under one heading that has no letter — digits, punctuation, emoji, an empty name.
    ///
    /// One bucket rather than one per symbol: nobody looks for a contact under "(" and a strip with
    /// eleven punctuation marks on it is a strip nobody can hit.
    public static let symbolSectionTitle = "#"

    /// Where somebody with no organisation goes when the list is ordered by organisation.
    public static let noOrganizationTitle = "No Organization"

    // MARK: - Sorting

    /// The string this entry sorts and sections by.
    ///
    /// Family-name order splits on the last space rather than parsing a name, because names are not
    /// parseable: "Rosa María de la Cruz" has four words and one surname, "Nguyễn" alone has none,
    /// and an organisation stored as a person — "Acme Corporation" — has no surname at all and must
    /// not acquire one. Taking the last word is wrong for some names and *predictably* wrong, which
    /// is what a sort order needs to be; a cleverer rule is wrong for different names each time and
    /// cannot be relied on to find anybody.
    public static func sortKey(for entry: PersonListEntry, sort: PersonListSort) -> String {
        switch sort {
        case .firstName, .recentInteraction:
            return entry.displayName

        case .lastName:
            let words = entry.displayName.split(separator: " ")
            guard words.count > 1, let last = words.last else { return entry.displayName }
            return String(last) + " " + words.dropLast().joined(separator: " ")

        case .organization:
            let organization = entry.organizationName?.trimmingCharacters(in: .whitespaces) ?? ""
            return organization.isEmpty ? entry.displayName : organization
        }
    }

    /// The people, in order.
    public static func sorted(
        _ entries: [PersonListEntry],
        by sort: PersonListSort,
        locale: Locale = .current
    ) -> [PersonListEntry] {
        switch sort {
        case .recentInteraction:
            // Never spoken to sorts last rather than first: a list headed by everybody you have no
            // history with is the opposite of what this order was asked for.
            return entries.sorted { left, right in
                switch (left.lastInteraction, right.lastInteraction) {
                case let (leftDate?, rightDate?) where leftDate != rightDate:
                    return leftDate > rightDate
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                default:
                    return compare(left.displayName, right.displayName, locale: locale) == .orderedAscending
                }
            }

        case .firstName, .lastName, .organization:
            let keyed = entries.map { (entry: $0, key: sortKey(for: $0, sort: sort)) }
            let sortedKeyed = keyed.sorted { left, right in
                switch compare(left.key, right.key, locale: locale) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return left.entry.id.uuidString < right.entry.id.uuidString
                }
            }
            return sortedKeyed.map(\.entry)
        }
    }

    private static func compare(_ left: String, _ right: String, locale: Locale) -> ComparisonResult {
        left.compare(
            right,
            options: [.caseInsensitive, .diacriticInsensitive, .numeric],
            range: nil,
            locale: locale
        )
    }

    // MARK: - Sectioning

    /// The heading a sort key belongs under.
    public static func sectionTitle(for key: String, locale: Locale = .current) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return symbolSectionTitle }

        // Diacritics are folded so that Ángela and Angela share a heading in the languages where
        // they should. Where they should *not* — Swedish, Norwegian, Icelandic — the locale-aware
        // comparison still orders the section correctly relative to its neighbours, which is the
        // half of the problem that actually stops somebody finding a name.
        let folded = String(first).folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: locale
        )

        guard let base = folded.first, base.isLetter else {
            return symbolSectionTitle
        }

        return String(base).uppercased(with: locale)
    }

    /// The list, cut into headed sections.
    ///
    /// - Parameter groupsWithoutOrganization: only meaningful for
    ///   ``PersonListSort/organization``, where people with no employer are collected at the end
    ///   rather than scattered under their own initials — which would put Maya Chen under M in a
    ///   list the user is reading by company.
    public static func sections(
        _ entries: [PersonListEntry],
        by sort: PersonListSort,
        locale: Locale = .current,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [PersonListSection] {
        let ordered = sorted(entries, by: sort, locale: locale)
        guard !ordered.isEmpty else { return [] }

        guard sort.isAlphabetical else {
            return timeSections(ordered, now: now, calendar: calendar)
        }

        var sections: [PersonListSection] = []
        var unfiled: [PersonListEntry] = []

        for entry in ordered {
            if sort == .organization,
               (entry.organizationName?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) {
                unfiled.append(entry)
                continue
            }

            let title = sectionTitle(for: sortKey(for: entry, sort: sort), locale: locale)

            // Appended to the open section rather than grouped into a dictionary, because the input
            // is already in order and a dictionary would throw that order away and need it sorting
            // back — which is the work this whole type exists to do once.
            if sections.last?.title == title {
                sections[sections.count - 1].entries.append(entry)
            } else {
                sections.append(PersonListSection(title: title, entries: [entry]))
            }
        }

        // Symbols and digits lead the list, the way every address book puts them, so that the
        // alphabet reads unbroken from A.
        if let symbols = sections.firstIndex(where: { $0.title == symbolSectionTitle }), symbols != 0 {
            let section = sections.remove(at: symbols)
            sections.insert(section, at: 0)
        }

        if !unfiled.isEmpty {
            sections.append(PersonListSection(title: noOrganizationTitle, entries: unfiled))
        }

        return sections
    }

    /// Sections for ``PersonListSort/recentInteraction``, which are spans of time rather than
    /// letters.
    private static func timeSections(
        _ ordered: [PersonListEntry],
        now: Date,
        calendar: Calendar
    ) -> [PersonListSection] {
        // Relative to `now`, never to the system clock. `isDateInToday(_:)` asks what day it is
        // where the process is running, which makes every heading here depend on when the test
        // happened to run — and, in the app, on a clock the whole codebase deliberately injects so
        // that "today" is something a caller states rather than something a function discovers.
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now

        func title(for date: Date?) -> String {
            guard let date else { return "Never" }
            if calendar.isDate(date, inSameDayAs: now) { return "Today" }
            if calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }

            let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
            switch days {
            case ..<7: return "This week"
            case ..<30: return "This month"
            case ..<365: return "This year"
            default: return "Longer ago"
            }
        }

        var sections: [PersonListSection] = []
        for entry in ordered {
            let heading = title(for: entry.lastInteraction)
            if sections.last?.title == heading {
                sections[sections.count - 1].entries.append(entry)
            } else {
                sections.append(PersonListSection(title: heading, entries: [entry]))
            }
        }
        return sections
    }

    // MARK: - Typing a name to reach it

    /// The entry a typed prefix should select.
    ///
    /// ### Why the nearest match rather than only an exact one
    /// Typing `mc` in a list with no McSomething should not do nothing — doing nothing is
    /// indistinguishable from the keystrokes having been dropped. It lands on the first name that
    /// sorts at or after what was typed, which is where the eye is going anyway, and one more
    /// keystroke corrects it. Returning `nil` is reserved for a list with nobody in it.
    public static func entry(
        matching typed: String,
        in sections: [PersonListSection],
        sort: PersonListSort,
        locale: Locale = .current
    ) -> PersonListEntry? {
        let query = typed.trimmingCharacters(in: .whitespaces)
        let all = sections.flatMap(\.entries)
        guard !query.isEmpty, !all.isEmpty else { return all.first }

        let keys = all.map { sortKey(for: $0, sort: sort) }

        for (index, key) in keys.enumerated()
        where key.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive, .anchored],
            range: nil,
            locale: locale
        ) != nil {
            return all[index]
        }

        for (index, key) in keys.enumerated()
        where compare(key, query, locale: locale) != .orderedAscending {
            return all[index]
        }

        return all.last
    }

    /// The section a jump control should move to for a given heading.
    ///
    /// Scrubbing past the end of the alphabet, or over a letter nobody's name begins with, lands on
    /// the nearest section that exists rather than nowhere — which is what makes dragging down the
    /// strip feel continuous instead of sticky.
    public static func section(
        nearest title: String,
        in sections: [PersonListSection],
        locale: Locale = .current
    ) -> PersonListSection? {
        guard !sections.isEmpty else { return nil }
        if let exact = sections.first(where: { $0.title == title }) { return exact }

        return sections.first { compare($0.title, title, locale: locale) != .orderedAscending }
            ?? sections.last
    }
}
