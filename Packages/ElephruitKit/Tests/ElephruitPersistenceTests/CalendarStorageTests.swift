import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

@Suite("Calendar sets in the store")
@MainActor
struct CalendarSetStorageTests {
    private func makeService(_ fixture: StoreFixture) -> (CalendarSetService, UserDefaults) {
        let defaults = UserDefaults(suiteName: "calendar-sets-\(UUID().uuidString)") ?? .standard
        let service = CalendarSetService(
            context: fixture.context,
            dateProvider: FixedDateProvider.reference,
            defaults: defaults
        )
        return (service, defaults)
    }

    @Test("A set survives being stored and read back whole")
    func setsRoundTrip() throws {
        let fixture = try StoreFixture()
        let (service, _) = makeService(fixture)

        let original = CalendarSetDefinition(
            name: "Work",
            symbolName: "briefcase",
            colorName: "indigo",
            calendars: [
                CalendarReference(identifier: "a", title: "Work", accountName: "Acme"),
                CalendarReference(identifier: "b", title: "Team", accountName: "Acme"),
            ],
            showsEveryCalendar: false,
            defaultCalendar: CalendarReference(identifier: "a", title: "Work", accountName: "Acme"),
            preferredView: .day,
            displayTimeZoneIdentifier: "Europe/London",
            workingHours: WorkingHours(startMinutes: 8 * 60, endMinutes: 18 * 60, weekdays: [2, 3, 4]),
            density: .compact,
            emphasisedPersonIDs: [UUID()],
            showsPersonContext: false,
            hidesDeclinedEvents: false
        )

        try service.create(original)
        let restored = try #require(try service.sets().first)

        #expect(restored.name == original.name)
        #expect(restored.calendars.count == 2)
        #expect(!restored.showsEveryCalendar)
        #expect(restored.defaultCalendar?.identifier == "a")
        #expect(restored.preferredView == .day)
        #expect(restored.displayTimeZoneIdentifier == "Europe/London")
        #expect(restored.workingHours.weekdays == [2, 3, 4])
        #expect(restored.density == .compact)
        #expect(restored.emphasisedPersonIDs.count == 1)
        #expect(!restored.showsPersonContext)
        #expect(!restored.hidesDeclinedEvents)
    }

