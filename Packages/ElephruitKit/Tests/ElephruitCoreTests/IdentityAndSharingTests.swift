import ElephruitCore
import Foundation
import Testing

/// Deciding whether two records are the same person.
///
/// Both directions matter, and they are not symmetric in cost. Three profiles for one person is
/// untidy; two people merged into one destroys the boundary between two sets of private notes and
/// cannot be undone by hand. So the suite tests what gets offered *and* what deliberately does not.
@Suite("Identity resolution")
struct IdentityResolutionTests {
    static func candidate(
        name: String,
        emails: [String] = [],
        phones: [String] = [],
        contactsIdentifier: String? = nil,
        organization: String? = nil,
        birthday: PartialDate? = nil
    ) -> IdentityCandidate {
        IdentityCandidate(
            id: UUID(),
            fullName: name,
            emails: emails,
            phones: phones,
            contactsIdentifier: contactsIdentifier,
            organization: organization,
            birthday: birthday
        )
    }

    @Test("The same Contacts record is the same person, with no judgement required")
    func sharedContactsIdentifierIsCertain() {
        let match = IdentityMatcher.match(
            Self.candidate(name: "Maya Chen", contactsIdentifier: "ABC-123"),
            Self.candidate(name: "M. Chen", contactsIdentifier: "ABC-123")
        )

        #expect(match.isCertain)
        #expect(match.evidence.contains(.sameContactsRecord))
    }

    @Test("A shared email is offered, never assumed")
    func sharedEmailIsOfferedNotCertain() {
        let match = IdentityMatcher.match(
            Self.candidate(name: "Maya Chen", emails: ["maya@example.com"]),
            Self.candidate(name: "Maya C", emails: ["MAYA@example.com"])
        )

        #expect(match.isWorthOffering)
        #expect(!match.isCertain, "a shared address can belong to a couple, a family, or a support alias")
    }

    @Test("Phone numbers written differently still match")
    func phoneNormalizationFindsTheSameNumber() {
        let match = IdentityMatcher.match(
            Self.candidate(name: "Maya Chen", phones: ["+1 (512) 555-0192"]),
            Self.candidate(name: "Maya Chen", phones: ["512-555-0192"])
        )

        #expect(match.evidence.contains(.sharedPhone))
        #expect(match.isWorthOffering)
    }

    @Test("Two people with the same name are not merged on that alone")
    func identicalNamesAreNotEnough() {
        let match = IdentityMatcher.match(
            Self.candidate(name: "John Smith"),
            Self.candidate(name: "John Smith")
        )

        #expect(match.evidence == [.identicalName])
        #expect(!match.isWorthOffering, "a common name is the weakest evidence there is")
    }

    @Test("Two unrelated people match on nothing")
    func strangersDoNotMatch() {
        let match = IdentityMatcher.match(
            Self.candidate(name: "Maya Chen", emails: ["maya@example.com"]),
            Self.candidate(name: "Theo Brandt", emails: ["theo@example.com"])
        )

        #expect(match.score == 0)
        #expect(match.evidence.isEmpty)
        #expect(!match.isWorthOffering)
    }

    @Test("A surname and a first initial is a hint, not a verdict")
    func initialMatchIsWeak() {
        let match = IdentityMatcher.match(
            Self.candidate(name: "Maya Chen"),
            Self.candidate(name: "Marcus Chen")
        )

        #expect(match.evidence.contains(.nameAndInitial))
        #expect(!match.isWorthOffering, "same surname, same initial, different people")
    }

    @Test("Name plus birthday together are worth offering")
    func nameAndBirthdayCombine() {
        let birthday = PartialDate(month: 10, day: 12)
        let match = IdentityMatcher.match(
            Self.candidate(name: "Maya Chen", birthday: birthday),
            Self.candidate(name: "Maya Chen", birthday: birthday)
        )

        #expect(match.isWorthOffering, "two weak signals agreeing is stronger than either")
        #expect(match.evidence.contains(.sameBirthday))
    }

