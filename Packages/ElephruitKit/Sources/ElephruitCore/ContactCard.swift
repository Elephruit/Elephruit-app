import Foundation

/// Which side of somebody's life a labelled detail belongs to.
///
/// ### Why this is derived from the label rather than stored
/// Contacts already records the distinction — a number labelled "work", an address labelled "home" —
/// and it is the *user's* answer, edited in the app they keep their address book in. Storing a second
/// copy would mean deciding what happens when the two disagree, and the honest answer is that the
/// address book wins. So the label is read every time and nothing is written.
///
/// ### Why there are only three cases
/// ``unspecified`` is not a failure to classify; it is the truthful answer for "mobile", "iPhone",
/// "main", and every custom label somebody typed themselves. A person's mobile is not evidence about
/// whether they are a colleague or a friend, and guessing would put a confident wrong badge on a row.
public enum ContactAffinity: String, Sendable, Hashable, CaseIterable, Codable {
    case personal
    case work

    /// Neither stated nor inferable — a mobile number, "main", or a label the user invented.
    case unspecified

    public var displayName: String {
        switch self {
        case .personal: "Personal"
        case .work: "Work"
        case .unspecified: "Other"
        }
    }

    /// Paired with the colour everywhere it is shown, so the distinction survives for somebody who
    /// cannot tell teal from indigo.
    public var symbolName: String {
        switch self {
        case .personal: "house"
        case .work: "briefcase"
        case .unspecified: "tag"
        }
    }

    /// The order groups appear in on a person's card.
    ///
    /// Stable rather than meaningful: a card that reshuffles when a detail is added is harder to read
    /// than one whose sections are always in the same place. ``unspecified`` is last because it is
    /// the remainder.
    public var sortOrder: Int {
        switch self {
        case .personal: 0
        case .work: 1
        case .unspecified: 2
        }
    }
}

/// What kind of thing a stored contact detail is.
///
/// Distinct from ``ContactDestinationSource``, which answers "what can this channel dial" and so
/// carries a `phoneOrEmail` case that no *stored* value ever has. This enum describes the value;
/// that one describes what an action will accept. ``ContactDetailKind/destinationSource`` bridges
/// them, so the two never drift.
public enum ContactDetailKind: String, Sendable, Hashable, CaseIterable, Codable {
    case email
    case phone
    case address
    case website

    public var displayName: String {
        switch self {
        case .email: "Email"
        case .phone: "Phone"
        case .address: "Address"
        case .website: "Website"
        }
    }

    public var symbolName: String {
        switch self {
        case .email: "envelope"
        case .phone: "phone"
        case .address: "mappin.and.ellipse"
        case .website: "safari"
        }
    }

    public var destinationSource: ContactDestinationSource {
        switch self {
        case .email: .email
        case .phone: .phone
        case .address: .address
        case .website: .website
        }
    }

    /// The order a card reads in. Reachability first: how to write to somebody, then how to ring
    /// them, then where they are.
    public var sortOrder: Int {
        switch self {
        case .email: 0
        case .phone: 1
        case .address: 2
        case .website: 3
        }
    }
}

/// One labelled contact detail, ready to be shown.
public struct ContactDetail: Sendable, Hashable, Identifiable {
    /// Derived from the value rather than random, so a redraw does not re-identify every row and
    /// SwiftUI keeps its animations and selection.
    public var id: String { "\(kind.rawValue)|\(label)|\(value)" }

    public var kind: ContactDetailKind
    public var label: String
    public var value: String

    public init(kind: ContactDetailKind, label: String, value: String) {
        self.kind = kind
        self.label = label
        self.value = value
    }

    public var affinity: ContactAffinity { ContactLabelReader.affinity(of: label) }

    /// The label as it should read on screen — "Work", "Beach house" — or the kind's own name when
    /// the detail carries no label at all.
    public var displayLabel: String {
        ContactLabelReader.displayName(of: label) ?? kind.displayName
    }
}

/// Reads what a contact label means.
///
/// Pure and case-folded, so "Work", "WORK", and "wörk" agree. Matching is on whole words rather than
/// substrings: "homework" is not a home address, and "network" is not a work one.
public enum ContactLabelReader {
    /// Words that mean this is part of somebody's working life.
    private static let workWords: Set<String> = ["work", "office", "business", "job", "employer"]

    /// Words that mean this is part of their private life.
    ///
    /// "iCloud" is included because it is an account somebody holds as a person, never one an
    /// employer issues — the one apparent exception that is not a guess.
    ///
    /// "House" is deliberately absent. It reads as a residence in "Beach house" and as an employer in
    /// "Halcyon Publishing House", and a label the user invented for themselves is better left
    /// unclassified than classified wrongly half the time.
    private static let personalWords: Set<String> = ["home", "personal", "private", "family", "icloud"]

