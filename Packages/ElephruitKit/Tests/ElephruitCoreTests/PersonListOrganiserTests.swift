import ElephruitCore
import Foundation
import Testing

/// How a large address book is cut up so that somebody can be reached without scrolling.
///
/// The datasets here are deliberately the awkward ones rather than the typical ones: a list of
/// tidy English names demonstrates nothing about sectioning. Numbers, symbols, accents, non-Latin
/// scripts, organisations stored as people, duplicate names, one-word names and empty names are all
/// present in any real address book and each of them is a way for an index to acquire a heading that
/// leads nowhere or lose somebody entirely.
@Suite("Person list organiser")
struct PersonListOrganiserTests {
    private func person(
        _ name: String,
        organization: String? = nil,
        lastInteraction: Date? = nil
    ) -> PersonListEntry {
        PersonListEntry(
            id: UUID(),
            displayName: name,
            organizationName: organization,
            lastInteraction: lastInteraction
        )
    }

    private let english = Locale(identifier: "en_GB")

    // MARK: - Sectioning

    @Test("People are grouped under their initial, in order")
    func basicSectioning() {
        let sections = PersonListOrganiser.sections(
            [person("Maya Chen"), person("Alice Brown"), person("Ada Lovelace"), person("Zoë Ball")],
            by: .firstName,
            locale: english
        )

        #expect(sections.map(\.title) == ["A", "M", "Z"])
        #expect(sections[0].entries.map(\.displayName) == ["Ada Lovelace", "Alice Brown"])
    }

    @Test("Digits and symbols share one heading, and it comes first")
    func symbolsLeadTheList() {
        let sections = PersonListOrganiser.sections(
            [person("Maya Chen"), person("3M"), person("+44 Support"), person("Álvaro Díaz")],
            by: .firstName,
            locale: english
        )

        #expect(sections.first?.title == "#")
        #expect(sections.first?.entries.count == 2, "a digit and a plus sign do not need a heading each")
        #expect(sections.map(\.title) == ["#", "A", "M"])
    }

    @Test("An empty name is filed rather than dropped")
    func emptyNames() {
        let sections = PersonListOrganiser.sections(
            [person(""), person("   "), person("Maya Chen")],
            by: .firstName,
            locale: english
        )

        #expect(sections.flatMap(\.entries).count == 3)
        #expect(sections.first?.title == "#")
    }

    /// A name with no first letter must not acquire a heading that reads as a letter.
    @Test("Emoji and punctuation land under the symbol heading")
    func nonLetterInitials() {
        let sections = PersonListOrganiser.sections(
            [person("🎂 Birthday List"), person("(old) Contacts"), person("Maya Chen")],
            by: .firstName,
            locale: english
        )

        #expect(sections.first?.title == "#")
        #expect(sections.first?.entries.count == 2)
    }

    @Test("Accented names share a heading with their base letter")
    func accents() {
        let sections = PersonListOrganiser.sections(
            [person("Ángela Ruiz"), person("Anna Smith"), person("Åke Lund")],
            by: .firstName,
            locale: english
        )

        #expect(sections.map(\.title) == ["A"])
        #expect(sections[0].entries.count == 3)
    }

    /// A strip promising letters the data has none of is a row of targets that do nothing.
    @Test("The index contains only headings that exist")
    func indexIsBuiltFromTheData() {
        let sections = PersonListOrganiser.sections(
            [person("Maya Chen"), person("Nisha Patel")],
            by: .firstName,
            locale: english
        )

        #expect(sections.map(\.title) == ["M", "N"])
    }

    @Test("Non-Latin names keep their own initial rather than being romanised")
    func nonLatinScripts() {
        let sections = PersonListOrganiser.sections(
            [person("日本語 太郎"), person("Δημήτρης Παπάς"), person("Мария Иванова"), person("Maya Chen")],
            by: .firstName,
            locale: english
        )

        let titles = Set(sections.map(\.title))
        #expect(titles.contains("M"))
        #expect(!titles.contains("#"), "a name in another script is not a symbol")
        #expect(sections.flatMap(\.entries).count == 4)
    }