    @Test("Duplicates come back strongest first, each pair considered once")
    func duplicateSweepIsOrderedAndDeduplicated() {
        let certain = Self.candidate(name: "Maya Chen", emails: ["maya@example.com"], contactsIdentifier: "A")
        let alsoCertain = Self.candidate(name: "Maya Chen", emails: ["maya@example.com"], contactsIdentifier: "A")
        let sameNameOnly = Self.candidate(name: "Maya Chen", phones: ["512-555-0192"])
        let stranger = Self.candidate(name: "Theo Brandt")

        let duplicates = IdentityMatcher.duplicates(among: [certain, alsoCertain, sameNameOnly, stranger])

        // Three Mayas make three pairs, but only the two sharing a Contacts record and an email
        // clear the threshold — a shared name alone never does.
        #expect(duplicates.count == 1)
        #expect(duplicates.first?.isCertain == true)

        let pair = Set([duplicates.first?.leftID, duplicates.first?.rightID].compactMap { $0 })
        #expect(pair == Set([certain.id, alsoCertain.id]))
        #expect(!pair.contains(sameNameOnly.id))
    }

    @Test("The strongest match is ordered first")
    func duplicatesAreOrderedByStrength() {
        let anchor = Self.candidate(name: "Maya Chen", emails: ["maya@example.com"], phones: ["512-555-0192"])
        let strong = Self.candidate(name: "Maya Chen", emails: ["maya@example.com"], phones: ["512-555-0192"])
        let weaker = Self.candidate(name: "Someone Else", emails: ["maya@example.com"])

        let duplicates = IdentityMatcher.duplicates(among: [anchor, strong, weaker])

        #expect(duplicates.count >= 2)
        #expect(duplicates[0].score >= duplicates[1].score)
    }

    @Test("An explanation is words, never a number")
    func matchesExplainThemselves() {
        let match = IdentityMatcher.match(
            Self.candidate(name: "Maya Chen", emails: ["maya@example.com"]),
            Self.candidate(name: "Maya Chen", emails: ["maya@example.com"])
        )

        #expect(match.explanation.contains("Same email address"))
        #expect(match.explanation.contains("Same name"))
        #expect(!match.explanation.contains("\(match.score)"))
    }

    // MARK: - Merging

    @Test("A merge says everything it will do before it does it")
    func mergePlanDescribesItself() {
        let plan = MergePlan(
            primaryID: UUID(),
            secondaryID: UUID(),
            primaryName: "Maya Chen",
            secondaryName: "M. Chen",
            addedEmails: ["maya.chen@northwind.example"],
            conflicts: [MergeConflict(field: "Role", primaryValue: "Head of Design", secondaryValue: "Design Lead")],
            movedObservations: 3,
            movedLinks: 7
        )

        #expect(plan.summary.contains("folded into"))
        #expect(plan.summary.contains("3 recorded facts"))
        #expect(plan.summary.contains("7 linked notes"))
        #expect(plan.summary.contains("nothing is overwritten"))
        #expect(!plan.isEmpty)
    }

    @Test("A merge that would change nothing says so")
    func emptyMergePlan() {
        let plan = MergePlan(
            primaryID: UUID(), secondaryID: UUID(),
            primaryName: "Maya Chen", secondaryName: "Maya Chen"
        )
        #expect(plan.isEmpty)
    }
}

// MARK: - Celebrations

