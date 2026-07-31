import AppIntents
import ElephruitCore
import ElephruitFeatures
import ElephruitModel
import ElephruitPersistence
import Foundation

/// The calendar in Shortcuts.
///
/// ### What is exposed, and what deliberately is not
/// Reading is unrestricted: an automation may ask what is on today, when the next meeting is, or
/// what the calendar holds for a search. Writing is limited to **creating an event**, which is the
/// one write whose effect is entirely contained — a new event appears, and nothing that already
/// existed changes.
///
/// There is no intent that edits or deletes an existing event, and that is a decision rather than an
/// omission. Both require an ``EventEditScope``, and the whole point of that type is that a person
/// chooses it in front of a sheet explaining what each choice does. An automation running unattended
/// cannot make that choice, and defaulting it is exactly how somebody loses a year of a series. The
/// module's rule — anything consequential is previewed by a person — is kept by not granting the
/// capability, which is stronger than a confirmation an automation could be written to dismiss.
///
/// Nothing here publishes availability, creates a conference, or proposes a time to anybody.

// MARK: - Reading

struct TodaysAgendaIntent: AppIntent {
    static let title: LocalizedStringResource = "Today's Agenda"

    static let description = IntentDescription(
        "Lists what is on your calendar today.",
        categoryName: "Calendar"
    )

    static let openAppWhenRun = false
    static let isDiscoverable = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[String]> {
        let services = try CaptureBridge.services()
        await services.calendar.start()

        guard services.calendar.isEnabled, services.calendar.authorization.canRead else {
            return .result(value: [String](), dialog: "Calendar access is not turned on in Elephruit.")
        }

        let calendar = services.calendar.displayCalendar
        let start = calendar.startOfDay(for: services.dateProvider.now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return .result(value: [String](), dialog: "Could not work out today's dates.")
        }

        await services.calendar.load(range: start..<end)
        let events = services.calendar.events(on: services.dateProvider.now)

        guard !events.isEmpty else {
            return .result(value: [String](), dialog: "Nothing scheduled today.")
        }

        let lines = events.map { event -> String in
            let time = event.isAllDay
                ? "All day"
                : event.startAt.formatted(date: .omitted, time: .shortened)
            return "\(time) — \(event.displayTitle)"
        }

        return .result(value: lines, dialog: "\(lines.prefix(4).joined(separator: ", "))")
    }
}

struct NextEventIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Event"

    static let description = IntentDescription(
        "Says what is coming up next on your calendar.",
        categoryName: "Calendar"
    )

    static let openAppWhenRun = false
    static let isDiscoverable = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String?> {
        let services = try CaptureBridge.services()
        await services.calendar.start()

        guard services.calendar.isEnabled, services.calendar.authorization.canRead else {
            return .result(value: nil, dialog: "Calendar access is not turned on in Elephruit.")
        }

        let calendar = services.calendar.displayCalendar
        let start = calendar.startOfDay(for: services.dateProvider.now)
        // Two days, because "next" late at night is tomorrow morning — and answering "nothing" to
        // somebody with a seven o'clock flight is the wrong answer to the question they asked.
        guard let end = calendar.date(byAdding: .day, value: 2, to: start) else {
            return .result(value: nil, dialog: "Could not work out the dates.")
        }

        await services.calendar.load(range: start..<end)

        let next = services.calendar.events
            .filter { $0.startAt > services.dateProvider.now && $0.appearsInPlan && !$0.isAllDay }
            .min { $0.startAt < $1.startAt }

        guard let next else {
            return .result(value: nil, dialog: "Nothing else scheduled.")
        }

        let when = next.startAt.formatted(date: .abbreviated, time: .shortened)
        var sentence = "\(next.displayTitle) at \(when)"
        if let location = next.locationName, !location.isEmpty { sentence += ", at \(location)" }

        return .result(value: next.displayTitle, dialog: "\(sentence).")
    }
}

struct SearchCalendarIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Calendar"

    static let description = IntentDescription(
        """
        Searches your events. Understands “with:maya”, “in:austin”, “calendar:work”, \
        “without:notes”, and periods like “last year”.
        """,
        categoryName: "Calendar"
    )

    static let openAppWhenRun = false
    static let isDiscoverable = true

    @Parameter(title: "Search", requestValueDialog: "What are you looking for?")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[String]> {
        let services = try CaptureBridge.services()

        let results = await services.calendarSearch.search(
            query,
            now: services.dateProvider.now,
            calendar: services.calendar.displayCalendar,
            limit: 25
        )

        guard !results.isEmpty else {
            return .result(value: [String](), dialog: "Nothing matched “\(query)”.")
        }

        let lines = results.events.map { event in
            "\(event.startAt.formatted(date: .abbreviated, time: .omitted)) — \(event.displayTitle)"
        }
        return .result(value: lines, dialog: "\(results.events.count) events. \(lines.prefix(3).joined(separator: ", "))")
    }
}