    @Test("The active set is a preference and the sets themselves are not")
    func activeSetIsPerDevice() throws {
        let fixture = try StoreFixture()
        let (service, defaults) = makeService(fixture)

        let created = try service.create(CalendarSetDefinition(name: "Work"))
        service.setActive(created.id)

        #expect(try service.activeSet()?.id == created.id)
        #expect(defaults.string(forKey: "calendar.activeSetID") == created.id.uuidString, """
            Which set is showing changes several times a day and belongs to this screen; syncing it \
            would switch a laptop to Family while its owner presents from a meeting room
            """)
    }

    @Test("A selection pointing at a deleted set is forgotten rather than left dangling")
    func staleSelectionIsCleared() throws {
        let fixture = try StoreFixture()
        let (service, defaults) = makeService(fixture)

        let created = try service.create(CalendarSetDefinition(name: "Work"))
        service.setActive(created.id)
        try service.delete(id: created.id)

        #expect(try service.activeSet() == nil)
        #expect(defaults.string(forKey: "calendar.activeSetID") == nil)
    }

    @Test("Deleting a set deletes nothing else")
    func deletingASetIsContained() throws {
        let fixture = try StoreFixture()
        let (service, _) = makeService(fixture)

        _ = try fixture.items.create(ItemDraft(kind: .note, title: "Something"))
        let created = try service.create(CalendarSetDefinition(name: "Work"))

        try service.delete(id: created.id)

        #expect(try service.sets().isEmpty)
        #expect(try fixture.items.items(matching: .everything()).count == 1, "A set owns no content")
    }

    @Test("Sets keep the order the user put them in")
    func reordering() throws {
        let fixture = try StoreFixture()
        let (service, _) = makeService(fixture)

        let first = try service.create(CalendarSetDefinition(name: "Work"))
        let second = try service.create(CalendarSetDefinition(name: "Personal"))
        let third = try service.create(CalendarSetDefinition(name: "Family"))

        try service.reorder([third.id, first.id, second.id])

        #expect(try service.sets().map(\.name) == ["Family", "Work", "Personal"])
    }

    @Test("Suggestions are offered once and created only when accepted")
    func suggestionsAreOffered() throws {
        let fixture = try StoreFixture()
        let (service, _) = makeService(fixture)

        #expect(!service.hasOfferedSuggestions)
        #expect(try service.sets().isEmpty, "Four sets nobody asked for is an app being presumptuous")

        let chosen = Array(CalendarSetDefinition.suggestions().prefix(2))
        try service.acceptSuggestions(chosen)

        #expect(try service.sets().count == 2)
        #expect(service.hasOfferedSuggestions)
    }

    @Test("An unreadable calendar list reads as “every calendar” rather than failing")
    func corruptDataDegradesGracefully() throws {
        let fixture = try StoreFixture()

        let record = CalendarSetRecord(name: "Work")
        record.calendarReferencesData = Data([0x00, 0x01, 0x02])
        fixture.context.insert(record)
        try fixture.context.save()

        let value = record.asValue()
        #expect(value.calendars.isEmpty)
        #expect(value.name == "Work", "A set whose calendar list cannot be read is still a set")
    }
}

@Suite("Templates in the store")
@MainActor
struct EventTemplateStorageTests {
    private func makeService(_ fixture: StoreFixture) -> EventTemplateService {
        EventTemplateService(context: fixture.context, dateProvider: FixedDateProvider.reference)
    }

    @Test("A template survives being stored and read back whole")
    func templatesRoundTrip() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        let original = EventTemplate(
            name: "One-to-one",
            symbolName: "person.2",
            colorName: "teal",
            title: "1:1",
            durationMinutes: 30,
            calendar: CalendarReference(identifier: "work", title: "Work", accountName: "Acme"),
            location: "Room 2",
            notes: "Agenda in the doc",
            availability: .tentative,
            alarms: [.minutesBefore(10), .minutesBefore(60)],
            recurrence: EventRecurrence(frequency: .weekly, daysOfWeek: [.init(3)]),
            timeZoneBehaviour: .fixedZone(identifier: "Europe/London"),
            linkedProjectID: UUID(),
            linkedPersonIDs: [UUID(), UUID()]
        )

        try service.create(original)
        let restored = try #require(try service.templates().first)

        #expect(restored.title == "1:1")
        #expect(restored.durationMinutes == 30)
        #expect(restored.calendar?.identifier == "work")
        #expect(restored.availability == .tentative)
        #expect(restored.alarms.count == 2)
        #expect(restored.recurrence?.frequency == .weekly)
        #expect(restored.timeZoneBehaviour == .fixedZone(identifier: "Europe/London"))
        #expect(restored.linkedPersonIDs.count == 2)
    }

    @Test("A template produces a draft at the time asked for")
    func templateProducesADraft() throws {
        let clock = FixedDateProvider.reference
        let template = EventTemplate(name: "Standup", durationMinutes: 15)

        let draft = template.draft(
            startingAt: clock.startOfToday.addingTimeInterval(9 * 3_600),
            fallbackCalendar: "work",
            available: [CalendarInfo(id: "work", title: "Work")],
            currentZone: TimeZone(identifier: "Europe/London") ?? .gmt
        )

        #expect(draft.duration == TimeInterval(15 * 60))
        #expect(draft.calendarIdentifier == "work")
        #expect(draft.timeZoneIdentifier == "Europe/London")
    }

    @Test("A template whose calendar is gone still works")
    func missingCalendarFallsBack() throws {
        let clock = FixedDateProvider.reference
        let template = EventTemplate(
            name: "Standup",
            calendar: CalendarReference(identifier: "retired", title: "Retired", accountName: "Old")
        )

        let draft = template.draft(
            startingAt: clock.startOfToday,
            fallbackCalendar: "work",
            available: [CalendarInfo(id: "work", title: "Work")],
            currentZone: .gmt
        )

        #expect(draft.calendarIdentifier == "work", """
            A template that stops working because a calendar was renamed is a template somebody has \
            to rebuild for no reason they can see
            """)
    }

    @Test("A floating template writes no zone at all")
    func floatingTemplates() throws {
        let clock = FixedDateProvider.reference
        let template = EventTemplate(name: "Gym", timeZoneBehaviour: .floating)

        let draft = template.draft(
            startingAt: clock.startOfToday,
            fallbackCalendar: "work",
            available: [],
            currentZone: TimeZone(identifier: "Europe/London") ?? .gmt
        )
        #expect(draft.timeZoneIdentifier == nil)
    }

    @Test("Use is recorded, and the menu is ordered by it")
    func rankingByUse() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        let rare = try service.create(EventTemplate(name: "Rare"))
        let common = try service.create(EventTemplate(name: "Common"))

        for _ in 0..<3 { try service.noteUse(of: common.id) }
        try service.noteUse(of: rare.id)

        #expect(try service.mostUsed().map(\.name) == ["Common", "Rare"], """
            Fifteen templates in the order they happened to be made is a list nobody reads to the \
            bottom of
            """)
    }

    @Test("A template made from an event copies its shape and not its links")
    func templatesFromEvents() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let event = CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: "e"),
            title: "Quarterly review",
            startAt: start,
            endAt: start.addingTimeInterval(5_400),
            calendarIdentifier: "work",
            calendarName: "Work",
            accountName: "Acme",
            locationName: "Room 2",
            notes: "Numbers",
            availability: .tentative,
            alarms: [.minutesBefore(15)]
        )

        let template = EventTemplate.from(event: event, named: "Quarterly")

        #expect(template.durationMinutes == 90)
        #expect(template.location == "Room 2")
        #expect(template.alarms.count == 1)
        #expect(template.linkedPersonIDs.isEmpty, """
            The links belong to that meeting. Copying them would attach last quarter's notes to next \
            quarter's event.
            """)
        #expect(template.linkedProjectID == nil)
    }
}

@Suite("What Elephruit knows about an event")
@MainActor
struct EventAnnotationTests {
    private func makeService(_ fixture: StoreFixture) -> EventAnnotationService {
        EventAnnotationService(
            context: fixture.context,
            items: fixture.items,
            dateProvider: FixedDateProvider.reference
        )
    }

    private func event(_ title: String = "Review", identifier: String = "e") -> CalendarEventSummary {
        let start = FixedDateProvider.reference.startOfToday.addingTimeInterval(9 * 3_600)
        return CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: identifier),
            title: title,
            startAt: start,
            endAt: start.addingTimeInterval(3_600),
            calendarIdentifier: "work",
            calendarName: "Work"
        )
    }

    @Test("Nothing is written until something is attached")
    func meetingsAreCreatedLazily() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        let annotation = try service.annotation(for: event().identity)

        #expect(annotation.isEmpty)
        #expect(annotation.meetingItemID == nil)
        #expect(try fixture.items.items(matching: .everything()).isEmpty, """
            A year of somebody's calendar is thousands of events. Writing a row for each so that \
            eleven can have notes would make the store larger than the library.
            """)
    }

    @Test("Linking a person creates the meeting and the link")
    func linkingAPerson() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        let person = try fixture.items.create(ItemDraft(kind: .person, title: "Maya Chen"))
        try service.link(person: person, to: event())

        let annotation = try service.annotation(for: event().identity)
        #expect(annotation.personIDs == [person.id])
        #expect(annotation.meetingItemID != nil)
    }

    @Test("Unlinking removes the link and keeps the person")
    func unlinking() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        let person = try fixture.items.create(ItemDraft(kind: .person, title: "Maya Chen"))
        try service.link(person: person, to: event())
        try service.unlink(person: person, from: event().identity)

        #expect(try service.annotation(for: event().identity).personIDs.isEmpty)
        #expect(try fixture.items.item(id: person.id) != nil, "Unlinking somebody must not delete them")
    }

    @Test("Filing an event under a project shows up on both sides")
    func filing() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        let project = try fixture.items.create(ItemDraft(kind: .project, title: "Q3 Launch"))
        try service.file(event(), under: project)

        #expect(try service.annotation(for: event().identity).projectIDs == [project.id])
    }

    @Test("Notes written before and after a meeting are kept apart")
    func preparationAndDebrief() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        try service.setPreparationNotes("Ask about the timeline", for: event())
        try service.setDebriefNotes("They want two more weeks", for: event())

        let annotation = try service.annotation(for: event().identity)
        #expect(annotation.preparationNotes == "Ask about the timeline")
        #expect(annotation.debriefNotes == "They want two more weeks")
    }

    @Test("Text written before the headings survives one being added")
    func freehandTextIsNotSwallowed() {
        let split = EventAnnotationService.split(body: "Some earlier thought\n\n## After\nWhat happened")

        #expect(split.preamble == "Some earlier thought", """
            A body that predates this feature must not lose its first paragraph the moment a debrief \
            is added
            """)
        #expect(split.debrief == "What happened")
        #expect(split.preparation.isEmpty)
    }

    @Test("A body with no headings is all preamble")
    func plainBodies() {
        let split = EventAnnotationService.split(body: "Just a note")
        #expect(split.preamble == "Just a note")
        #expect(split.preparation.isEmpty && split.debrief.isEmpty)
    }

    @Test("A follow-up is a task, and it is linked to the meeting")
    func followUps() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        let person = try fixture.items.create(ItemDraft(kind: .person, title: "Maya Chen"))
        try service.link(person: person, to: event())

        let task = try service.createFollowUp(
            title: "Send the numbers",
            dueAt: FixedDateProvider.reference.startOfTomorrow,
            for: event(),
            aboutPeople: [person]
        )

        #expect(task.kind == .task)
        #expect(task.status == .open)
        #expect(task.dueAt != nil)

        // Linked to the meeting, so opening either shows the other.
        let meeting = try #require(try service.meetingItem(for: event().identity))
        #expect(task.outgoingLinks.contains { $0.target?.id == meeting.id })
        #expect(task.outgoingLinks.contains { $0.target?.id == person.id })
    }

    @Test("Annotations for a whole window come back in one pass")
    func batchAnnotations() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        let person = try fixture.items.create(ItemDraft(kind: .person, title: "Maya Chen"))
        try service.link(person: person, to: event("First", identifier: "a"))
        try service.link(person: person, to: event("Second", identifier: "b"))

        let identities = ["a", "b", "c"].map { EventIdentity(externalIdentifier: $0) }
        let found = try service.annotations(for: identities)

        #expect(found.count == 2)
        #expect(try service.annotatedKeys(among: identities) == ["a", "b"], """
            One fetch rather than one per row: a month view asking per event is a thousand queries
            """)
    }

    @Test("Prior meetings with the same people come back newest first")
    func priorMeetings() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)
        let clock = FixedDateProvider.reference

        let person = try fixture.items.create(ItemDraft(kind: .person, title: "Maya Chen"))

        for offset in [-30, -10, -2] {
            let start = clock.startOfDay(daysFromToday: offset)
            let past = CalendarEventSummary(
                identity: EventIdentity(externalIdentifier: "past\(offset)"),
                title: "Catch-up \(offset)",
                startAt: start,
                endAt: start.addingTimeInterval(3_600)
            )
            try service.link(person: person, to: past)
        }

        let history = try service.priorMeetings(withPeople: [person.id], before: clock.now)

        #expect(history.count == 3)
        let dates = history.compactMap { $0.eventReference?.startAt }
        #expect(dates == dates.sorted(by: >), "Newest first, because that is what you need walking in")
    }

    @Test("A future meeting is not history")
    func futureMeetingsAreExcluded() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)
        let clock = FixedDateProvider.reference

        let person = try fixture.items.create(ItemDraft(kind: .person, title: "Maya Chen"))
        let future = CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: "future"),
            title: "Next week",
            startAt: clock.startOfDay(daysFromToday: 7),
            endAt: clock.startOfDay(daysFromToday: 7).addingTimeInterval(3_600)
        )
        try service.link(person: person, to: future)

        #expect(try service.priorMeetings(withPeople: [person.id], before: clock.now).isEmpty)
    }

    @Test("The cached title keeps a linked meeting readable when the calendar is off")
    func cachedDetailsSurvive() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        let person = try fixture.items.create(ItemDraft(kind: .person, title: "Maya Chen"))
        try service.link(person: person, to: event("Board meeting"))

        let meeting = try #require(try service.meetingItem(for: event().identity))
        #expect(meeting.eventReference?.cachedTitle == "Board meeting")
        #expect(meeting.eventReference?.startAt != nil)
    }
}

@Suite("Calendar colours match the design system")
struct CalendarPaletteAgreementTests {
    @Test("Every name the mapper can produce exists in the palette")
    func namesAgreeWithTheDesignSystem() {
        // The mapper lives in Core, which knows nothing about SwiftUI, and the palette lives in the
        // design system. They can only be kept in agreement by a test that can see both — and an
        // unknown name does not fail loudly, it silently resolves to the accent colour and looks
        // deliberate.
        let designNames = Set(Theme.Palette.allCases.map(\.rawValue))
        let mapperNames = Set(CalendarPalette.names)

        #expect(mapperNames.isSubset(of: designNames), """
            \(mapperNames.subtracting(designNames)) are produced by the colour mapper and are not in \
            the palette
            """)
    }
}
