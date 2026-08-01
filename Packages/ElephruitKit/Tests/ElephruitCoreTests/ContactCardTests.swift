import ElephruitCore
import Foundation
import Testing

/// What a person's card and a person's row are allowed to say.
///
/// ### Why these are unit tests and not a look at the screen
/// Both bugs these cover were invisible to review. A row reading "Caroline Howe / Caroline Howe" only
/// appears for records whose company field holds the person's own name, which is a property of the
/// user's address book and not of the sample data. And whether a number labelled "home office" reads
/// as work or as personal is a decision nobody re-derives while looking at a screenshot. Both are
/// pure functions over strings, so both can simply be asserted.
@Suite("Contact card")
struct ContactCardTests {
    // MARK: - What a label means

    @Test("Address-book labels resolve to the side of life they name")
    func standardLabels() {
        #expect(ContactLabelReader.affinity(of: "work") == .work)
        #expect(ContactLabelReader.affinity(of: "Work") == .work)
        #expect(ContactLabelReader.affinity(of: "office") == .work)
        #expect(ContactLabelReader.affinity(of: "home") == .personal)
        #expect(ContactLabelReader.affinity(of: "Home") == .personal)
        #expect(ContactLabelReader.affinity(of: "iCloud") == .personal)
    }

    /// A mobile number is not evidence about whether somebody is a colleague or a friend, and a badge
    /// saying otherwise would be a confident guess on every row in the list.
    @Test("Device and invented labels stay unspecified rather than being guessed at")
    func ambiguousLabels() {
        #expect(ContactLabelReader.affinity(of: "mobile") == .unspecified)
        #expect(ContactLabelReader.affinity(of: "iPhone") == .unspecified)
        #expect(ContactLabelReader.affinity(of: "main") == .unspecified)
        #expect(ContactLabelReader.affinity(of: "Beach house") == .unspecified)
        #expect(ContactLabelReader.affinity(of: "") == .unspecified)
    }

    /// Substring matching would make "homework" a home address and "network" a work one.
    @Test("Matching is on whole words")
    func wordBoundaries() {
        #expect(ContactLabelReader.affinity(of: "homework") == .unspecified)
        #expect(ContactLabelReader.affinity(of: "network") == .unspecified)
        #expect(ContactLabelReader.affinity(of: "work-email") == .work)
    }

    /// "home office" is a work address that happens to be at home. Reading it as personal would file
    /// a colleague's details under the wrong heading, which is the one thing this grouping exists to
    /// get right.
    @Test("A label naming both sides is read as work")
    func workWins() {
        #expect(ContactLabelReader.affinity(of: "home office") == .work)
    }

    @Test("A label the user typed keeps its own capitalisation")
    func displayNames() {
        #expect(ContactLabelReader.displayName(of: "work") == "Work")
        #expect(ContactLabelReader.displayName(of: "Beach house") == "Beach house")
        #expect(ContactLabelReader.displayName(of: "  ") == nil)
    }

    @Test("A detail with no label falls back to naming its kind")
    func unlabelledDetail() {
        let detail = ContactDetail(kind: .email, label: "", value: "a@example.com")
        #expect(detail.displayLabel == "Email")
        #expect(detail.affinity == .unspecified)
    }

    /// The card groups by affinity and heads each group with its name. A row under *Personal* whose
    /// own label is also "personal" was printing the word twice, in two type sizes, six points
    /// apart, about the same value — and a reader looking for what distinguishes three rows from
    /// each other found a column that does not.
    @Test("A row does not repeat the heading it is sitting under")
    func labelDoesNotRepeatItsHeading() {
        let personalEmail = ContactDetail(kind: .email, label: "personal", value: "a@example.com")
        #expect(personalEmail.displayLabel == "Personal")
        #expect(personalEmail.displayLabel(under: .personal) == "Email")

        // Case-folded, because address books are not consistent about it.
        let shouted = ContactDetail(kind: .phone, label: "WORK", value: "555")
        #expect(shouted.displayLabel(under: .work) == "Phone")

        // A label that says something the heading does not is kept exactly as written. This is the
        // whole reason for taking the *label* out rather than the heading.
        let beachHouse = ContactDetail(kind: .address, label: "Beach house", value: "1 Sea Road")
        #expect(beachHouse.displayLabel(under: .unspecified) == "Beach house")

        let mobile = ContactDetail(kind: .phone, label: "iPhone", value: "555")
        #expect(mobile.displayLabel(under: .unspecified) == "iPhone")

        // And a heading it is *not* under leaves it alone: the same personal email listed under
        // Work — which the reader would want to see is odd — still says so.
        #expect(personalEmail.displayLabel(under: .work) == "Personal")
    }

    // MARK: - The identity line