/// Birthdays, anniversaries, and the dates that misbehave.
@Suite("Celebrations")
struct CelebrationTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    @Test("A birthday with no year is a normal birthday")
    func birthdayWithoutAYear() {
        let birthday = PartialDate(month: 10, day: 12)
        #expect(birthday?.hasYear == false)
        #expect(birthday?.displayText.contains("October") == true)
        #expect(birthday?.displayText.contains("2000") == false, "a placeholder year must never be shown")
    }

    @Test("A birthday with a year gives an age")
    func birthdayWithAYearCounts() {
        guard let birthday = PartialDate(year: 1987, month: 10, day: 12) else {
            Issue.record("could not build the date")
            return
        }

        let celebration = Celebration(
            personID: UUID(), personName: "Maya Chen", kind: .birthday, date: birthday
        )
        let placed = CelebrationCalendar.place(celebration, asOf: Self.date(2026, 9, 30), calendar: Self.calendar)

        #expect(placed?.milestoneYears == 39)
        #expect(placed?.daysAway == 12)
        #expect(placed?.summary.contains("turns 39") == true)
    }

    @Test("Without a year there is no age to claim")
    func noYearMeansNoMilestone() {
        guard let birthday = PartialDate(month: 10, day: 12) else {
            Issue.record("could not build the date")
            return
        }

        let placed = CelebrationCalendar.place(
            Celebration(personID: UUID(), personName: "Maya Chen", kind: .birthday, date: birthday),
            asOf: Self.date(2026, 9, 30),
            calendar: Self.calendar
        )

        #expect(placed?.milestoneYears == nil)
        #expect(placed?.summary.contains("turns") == false)
    }

    @Test("A leap-day birthday is marked on the 28th and says so")
    func leapDayIsShiftedAndLabelled() {
        guard let birthday = PartialDate(month: 2, day: 29) else {
            Issue.record("could not build the date")
            return
        }

        let placed = CelebrationCalendar.place(
            Celebration(personID: UUID(), personName: "Theo Brandt", kind: .birthday, date: birthday),
            // 2027 is not a leap year.
            asOf: Self.date(2027, 1, 1),
            calendar: Self.calendar
        )

        #expect(placed != nil, "a leap-day birthday must not disappear for three years in four")
        #expect(placed?.isShiftedFromLeapDay == true)
        #expect(Self.calendar.component(.day, from: placed?.occursOn ?? Date()) == 28)
    }

    @Test("In a leap year it falls where it belongs")
    func leapDayIsNotShiftedInALeapYear() {
        guard let birthday = PartialDate(month: 2, day: 29) else {
            Issue.record("could not build the date")
            return
        }

        let placed = CelebrationCalendar.place(
            Celebration(personID: UUID(), personName: "Theo Brandt", kind: .birthday, date: birthday),
            asOf: Self.date(2028, 1, 1),
            calendar: Self.calendar
        )

        #expect(placed?.isShiftedFromLeapDay == false)
        #expect(Self.calendar.component(.day, from: placed?.occursOn ?? Date()) == 29)
    }

    @Test("A memorial is never treated as a celebration")
    func memorialsAreQuiet() {
        #expect(!CelebrationKind.memorial.isCelebratory)
        #expect(CelebrationKind.memorial.milestonePhrase(years: 3) == "3 years ago")
        #expect(CelebrationKind.birthday.isCelebratory)
    }

    @Test("Upcoming celebrations come back soonest first, inside the window")
    func upcomingIsOrderedAndBounded() {
        guard let soon = PartialDate(month: 10, day: 5),
              let later = PartialDate(month: 10, day: 20),
              let farOff = PartialDate(month: 6, day: 1)
        else {
            Issue.record("could not build the dates")
            return
        }

        let celebrations = [
            Celebration(personID: UUID(), personName: "Later", kind: .birthday, date: later),
            Celebration(personID: UUID(), personName: "Soon", kind: .birthday, date: soon),
            Celebration(personID: UUID(), personName: "Far off", kind: .birthday, date: farOff),
        ]

        let upcoming = CelebrationCalendar.upcoming(
            from: celebrations, within: 30, asOf: Self.date(2026, 10, 1), calendar: Self.calendar
        )

        #expect(upcoming.map(\.celebration.personName) == ["Soon", "Later"])
        #expect(upcoming.first?.isImminent == true)
    }

    @Test("Dates are read the several ways people write them")
    func partialDateParsing() {
        #expect(PartialDate.parse("October 12")?.month == 10)
        #expect(PartialDate.parse("12 October")?.day == 12)
        #expect(PartialDate.parse("Oct 12")?.month == 10)
        #expect(PartialDate.parse("October 12 1987")?.year == 1987)
        #expect(PartialDate.parse("1987-10-12")?.year == 1987)
    }

    @Test("An ambiguous numeric pair is refused rather than guessed")
    func ambiguousNumericDatesAreRejected() {
        #expect(PartialDate.parse("3/4") == nil, "March the fourth to half the world, April the third to the rest")
        #expect(PartialDate.parse("") == nil)
        #expect(PartialDate.parse("sometime") == nil)
    }
}