    @Test("Every person appears in exactly one section")
    func nobodyIsLostOrDuplicated() {
        let people = (0..<500).map { person("Person \($0)") }
            + [person("3M"), person(""), person("Ángela"), person("日本語")]

        for sort in PersonListSort.allCases {
            let sections = PersonListOrganiser.sections(people, by: sort, locale: english)
            let ids = sections.flatMap(\.entries).map(\.id)

            #expect(ids.count == people.count, "\(sort) lost somebody")
            #expect(Set(ids).count == people.count, "\(sort) duplicated somebody")
        }
    }

    @Test("Nobody in, no sections out")
    func empty() {
        #expect(PersonListOrganiser.sections([], by: .firstName, locale: english).isEmpty)
    }

    // MARK: - Orders

    @Test("Family-name order takes the last word, predictably")
    func lastNameOrder() {
        let sections = PersonListOrganiser.sections(
            [person("Maya Chen"), person("Alice Brown"), person("Ada Lovelace")],
            by: .lastName,
            locale: english
        )

        #expect(sections.map(\.title) == ["B", "C", "L"])
    }

    /// An organisation stored as a person has no surname and must not acquire one.
    @Test("A one-word name sorts as itself in family-name order")
    func singleWordNames() {
        let sections = PersonListOrganiser.sections(
            [person("Acme"), person("Nguyễn"), person("Maya Chen")],
            by: .lastName,
            locale: english
        )

        #expect(sections.map(\.title) == ["A", "C", "N"])
    }

    @Test("Organisation order collects the unemployed at the end rather than under their initials")
    func organizationOrder() {
        let sections = PersonListOrganiser.sections(
            [
                person("Maya Chen", organization: "Northwind"),
                person("Alice Brown"),
                person("Sam Reed", organization: "Acme"),
            ],
            by: .organization,
            locale: english
        )

        #expect(sections.map(\.title) == ["A", "N", PersonListOrganiser.noOrganizationTitle])
        #expect(sections.last?.entries.map(\.displayName) == ["Alice Brown"])
    }

    @Test("Recent-interaction order uses spans of time, not letters")
    func recentInteractionOrder() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sections = PersonListOrganiser.sections(
            [
                person("Never Spoken"),
                person("Today Person", lastInteraction: now.addingTimeInterval(-60)),
                person("Old Friend", lastInteraction: now.addingTimeInterval(-400 * 86_400)),
            ],
            by: .recentInteraction,
            locale: english,
            now: now
        )