    /// The bug in the screenshot: address books imported from elsewhere routinely put the person's
    /// own name in the company field, and the row then spends its second line repeating its first.
    @Test("A role or company that only repeats the name produces no line at all")
    func identityLineDropsTheName() {
        #expect(
            ContactCard.identityLine(name: "Caroline Howe", organization: "Caroline Howe") == nil
        )
        #expect(
            ContactCard.identityLine(name: "Caroline Howe", role: "caroline howe") == nil
        )
        #expect(ContactCard.identityLine(name: "Caroline Howe") == nil)
    }

    @Test("Role, company, and place read as one line")
    func identityLineComposes() {
        #expect(
            ContactCard.identityLine(
                name: "Maya Chen",
                role: "Head of Design",
                organization: "Northwind",
                location: "Austin"
            ) == "Head of Design · Northwind · Austin"
        )
    }

    @Test("A role and a company that are the same word are said once")
    func identityLineDeduplicates() {
        #expect(
            ContactCard.identityLine(name: "Maya Chen", role: "Fieldstone", organization: "Fieldstone")
                == "Fieldstone"
        )
    }

    @Test("Whitespace-only fields are not a line")
    func identityLineIgnoresBlanks() {
        #expect(ContactCard.identityLine(name: "Maya Chen", role: "  ", organization: "") == nil)
    }

    // MARK: - What a row shows

    private func sampleDetails() -> [ContactDetail] {
        ContactCard.details(
            emails: [(label: "work", value: "maya@northwind.example"), (label: "home", value: "maya@example.com")],
            phones: [(label: "mobile", value: "512-555-0192")],
            addresses: [(label: "home", value: "10 Rivergate, Austin")]
        )
    }

    @Test("Empty values never become details")
    func blanksAreDropped() {
        let details = ContactCard.details(
            emails: [(label: "work", value: "   ")],
            phones: [(label: "mobile", value: "512-555-0192")]
        )
        #expect(details.count == 1)
        #expect(details.first?.kind == .phone)
    }

    /// One of each kind before a second of any kind: an address *and* a number answers "how do I
    /// reach this person"; two email addresses does not.
    @Test("A row shows one of each kind before a second of any")
    func rowPrefersVariety() {
        let row = ContactCard.rowDetails(from: sampleDetails())
        #expect(row.count == 2)
        #expect(row.map(\.kind) == [.email, .phone])
        #expect(row.first?.value == "maya@northwind.example")
    }

    @Test("A row falls back to a second of the same kind when there is nothing else")
    func rowFallsBackWithinAKind() {
        let details = ContactCard.details(
            emails: [(label: "work", value: "a@example.com"), (label: "home", value: "b@example.com")]
        )
        let row = ContactCard.rowDetails(from: details)
        #expect(row.map(\.value) == ["a@example.com", "b@example.com"])
    }

    @Test("A row asked for nothing shows nothing")
    func rowRespectsItsLimit() {
        #expect(ContactCard.rowDetails(from: sampleDetails(), limit: 0).isEmpty)
        #expect(ContactCard.rowDetails(from: [], limit: 2).isEmpty)
        #expect(ContactCard.rowDetails(from: sampleDetails(), limit: 99).count == 4)
    }

    // MARK: - Grouping

    @Test("Details group by side of life, in a stable order, and empty groups do not appear")
    func grouping() {
        let groups = ContactCard.groups(from: sampleDetails())

        #expect(groups.map(\.affinity) == [.personal, .work, .unspecified])

        let personal = groups.first { $0.affinity == .personal }
        #expect(personal?.details.map(\.kind) == [.email, .address])

        let work = groups.first { $0.affinity == .work }
        #expect(work?.details.map(\.value) == ["maya@northwind.example"])
    }

    @Test("Somebody with no details has no groups")
    func groupingNothing() {
        #expect(ContactCard.groups(from: []).isEmpty)
    }

    /// Two people's cards must not collide in a `ForEach`, and one person's card must keep its
    /// identity across a redraw so selection and animation survive.
    @Test("A detail's identity comes from what it is, not from when it was built")
    func stableIdentity() {
        let first = ContactDetail(kind: .phone, label: "work", value: "512-555-0192")
        let second = ContactDetail(kind: .phone, label: "work", value: "512-555-0192")
        let other = ContactDetail(kind: .phone, label: "home", value: "512-555-0192")

        #expect(first.id == second.id)
        #expect(first.id != other.id)
    }

    @Test("Every detail kind maps to the destination its actions accept")
    func kindsBridgeToDestinations() {
        #expect(ContactDetailKind.email.destinationSource == .email)
        #expect(ContactDetailKind.phone.destinationSource == .phone)
        #expect(ContactDetailKind.address.destinationSource == .address)
        #expect(ContactDetailKind.website.destinationSource == .website)
    }
}