// MARK: - Contact actions

@Suite("Contact actions")
struct ContactActionTests {
    @Test("Each channel builds the URL the system expects")
    func urlsAreWellFormed() {
        #expect(ContactActionURL.url(for: .call, destination: "512-555-0192")?.absoluteString == "tel:5125550192")
        #expect(ContactActionURL.url(for: .message, destination: "512-555-0192")?.absoluteString == "sms:5125550192")
        #expect(
            ContactActionURL.url(for: .email, destination: "maya@example.com")?.absoluteString
                == "mailto:maya@example.com"
        )
        #expect(
            ContactActionURL.url(for: .facetimeVideo, destination: "512-555-0192")?.absoluteString
                == "facetime:5125550192"
        )
    }

    @Test("Something that is not a destination builds no URL at all")
    func rubbishBuildsNothing() {
        #expect(ContactActionURL.url(for: .call, destination: "") == nil)
        #expect(ContactActionURL.url(for: .call, destination: "not a number") == nil)
        #expect(ContactActionURL.url(for: .web, destination: "not a website") == nil)
    }

    /// The privacy failure this exists to prevent: a group email that shows everyone's address to
    /// everyone else.
    @Test("A group email hides the recipients from each other")
    func groupEmailUsesBlindCopy() {
        let url = ContactActionURL.mailtoURL(
            recipients: ["maya@example.com", "theo@example.com"],
            useBlindCopy: true
        )

        let text = url?.absoluteString ?? ""
        #expect(text.contains("bcc="))
        #expect(text.hasPrefix("mailto:?"), "nobody is in the To field")
    }

    @Test("A single recipient does not need hiding from themselves")
    func singleRecipientIsAddressedDirectly() {
        let url = ContactActionURL.mailtoURL(recipients: ["maya@example.com"])
        #expect(url?.absoluteString == "mailto:maya@example.com")
    }

    @Test("One number is used without asking; two are not")
    func destinationPolicyAsksWhenItShould() {
        let mobile = ContactDestination(label: "mobile", value: "512-555-0192", source: .phone)
        let work = ContactDestination(label: "work", value: "512-555-0100", source: .phone)

        #expect(ContactDestinationPolicy.automatic(for: .call, from: [mobile]) != nil)
        #expect(
            ContactDestinationPolicy.automatic(for: .call, from: [mobile, work]) == nil,
            "the app does not get to decide which of somebody's phones to ring"
        )
    }

    @Test("A preferred number breaks the tie")
    func preferredDestinationWins() {
        let mobile = ContactDestination(label: "mobile", value: "512-555-0192", source: .phone, isPreferred: true)
        let work = ContactDestination(label: "work", value: "512-555-0100", source: .phone)

        #expect(ContactDestinationPolicy.automatic(for: .call, from: [mobile, work])?.label == "mobile")
    }

    @Test("A channel only offers destinations it can use")
    func channelsFilterDestinations() {
        let destinations = [
            ContactDestination(label: "mobile", value: "512-555-0192", source: .phone),
            ContactDestination(label: "work", value: "maya@example.com", source: .email),
        ]

        #expect(ContactDestinationPolicy.candidates(for: .call, from: destinations).count == 1)
        #expect(ContactDestinationPolicy.candidates(for: .email, from: destinations).count == 1)
        #expect(
            ContactDestinationPolicy.candidates(for: .facetimeVideo, from: destinations).count == 2,
            "FaceTime reaches a number or an Apple ID"
        )
    }

    /// Pressing Call is not the same as having spoken, and the timeline must not claim otherwise.
    @Test("Only a logged interaction counts as contact")
    func onlyLoggedInteractionsCount() {
        #expect(InteractionProvenance.logged.countsAsContact)
        #expect(!InteractionProvenance.initiated.countsAsContact)
        #expect(!InteractionProvenance.detected.countsAsContact)
    }
}