// MARK: - Writing

struct CreateEventIntent: AppIntent {
    static let title: LocalizedStringResource = "Create an Event"

    static let description = IntentDescription(
        """
        Creates an event from a sentence — “Lunch with Maya tomorrow at noon”. Shows what it \
        understood before it is added.
        """,
        categoryName: "Calendar"
    )

    static let openAppWhenRun = false

    @Parameter(title: "Event", requestValueDialog: "What would you like to add?")
    var phrase: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = try CaptureBridge.services()
        await services.calendar.start()

        guard services.calendar.isEnabled, services.calendar.authorization.canRead else {
            return .result(dialog: "Calendar access is not turned on in Elephruit.")
        }

        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .result(dialog: "Nothing to add.") }

        let people = (try? services.persons.allPeople(includingPlaceholders: false))?.map {
            KnownPerson(id: $0.id, fullName: $0.displayTitle)
        } ?? []

        let context = EventPhraseContext(
            people: people,
            calendarNames: services.calendar.calendars.map(\.title),
            timeZoneIdentifiers: services.calendar.timeZoneDisplay.favouriteZoneIdentifiers
        )

        let interpretation = EventPhraseParser.parse(
            trimmed, context: context, calendar: services.calendar.displayCalendar
        )

        guard let identifier = services.calendar.defaultCalendarIdentifier else {
            return .result(dialog: "There is no calendar Elephruit can write to.")
        }
        guard let draft = interpretation.draft(
            defaultCalendarIdentifier: identifier,
            calendars: services.calendar.calendars,
            dateProvider: services.dateProvider
        ) else {
            return .result(dialog: "Could not work out when “\(trimmed)” should be.")
        }

        switch await services.calendar.create(draft) {
        case .success(let event):
            // The person the phrase named is linked in Elephruit and never written into the event,
            // which is the same rule the interface follows and the reason an automation is allowed
            // to do this at all.
            if let personID = interpretation.personID,
               let person = try? services.items.item(id: personID) {
                _ = try? services.eventLinks.link(person: person, to: event)
            }

            let when = event.isAllDay
                ? event.startAt.formatted(date: .abbreviated, time: .omitted)
                : event.startAt.formatted(date: .abbreviated, time: .shortened)
            let name = event.calendarName.map { " on \($0)" } ?? ""

            return .result(dialog: "Added “\(event.displayTitle)” for \(when)\(name).")

        case .failure(let failure):
            return .result(dialog: "\(failure.message)")
        }
    }
}

struct SwitchCalendarSetIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Calendar Set"

    static let description = IntentDescription(
        "Changes which calendars are showing, and the view and working hours that go with them.",
        categoryName: "Calendar"
    )

    static let openAppWhenRun = false

    @Parameter(title: "Set", requestValueDialog: "Which set?")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = try CaptureBridge.services()
        await services.calendar.refreshSets()

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // "All" returns to showing everything, which is a real state and the one somebody wants back
        // after a focus session.
        if ["all", "everything", "all calendars"].contains(trimmed) {
            await services.calendar.activate(setID: nil)
            return .result(dialog: "Showing every calendar.")
        }

        guard let match = services.calendar.sets.first(where: {
            TextNormalizer.foldedForMatching($0.name) == TextNormalizer.foldedForMatching(name)
        }) ?? services.calendar.sets.first(where: {
            TextNormalizer.foldedForMatching($0.name).hasPrefix(TextNormalizer.foldedForMatching(name))
        }) else {
            let available = services.calendar.sets.map(\.name).joined(separator: ", ")
            return .result(dialog: available.isEmpty
                ? "There are no Calendar Sets yet."
                : "No set called “\(name)”. There is: \(available).")
        }

        await services.calendar.activate(setID: match.id)
        return .result(dialog: "Switched to \(match.name).")
    }
}

struct OpenCalendarIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Calendar"

    static let description = IntentDescription(
        "Brings Elephruit forward on your calendar.",
        categoryName: "Calendar"
    )

    /// One of the two intents that does open the app, because opening it is the whole ask.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CalendarIntentRouting.shouldOpenCalendar = true
        return .result()
    }
}

/// What an intent asked the app to do when it comes forward.
///
/// A stored flag rather than a URL scheme, on the same terms as ``PeopleIntentRouting``: the intent
/// runs in this process, and registering a scheme would be a second externally-reachable entry point
/// for no benefit.
///
/// `@MainActor`, which is what makes mutable static state legal here rather than a data race waiting
/// to happen: every reader and every writer is already on the main actor.
@MainActor
enum CalendarIntentRouting {
    static var shouldOpenCalendar = false

    /// A day to land on, set by a deep link.
    static var requestedDay: Date?
}
