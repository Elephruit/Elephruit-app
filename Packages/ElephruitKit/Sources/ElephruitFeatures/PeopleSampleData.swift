import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation

/// Sample human records used by previews and design-review builds.
///
/// ### Why the awkward cases are the point
/// A design that looks right against three tidy contacts falls apart against a real address book. So
/// this fixture contains, deliberately: a child whose age is an *estimate* derived from a dated
/// remark, a fact that has gone stale, a promise nobody has kept, a birthday with no year, a leap-day
/// birthday, a person with two phone numbers so the call action has to ask, a placeholder record with
/// no details at all, and two profiles for one human being that the identity layer should offer to
/// reconcile. Each of those exercises a state the interface has to have an answer for.
///
/// Reachable only through ``AppServices/loadSampleData()``, which refuses outside development mode.
enum PeopleSampleData {
    @MainActor
    static func populate(services: AppServices) throws(AppError) {
        let people = services.persons
        let items = services.items
        let clock = services.dateProvider
        let today = clock.startOfToday

        // MARK: The centre of the fixture

        let maya = try people.createPerson(
            PersonDraft(
                fullName: "Maya Chen",
                nickname: "Maya",
                pronouns: "she/her",
                pronunciation: "MY-uh",
                roleTitle: "Head of Design",
                organizationName: "Northwind Studio",
                locationText: "Austin",
                timeZoneIdentifier: "America/Chicago",
                emails: [
                    LabelledValue(label: "work", value: "maya@northwind.example"),
                    LabelledValue(label: "home", value: "maya.chen@example.com"),
                ],
                // Two numbers on purpose: the Call action must ask which, rather than picking.
                phones: [
                    LabelledValue(label: "mobile", value: "512-555-0192"),
                    LabelledValue(label: "work", value: "512-555-0100"),
                ],
                addresses: [LabelledValue(label: "home", value: "12 Rosewood Lane, Austin, TX")],
                websites: [LabelledValue(label: "work", value: "northwind.example")]
            )
        )
        try items.update(maya) { $0.isFavorite = true }
        try items.update(maya) { $0.colorName = "indigo" }

        // A birthday coming up, with a year — so the celebrations list can say "turns 39".
        if let birthday = PartialDate(year: 1987, month: 10, day: 12) {
            try people.addCelebration(to: maya, kind: .birthday, title: nil, date: birthday)
        }

        // MARK: Household

        let sam = try people.createPerson(
            PersonDraft(
                fullName: "Sam Okonkwo",
                pronouns: "he/him",
                roleTitle: "Structural engineer",
                locationText: "Austin",
                emails: [LabelledValue(label: "home", value: "sam@example.com")]
            )
        )
        try people.relate(maya, to: sam, as: .partner, label: "husband")

        // A child, created as a lightweight record — no contact details, and none needed.
        let jack = try people.resolveOrCreatePlaceholder(named: "Jack Chen")
        try people.relate(maya, to: jack, as: .child, label: "son")

        // A pet, which is a person record for the reason given on `RelationshipKind.pet`: "Pepper is
        // terrified of thunderstorms" is a fact that needs a subject.
        let pepper = try people.resolveOrCreatePlaceholder(named: "Pepper")
        try people.relate(maya, to: pepper, as: .pet, label: "dog")

        // MARK: The conversation everything is derived from

        let coffee = try items.create(
            ItemDraft(
                kind: .interaction,
                title: "Coffee with Maya",
                body: """
                    Jack is six and starts second grade next month. Pepper is terrified of \
                    thunderstorms, and Maya wants a recommendation for a dog trainer. She has moved \
                    to Austin and is enjoying it more than she expected.
                    """,
                startAt: clock.calendar.date(byAdding: .day, value: -900, to: today)
            )
        )
        try items.update(coffee) { $0.sourceIdentifier = InteractionProvenance.logged.rawValue }
        try items.link(coffee, to: maya, kind: .mentions)

        // Far enough back that a school-year boundary has been crossed, so the fixture shows a
        // *labelled* grade estimate rather than only the unhedged case. Two and a half years also
        // widens the age to a two-year range, which is what an honest estimate looks like.
        let observedOn = clock.calendar.date(byAdding: .day, value: -900, to: today) ?? today

        // The worked example: an age and a grade, both anchored to the date they were said. Eighteen
        // months on, the page reads "approximately 7–8 years old · likely in 3rd grade" and says
        // where that came from.
        try people.record(
            ObservationDraft(attribute: .observedAge, value: "6"),
            about: jack, observedOn: observedOn, confidence: .stated, sensitivity: .normal, source: coffee
        )
        try people.record(
            ObservationDraft(attribute: .schoolGrade, value: "2nd grade", effective: .today),
            about: jack, observedOn: observedOn, confidence: .stated, sensitivity: .normal, source: coffee
        )
        try people.record(
            ObservationDraft(attribute: .dislike, value: "thunderstorms"),
            about: pepper, observedOn: observedOn, confidence: .stated, sensitivity: .normal, source: coffee
        )
        try people.record(
            ObservationDraft(attribute: .lookingFor, value: "a dog trainer"),
            about: maya, observedOn: observedOn, confidence: .stated, sensitivity: .normal, source: coffee
        )

        // MARK: What is true about Maya

        try people.record(
            ObservationDraft(attribute: .significance, value: "The person who taught me how to run a design review."),
            about: maya, observedOn: today, confidence: .stated, sensitivity: .normal, source: nil
        )
        try people.record(
            ObservationDraft(attribute: .location, value: "Austin"),
            about: maya, observedOn: observedOn, confidence: .stated, sensitivity: .normal, source: coffee
        )
        try people.record(
            ObservationDraft(attribute: .like, value: "natural wine"),
            about: maya, observedOn: clock.calendar.date(byAdding: .day, value: -200, to: today) ?? today,
            confidence: .stated, sensitivity: .normal, source: nil
        )
        try people.record(
            ObservationDraft(attribute: .like, value: "small restaurants, never anywhere loud"),
            about: maya, observedOn: clock.calendar.date(byAdding: .day, value: -60, to: today) ?? today,
            confidence: .stated, sensitivity: .normal, source: nil
        )
        try people.record(
            ObservationDraft(attribute: .dislike, value: "surprise phone calls — send a message first"),
            about: maya, observedOn: clock.calendar.date(byAdding: .day, value: -90, to: today) ?? today,
            confidence: .stated, sensitivity: .normal, source: nil
        )
        try people.record(
            ObservationDraft(attribute: .giftIdea, value: "the Fermentation book she mentioned"),
            about: maya, observedOn: clock.calendar.date(byAdding: .day, value: -30, to: today) ?? today,
            confidence: .stated, sensitivity: .normal, source: nil
        )
        try people.record(
            ObservationDraft(attribute: .communicationPreference, value: "Messages, not email. Replies in the evening."),
            about: maya, observedOn: today, confidence: .stated, sensitivity: .normal, source: nil
        )

        // A private reflection: shown behind a lock, never exported, never in a brief, and not
        // reachable from the search field.
        try people.record(
            ObservationDraft(attribute: .reflection, value: "I think she is quietly unhappy at Northwind."),
            about: maya, observedOn: today, confidence: .stated, sensitivity: .restricted, source: nil
        )

        // A stale fact — recorded years ago and never confirmed since, so the app stops vouching
        // for it and offers to check.
        try people.record(
            ObservationDraft(attribute: .employer, value: "Northwind Studio"),
            about: maya,
            observedOn: clock.calendar.date(byAdding: .day, value: -900, to: today) ?? today,
            confidence: .stated, sensitivity: .normal, source: nil
        )

        // MARK: A promise nobody has kept

        let promise = try items.create(
            ItemDraft(
                kind: .task,
                title: "Send Maya the dog trainer's number",
                tagSlugs: [TagConventions.owed],
                dueAt: clock.calendar.date(byAdding: .day, value: -14, to: today)
            )
        )
        try items.link(promise, to: maya, kind: .mentions)

        // MARK: A colleague, met through somebody

        let nisha = try people.createPerson(
            PersonDraft(
                fullName: "Nisha Raman",
                roleTitle: "Principal engineer",
                organizationName: "Northwind Studio",
                emails: [LabelledValue(label: "work", value: "nisha@northwind.example")]
            )
        )
        try people.relate(maya, to: nisha, as: .colleague, label: nil)

        let danielle = try people.createPerson(
            PersonDraft(
                fullName: "Danielle Okafor",
                roleTitle: "Dog trainer",
                locationText: "Austin",
                phones: [LabelledValue(label: "mobile", value: "512-555-0177")]
            )
        )
        // "People I met through Nisha" has an answer.
        try people.relate(danielle, to: nisha, as: .introducedBy, label: nil)

        // MARK: A professional organisation chart

        let rosa = try people.createPerson(
            PersonDraft(
                fullName: "Rosa Iyer",
                roleTitle: "Managing director",
                organizationName: "Northwind Studio",
                emails: [LabelledValue(label: "work", value: "rosa@northwind.example")]
            )
        )
        try people.relate(maya, to: rosa, as: .manager, label: nil)

        for (name, role) in [("Theo Brandt", "Product designer"), ("Ines Duarte", "Design engineer")] {
            let report = try people.createPerson(
                PersonDraft(
                    fullName: name,
                    roleTitle: role,
                    organizationName: "Northwind Studio",
                    emails: [
                        LabelledValue(
                            label: "work",
                            value: "\(name.split(separator: " ").first?.lowercased() ?? "x")@northwind.example"
                        )
                    ]
                )
            )
            try people.relate(maya, to: report, as: .directReport, label: nil)
            try people.relate(report, to: nisha, as: .colleague, label: nil)
        }

        // MARK: Interactions over time, so the timeline has shape

        let interactions: [(days: Int, title: String, kind: ItemKind, provenance: InteractionProvenance)] = [
            (-420, "Called about the Austin move", .interaction, .logged),
            (-300, "Lunch — she brought Jack", .interaction, .logged),
            (-180, "Design review", .meeting, .detected),
            (-95, "Messaged about the trainer", .interaction, .initiated),
            (-21, "Walk around Lady Bird Lake", .interaction, .logged),
            (7, "Quarterly catch-up", .meeting, .detected),
        ]

        for entry in interactions {
            let date = clock.calendar.date(byAdding: .day, value: entry.days, to: today)
            let item = try items.create(
                ItemDraft(kind: entry.kind, title: entry.title, startAt: date)
            )
            try items.update(item) { $0.sourceIdentifier = entry.provenance.rawValue }
            try items.link(item, to: maya, kind: entry.kind == .meeting ? .participant : .mentions)
        }

        // A note that lives elsewhere and appears here only because it is linked.
        let note = try items.create(
            ItemDraft(
                kind: .note,
                title: "Studio pricing conversation",
                body: "Maya thinks the new tiers will confuse the smaller clients. Worth revisiting.",
                tagSlugs: ["work"]
            )
        )
        try items.link(note, to: maya, kind: .mentions)

        // MARK: Celebrations that exercise the awkward cases

        // No year — the ordinary case, and the app must not invent one.
        if let birthday = PartialDate(month: 3, day: 4) {
            try people.addCelebration(to: jack, kind: .birthday, title: nil, date: birthday)
        }
        // A leap day, which genuinely does not occur most years.
        if let birthday = PartialDate(year: 1996, month: 2, day: 29) {
            try people.addCelebration(to: nisha, kind: .birthday, title: nil, date: birthday)
        }
        if let anniversary = PartialDate(year: 2014, month: 6, day: 21) {
            try people.addCelebration(to: maya, kind: .anniversary, title: "Married", date: anniversary)
        }
        if let adopted = PartialDate(year: 2021, month: 9, day: 2) {
            try people.addCelebration(to: pepper, kind: .milestone, title: "Adopted", date: adopted)
        }

        // One falling *today*, and one tomorrow.
        //
        // Fixed dates would put every celebration months away for most of the year, and a briefing
        // that can never demonstrate the case it exists for is a briefing nobody has looked at. So
        // these two are derived from the clock: Today can always show what it does with a birthday
        // that is happening, and with one close enough to still act on.
        let todayParts = clock.calendar.dateComponents([.month, .day], from: today)
        if let month = todayParts.month, let day = todayParts.day,
           let birthday = PartialDate(year: 1991, month: month, day: day) {
            try people.addCelebration(to: rosa, kind: .birthday, title: nil, date: birthday)
        }

        let tomorrow = clock.startOfTomorrow
        let tomorrowParts = clock.calendar.dateComponents([.month, .day], from: tomorrow)
        if let month = tomorrowParts.month, let day = tomorrowParts.day,
           let birthday = PartialDate(month: month, day: day) {
            try people.addCelebration(to: danielle, kind: .birthday, title: nil, date: birthday)
        }

        // MARK: A duplicate to reconcile

        // The same human being, arriving a second time from a different account with a different
        // spelling. The identity layer should offer to fold them together — and nothing should
        // happen until somebody agrees.
        try people.createPerson(
            PersonDraft(
                fullName: "M. Chen",
                organizationName: "Northwind",
                emails: [LabelledValue(label: "work", value: "maya@northwind.example")],
                contactsIdentifier: "sample-contact-maya",
                contactsAccountName: "Google"
            )
        )
        try people.updateProfile(of: maya) { profile in
            profile.contactsIdentifier = "sample-contact-maya"
            profile.contactsAccountName = "iCloud"
        }

        // MARK: The user's own card

        let me = try people.createPerson(
            PersonDraft(
                fullName: "Alex Rivera",
                pronouns: "they/them",
                roleTitle: "Product designer",
                organizationName: "Northwind Studio",
                emails: [
                    LabelledValue(label: "work", value: "alex@northwind.example"),
                    LabelledValue(label: "home", value: "alex@example.com"),
                ],
                phones: [LabelledValue(label: "mobile", value: "512-555-0134")],
                addresses: [LabelledValue(label: "home", value: "8 Chestnut Court, Austin, TX")],
                websites: [LabelledValue(label: "work", value: "alexrivera.example")]
            )
        )
        try people.setMyCard(me)

        // MARK: Groups, one of each kind

        let family = try services.personGroups.createFixedGroup(named: "Family", symbolName: "figure.2.and.child.holdinghands")
        for member in [maya, sam, jack, pepper] {
            try services.personGroups.add(member, to: family.id)
        }

        let designTeam = try services.personGroups.createFixedGroup(named: "Design Team", symbolName: "square.grid.2x2")
        for member in [maya, nisha, rosa] {
            try services.personGroups.add(member, to: designTeam.id)
        }

        // Smart: nobody is added, and the membership is whatever the query currently matches.
        try services.personGroups.createSmartGroup(named: "In Austin", query: "people in Austin")
        try services.personGroups.createSmartGroup(named: "Out of touch", query: "haven't contacted in six months")

        Diagnostics.features.info("Loaded People sample data")
    }
}