// MARK: - Sharing

@Suite("Share profiles")
struct ShareProfileTests {
    static let fullCard: ShareableCard = {
        var card = ShareableCard()
        card[.fullName] = "Alex Rivera"
        card[.pronouns] = "they/them"
        card[.jobTitle] = "Product Designer"
        card[.organization] = "Northwind"
        card[.workEmail] = "alex@northwind.example"
        card[.personalEmail] = "alex@example.com"
        card[.mobilePhone] = "512-555-0134"
        card[.postalAddress] = "12 Rosewood Lane, Austin"
        card[.birthday] = "1990-04-11"
        return card
    }()

    @Test("A professional card carries work details and nothing personal")
    func professionalProfileExcludesPrivateFields() {
        guard let profile = ShareProfile.defaults().first(where: { $0.name == "Professional" }) else {
            Issue.record("no professional profile")
            return
        }

        let vcard = VCardEmitter.emit(card: Self.fullCard, profile: profile)

        #expect(vcard.contains("alex@northwind.example"))
        #expect(!vcard.contains("alex@example.com"), "the personal address was not selected")
        #expect(!vcard.contains("Rosewood"), "nor was the home address")
        #expect(!vcard.contains("1990-04-11"))
    }

    @Test("A minimal card is genuinely minimal")
    func minimalProfileIsSmall() {
        guard let profile = ShareProfile.defaults().first(where: { $0.name == "Minimal" }) else {
            Issue.record("no minimal profile")
            return
        }

        let vcard = VCardEmitter.emit(card: Self.fullCard, profile: profile)

        #expect(vcard.contains("Alex Rivera"))
        #expect(vcard.contains("alex@example.com"))
        #expect(!vcard.contains("512-555-0134"))
        #expect(!vcard.contains("Northwind"))
    }

    /// The guarantee the emitter's shape is built around, asserted rather than assumed.
    @Test("No app-only data can reach a vCard")
    func appOnlyDataIsStructurallyExcluded() {
        let everything = ShareProfile(name: "Everything", fields: Set(ShareableField.allCases))
        let vcard = VCardEmitter.emit(card: Self.fullCard, profile: everything)

        for forbidden in ["observation", "confidence", "reflection", "timeline", "estimated", "provenance"] {
            #expect(!vcard.lowercased().contains(forbidden), "“\(forbidden)” must never be exportable")
        }
    }

    @Test("Pronouns survive, in the only field a vCard has for them")
    func pronounsGoInTheNote() {
        guard let profile = ShareProfile.defaults().first(where: { $0.name == "Professional" }) else {
            Issue.record("no professional profile")
            return
        }

        let vcard = VCardEmitter.emit(card: Self.fullCard, profile: profile)
        #expect(vcard.contains("Pronouns: they/them"))
    }

    @Test("A vCard is well formed")
    func vcardStructure() {
        let vcard = VCardEmitter.emit(card: Self.fullCard, profile: ShareProfile(name: "Test", fields: [.fullName]))

        #expect(vcard.hasPrefix("BEGIN:VCARD\r\nVERSION:3.0"))
        #expect(vcard.hasSuffix("END:VCARD\r\n"))
        #expect(vcard.contains("\r\n"), "vCard requires CRLF; bare newlines fail silently")
    }

    @Test("Characters with meaning in a vCard are escaped")
    func escaping() {
        var card = ShareableCard()
        card[.fullName] = "Smith; Jones, Ltd"
        let vcard = VCardEmitter.emit(card: card, profile: ShareProfile(name: "Test", fields: [.fullName]))

        #expect(vcard.contains("Smith\\; Jones\\, Ltd"))
    }