    public static func affinity(of label: String) -> ContactAffinity {
        let words = Set(
            TextNormalizer.foldedForMatching(label)
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
        )

        // Checked in this order because "home office" is a work address that happens to be at home,
        // and labelling it "Personal" would put a colleague's number under the wrong heading.
        if !words.isDisjoint(with: workWords) { return .work }
        if !words.isDisjoint(with: personalWords) { return .personal }
        return .unspecified
    }

    /// A label fit to show, or `nil` when there is nothing to show.
    ///
    /// Capitalises only labels that arrive lower-cased from the address book. A label the user typed
    /// themselves — "Beach house", "Mum's" — is returned exactly as written, because they already
    /// chose how it should read.
    public static func displayName(of label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed == trimmed.lowercased() else { return trimmed }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }
}

/// A person's contact details, grouped for display.
public struct ContactDetailGroup: Sendable, Hashable, Identifiable {
    public var id: String { affinity.rawValue }
    public var affinity: ContactAffinity
    public var details: [ContactDetail]

    public init(affinity: ContactAffinity, details: [ContactDetail]) {
        self.affinity = affinity
        self.details = details
    }
}

/// How a person's stored details are ordered, grouped, and reduced to a line in a list.
///
/// Every function here is pure, so what a row says can be asserted in a test rather than reviewed in
/// a screenshot — which is the only kind of check that stays true after the next edit.
public enum ContactCard {
    /// Every detail in card order: emails, phones, addresses, websites, each keeping the order the
    /// address book stored them in, because that order is the user's own ranking.
    public static func details(
        emails: [(label: String, value: String)] = [],
        phones: [(label: String, value: String)] = [],
        addresses: [(label: String, value: String)] = [],
        websites: [(label: String, value: String)] = []
    ) -> [ContactDetail] {
        func build(_ kind: ContactDetailKind, _ values: [(label: String, value: String)]) -> [ContactDetail] {
            values.compactMap { entry in
                let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                return ContactDetail(kind: kind, label: entry.label, value: value)
            }
        }

        return build(.email, emails)
            + build(.phone, phones)
            + build(.address, addresses)
            + build(.website, websites)
    }

    /// The details worth putting in a list row, best first.
    ///
    /// One of each kind before a second of any kind: an email *and* a number answers "how do I reach
    /// this person" in a way that two email addresses does not. Within a kind the stored order wins.
    public static func rowDetails(from details: [ContactDetail], limit: Int = 2) -> [ContactDetail] {
        guard limit > 0 else { return [] }

        var chosen: [ContactDetail] = []
        var used = Set<Int>()

        var seenKinds = Set<ContactDetailKind>()
        for (index, detail) in details.enumerated() where !seenKinds.contains(detail.kind) {
            seenKinds.insert(detail.kind)
            used.insert(index)
            chosen.append(detail)
            if chosen.count == limit { return chosen }
        }

        for (index, detail) in details.enumerated() where !used.contains(index) {
            chosen.append(detail)
            if chosen.count == limit { break }
        }

        return chosen
    }

    /// The details grouped by which side of somebody's life they belong to.
    ///
    /// Empty groups are omitted rather than shown empty: a card with a "Work" heading and nothing
    /// under it implies a gap the user is expected to fill, which is not what the app is for.
    public static func groups(from details: [ContactDetail]) -> [ContactDetailGroup] {
        Dictionary(grouping: details, by: \.affinity)
            .map { affinity, group in
                ContactDetailGroup(
                    affinity: affinity,
                    details: group.sorted { $0.kind.sortOrder < $1.kind.sortOrder }
                )
            }
            .sorted { $0.affinity.sortOrder < $1.affinity.sortOrder }
    }

    /// Role, organisation, and place — the line that says *who somebody is* rather than how to reach
    /// them.
    ///
    /// ### Why the name is passed in
    /// Address books imported from elsewhere routinely carry the person's own name in the company
    /// field, and a row that reads "Caroline Howe / Caroline Howe" spends its second line saying
    /// nothing. Anything that merely repeats the name is dropped, so the line is either informative
    /// or absent.
    public static func identityLine(
        name: String,
        role: String? = nil,
        organization: String? = nil,
        location: String? = nil
    ) -> String? {
        let folded = TextNormalizer.foldedForMatching(name)

        let parts = [role, organization, location]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { TextNormalizer.foldedForMatching($0) != folded }

        // A record whose role and organisation are the same word says it once.
        var seen = Set<String>()
        let unique = parts.filter { seen.insert(TextNormalizer.foldedForMatching($0)).inserted }

        return unique.isEmpty ? nil : unique.joined(separator: " · ")
    }
}