        #expect(sections.map(\.title) == ["Today", "Longer ago", "Never"])
    }

    /// A list headed by everybody you have no history with is the opposite of what this order asked
    /// for.
    @Test("Never having spoken sorts last, not first")
    func neverSpokenSortsLast() {
        let now = Date()
        let ordered = PersonListOrganiser.sorted(
            [person("Never"), person("Recent", lastInteraction: now)],
            by: .recentInteraction
        )

        #expect(ordered.map(\.displayName) == ["Recent", "Never"])
    }

    /// Two people with the same name is normal, and the order between them must not change between
    /// reloads or the list reshuffles itself under the pointer.
    @Test("Duplicate names have a fixed order")
    func duplicatesAreStable() {
        let people = [person("Maya Chen"), person("Maya Chen"), person("Maya Chen")]
        let first = PersonListOrganiser.sorted(people, by: .firstName).map(\.id)

        for _ in 0..<25 {
            #expect(PersonListOrganiser.sorted(people, by: .firstName).map(\.id) == first)
        }
    }

    @Test("A very long name does not break sectioning")
    func longNames() {
        let long = String(repeating: "Wolfeschlegelsteinhausenbergerdorff ", count: 20)
        let sections = PersonListOrganiser.sections([person(long)], by: .firstName, locale: english)

        #expect(sections.map(\.title) == ["W"])
    }

    // MARK: - Typing a name

    @Test("Typing a prefix reaches the first name that starts with it")
    func typeToSelect() {
        let sections = PersonListOrganiser.sections(
            [person("Maya Chen"), person("Nisha Patel"), person("Marcus Webb")],
            by: .firstName,
            locale: english
        )

        #expect(
            PersonListOrganiser.entry(matching: "mar", in: sections, sort: .firstName, locale: english)?
                .displayName == "Marcus Webb"
        )
    }

    @Test("Typing is case- and accent-insensitive")
    func typeToSelectFolds() {
        let sections = PersonListOrganiser.sections(
            [person("Ángela Ruiz"), person("Bob Stone")],
            by: .firstName,
            locale: english
        )

        #expect(
            PersonListOrganiser.entry(matching: "ANG", in: sections, sort: .firstName, locale: english)?
                .displayName == "Ángela Ruiz"
        )
    }

    /// Doing nothing is indistinguishable from the keystrokes having been dropped.
    @Test("Typing something nobody matches lands on the nearest name rather than nowhere")
    func typeToSelectFallsForward() {
        let sections = PersonListOrganiser.sections(
            [person("Alice"), person("Nisha"), person("Zoë")],
            by: .firstName,
            locale: english
        )

        #expect(
            PersonListOrganiser.entry(matching: "m", in: sections, sort: .firstName, locale: english)?
                .displayName == "Nisha"
        )
    }

    @Test("Typing past the end lands on the last name")
    func typeToSelectPastTheEnd() {
        let sections = PersonListOrganiser.sections(
            [person("Alice"), person("Bob")],
            by: .firstName,
            locale: english
        )

        #expect(
            PersonListOrganiser.entry(matching: "zzz", in: sections, sort: .firstName, locale: english)?
                .displayName == "Bob"
        )
    }

    @Test("Typing into an empty list is not a crash")
    func typeToSelectEmpty() {
        #expect(PersonListOrganiser.entry(matching: "a", in: [], sort: .firstName) == nil)
    }

    @Test("Family-name order is typed by family name")
    func typeToSelectFollowsTheSort() {
        let sections = PersonListOrganiser.sections(
            [person("Maya Chen"), person("Alice Brown")],
            by: .lastName,
            locale: english
        )

        #expect(
            PersonListOrganiser.entry(matching: "che", in: sections, sort: .lastName, locale: english)?
                .displayName == "Maya Chen"
        )
    }

    // MARK: - Scrubbing the index

    @Test("A heading that exists is jumped to exactly")
    func exactJump() {
        let sections = PersonListOrganiser.sections(
            [person("Alice"), person("Maya"), person("Zoë")],
            by: .firstName,
            locale: english
        )

        #expect(PersonListOrganiser.section(nearest: "M", in: sections)?.title == "M")
    }

    /// What makes dragging down the strip feel continuous rather than sticky.
    @Test("A heading nobody's name begins with lands on the next one that exists")
    func nearestJump() {
        let sections = PersonListOrganiser.sections(
            [person("Alice"), person("Maya"), person("Zoë")],
            by: .firstName,
            locale: english
        )

        #expect(PersonListOrganiser.section(nearest: "G", in: sections)?.title == "M")
        #expect(PersonListOrganiser.section(nearest: "Z", in: sections)?.title == "Z")
    }

    @Test("Scrubbing past the last heading stays on the last heading")
    func jumpPastTheEnd() {
        let sections = PersonListOrganiser.sections([person("Alice")], by: .firstName, locale: english)
        #expect(PersonListOrganiser.section(nearest: "Z", in: sections)?.title == "A")
    }

    @Test("Scrubbing an empty list is not a crash")
    func jumpInEmptyList() {
        #expect(PersonListOrganiser.section(nearest: "A", in: []) == nil)
    }

    // MARK: - Size

    /// Eight thousand people is a real address book, and this runs on every reload.
    @Test("Sectioning a large address book is not slow")
    func largeAddressBook() {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let people = (0..<8000).map { index -> PersonListEntry in
            let initial = alphabet[alphabet.index(alphabet.startIndex, offsetBy: index % 26)]
            return person("\(initial)name\(index) Surname\(index % 97)")
        }

        let started = Date()
        let sections = PersonListOrganiser.sections(people, by: .lastName, locale: english)
        let elapsed = Date().timeIntervalSince(started)

        #expect(sections.flatMap(\.entries).count == 8000)
        #expect(elapsed < 3.0, "sectioning took \(elapsed)s")
    }
}