    @Test("A profile says when it would disclose something sensitive")
    func sensitiveFieldsAreNamed() {
        let profile = ShareProfile(name: "Everything", fields: [.fullName, .postalAddress, .mobilePhone])

        #expect(profile.includesSensitiveFields)
        #expect(profile.sensitiveFieldNames.contains("Address"))
        #expect(profile.sensitiveFieldNames.contains("Mobile"))
    }

    @Test("And when it would not")
    func harmlessProfileSaysNothing() {
        let profile = ShareProfile(name: "Work", fields: [.fullName, .workEmail, .organization])
        #expect(!profile.includesSensitiveFields)
    }
}

// MARK: - People search

@Suite("People search")
struct PersonSearchTests {
    @Test("people in Austin")
    func locationSearch() {
        let query = PersonQueryParser.parse("people in Austin")
        #expect(query.attributeFilters.contains { $0.attribute == .location && $0.value == "austin" })
    }

    @Test("works at Acme")
    func employerSearch() {
        let query = PersonQueryParser.parse("works at Acme")
        #expect(query.attributeFilters.contains { $0.attribute == .employer && $0.value == "acme" })
    }

    @Test("likes natural wine")
    func preferenceSearch() {
        let query = PersonQueryParser.parse("likes natural wine")
        #expect(query.attributeFilters.contains { $0.attribute == .like && $0.value == "natural wine" })
    }

    @Test("Maya's son")
    func relationSearch() {
        let query = PersonQueryParser.parse("Maya's son")
        #expect(query.relatedTo?.personName == "maya")
        #expect(query.relatedTo?.kind == .child)
        #expect(query.relatedTo?.label == "son")
    }

    @Test("people I met through Nisha")
    func introductionSearch() {
        let query = PersonQueryParser.parse("people I met through Nisha")
        #expect(query.introducedBy == "nisha")
    }

    @Test("birthdays next month")
    func celebrationSearch() {
        let query = PersonQueryParser.parse("birthdays next month")
        #expect(query.celebrationWindowMonths == 2)
    }

    @Test("haven't contacted in six months")
    func staleContactSearch() {
        let query = PersonQueryParser.parse("haven't contacted in six months")
        #expect(query.notContactedForDays == 180)
    }

    @Test("open promises")
    func promiseSearch() {
        #expect(PersonQueryParser.parse("open promises").hasOpenPromises)
    }

    @Test("dog trainer falls through to free text")
    func freeTextSearch() {
        let query = PersonQueryParser.parse("dog trainer")
        #expect(query.freeText == "dog trainer")
        #expect(!query.isStructural, "not everything is a filter, and pretending otherwise loses results")
    }

    @Test("Every documented example parses to something")
    func everyExampleIsUnderstood() {
        for example in PersonQueryParser.examples {
            let query = PersonQueryParser.parse(example)
            #expect(!query.isEmpty, "“\(example)” is offered in the empty state and must do something")
        }
    }

    @Test("Results are ordered by how well they matched, then by recency")
    func rankingPrefersStrongMatchesThenRecency() {
        let strong = RankedPerson(
            id: UUID(), name: "Weak name match",
            reasons: [PersonMatchReason(text: "name", strength: .exactName)],
            daysSinceContact: 400
        )
        let recent = RankedPerson(
            id: UUID(), name: "Recent but weaker",
            reasons: [PersonMatchReason(text: "fact", strength: .factValue)],
            daysSinceContact: 2
        )

        #expect(PersonRanker.rank([recent, strong]).first?.id == strong.id)
    }

    @Test("Somebody never spoken to sorts after somebody spoken to years ago")
    func neverContactedSortsLast() {
        let reasons = [PersonMatchReason(text: "fact", strength: .factValue)]
        let longAgo = RankedPerson(id: UUID(), name: "Long ago", reasons: reasons, daysSinceContact: 2000)
        let never = RankedPerson(id: UUID(), name: "Never", reasons: reasons, daysSinceContact: nil)

        #expect(PersonRanker.rank([never, longAgo]).first?.id == longAgo.id)
    }
}
