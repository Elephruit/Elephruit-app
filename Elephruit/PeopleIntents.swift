import AppIntents
import ElephruitCore
import ElephruitFeatures
import ElephruitModel
import ElephruitPersistence
import Foundation

/// The People module in Shortcuts.
///
/// ### What is exposed, and what deliberately is not
/// Everything here **reads or writes Elephruit's own store**. Nothing sends an email, places a call,
/// creates a calendar invitation, or touches the system address book, because an automation runs with
/// nobody watching and the module's rule is that anything externally visible is previewed and
/// confirmed by a person. An intent cannot honour that, so it does not get the capability — which is
/// a stronger guarantee than a confirmation dialogue an automation could be built to dismiss.
///
/// Retrieval intents are marked `isDiscoverable` and read-only. Writing intents state what they wrote
/// in their dialogue, so a Shortcut that runs unattended still leaves a record of what it did.

// MARK: - Finding

struct FindPersonIntent: AppIntent {
    static let title: LocalizedStringResource = "Find a Person"

    static let description = IntentDescription(
        "Searches your people by name, by what you have recorded about them, or by how they are related to somebody.",
        categoryName: "People"
    )

    static let openAppWhenRun = false

    @Parameter(title: "Search", requestValueDialog: "Who are you looking for?")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[String]> {
        let services = try CaptureBridge.services()
        let results = try services.personSearch.search(query, limit: 10)

        guard !results.isEmpty else {
            return .result(value: [String](), dialog: "Nobody matches “\(query)”.")
        }

        let names = results.map(\.name)
        let summary = results.prefix(3)
            .map { result in result.bestReason.map { "\(result.name) — \($0.text)" } ?? result.name }
            .joined(separator: ", ")

        return .result(value: names, dialog: "\(summary)")
    }
}

struct OpenPersonIntent: AppIntent {
    static let title: LocalizedStringResource = "Open a Person"

    static let description = IntentDescription(
        "Brings Elephruit forward on somebody's page.",
        categoryName: "People"
    )

    /// The one intent here that does bring the app forward, because opening a page is the whole ask.
    static let openAppWhenRun = true

    @Parameter(title: "Name", requestValueDialog: "Whose page?")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = try CaptureBridge.services()

        guard let match = try services.personSearch.search(name, limit: 1).first else {
            return .result(dialog: "No one called “\(name)”.")
        }

        PeopleIntentRouting.requestedPersonID = match.id
        return .result(dialog: "Opening \(match.name).")
    }
}

// MARK: - Writing

struct CreatePersonIntent: AppIntent {
    static let title: LocalizedStringResource = "Create a Person"

    static let description = IntentDescription(
        "Adds somebody to Elephruit. Creates a local record only — your system contacts are never changed.",
        categoryName: "People"
    )

    static let openAppWhenRun = false

    @Parameter(title: "Name", requestValueDialog: "What is their name?")
    var name: String

    @Parameter(title: "Email")
    var email: String?

    @Parameter(title: "Phone")
    var phone: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "A person needs a name.")
        }

        let services = try CaptureBridge.services()

        var draft = PersonDraft(fullName: trimmed)
        if let email, !email.isEmpty { draft.emails = [LabelledValue(label: "email", value: email)] }
        if let phone, !phone.isEmpty { draft.phones = [LabelledValue(label: "phone", value: phone)] }

        let person = try services.persons.createPerson(draft)
        services.noteChange(to: person)

        return .result(dialog: "Added \(person.displayTitle) to Elephruit.")
    }
}

struct AddPersonNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a Note About Someone"

    static let description = IntentDescription(
        "Writes a timestamped note and links it to somebody, so it appears in their history.",
        categoryName: "People"
    )

    static let openAppWhenRun = false

    @Parameter(title: "Person", requestValueDialog: "Who is this about?")
    var name: String

    @Parameter(title: "Note", requestValueDialog: "What do you want to record?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = try CaptureBridge.services()

        guard let person = try PeopleIntentRouting.resolve(name, in: services) else {
            return .result(dialog: "No one called “\(name)”.")
        }

        let note = try services.items.create(ItemDraft(kind: .note, title: text))
        try services.items.link(note, to: person, kind: .mentions)
        services.noteChange(to: note)

        return .result(dialog: "Noted against \(person.displayTitle).")
    }
}

struct LogInteractionIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a Conversation"

    static let description = IntentDescription(
        "Records that you spoke to somebody, with a summary. This is a record you are making, not something detected.",
        categoryName: "People"
    )

    static let openAppWhenRun = false

    @Parameter(title: "Person", requestValueDialog: "Who did you speak to?")
    var name: String

    @Parameter(title: "What was it about", requestValueDialog: "What was it about?")
    var summary: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = try CaptureBridge.services()

        guard let person = try PeopleIntentRouting.resolve(name, in: services) else {
            return .result(dialog: "No one called “\(name)”.")
        }

        let interaction = try services.people.recordInteraction(with: person, summary: summary)
        // Stated by a person rather than inferred by the app, so it counts as contact.
        try services.items.update(interaction) {
            $0.sourceIdentifier = InteractionProvenance.logged.rawValue
        }
        services.noteChange(to: interaction)

        return .result(dialog: "Logged a conversation with \(person.displayTitle).")
    }
}

struct RecordFactIntent: AppIntent {
    static let title: LocalizedStringResource = "Record a Fact About Someone"

    static let description = IntentDescription(
        "Records something you learned, with today's date, so any estimate derived from it advances correctly.",
        categoryName: "People"
    )

    static let openAppWhenRun = false

    @Parameter(title: "Person", requestValueDialog: "Who is this about?")
    var name: String

    @Parameter(title: "Fact", requestValueDialog: "What did you learn?")
    var value: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = try CaptureBridge.services()

        guard let person = try PeopleIntentRouting.resolve(name, in: services) else {
            return .result(dialog: "No one called “\(name)”.")
        }

        try services.persons.record(
            ObservationDraft(attribute: .lifeEvent, value: value),
            about: person,
            observedOn: services.dateProvider.now,
            confidence: .stated,
            sensitivity: .normal,
            source: nil
        )
        services.noteChange(to: person)

        return .result(dialog: "Recorded for \(person.displayTitle), dated today.")
    }
}

struct CreateFollowUpIntent: AppIntent {
    static let title: LocalizedStringResource = "Create a Follow-up"

    static let description = IntentDescription(
        "Adds a task linked to somebody, so it appears in their history and in your Today list.",
        categoryName: "People"
    )

    static let openAppWhenRun = false

    @Parameter(title: "Person", requestValueDialog: "Who is this about?")
    var name: String

    @Parameter(title: "What needs doing", requestValueDialog: "What needs doing?")
    var text: String

    @Parameter(title: "Is this a promise you made?", default: false)
    var isPromise: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = try CaptureBridge.services()

        guard let person = try PeopleIntentRouting.resolve(name, in: services) else {
            return .result(dialog: "No one called “\(name)”.")
        }

        // A promise is tagged, never inferred from the wording — see `PersonWorkspaceService`.
        let task = try services.items.create(
            ItemDraft(kind: .task, title: text, tagSlugs: isPromise ? ["promise"] : [])
        )
        try services.items.link(task, to: person, kind: .mentions)
        services.noteChange(to: task)

        return .result(dialog: "Added a follow-up for \(person.displayTitle).")
    }
}

// MARK: - Retrieval

struct MeetingBriefIntent: AppIntent {
    static let title: LocalizedStringResource = "Get a Meeting Brief"

    static let description = IntentDescription(
        "Everything worth knowing before you see somebody. Estimates are labeled as estimates.",
        categoryName: "People"
    )

    static let openAppWhenRun = false

    @Parameter(title: "Person", requestValueDialog: "Who are you seeing?")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let services = try CaptureBridge.services()

        guard let person = try PeopleIntentRouting.resolve(name, in: services) else {
            return .result(value: "", dialog: "No one called “\(name)”.")
        }

        let brief = try services.personWorkspace.brief(for: person)
        guard !brief.isEmpty else {
            return .result(value: "", dialog: "Nothing recorded about \(person.displayTitle) yet.")
        }

        // Estimates are marked in the text itself rather than in a separate field a Shortcut might
        // drop on the way to a notification. A brief read aloud has to carry its own hedges.
        let text = brief.sections
            .map { group in
                let lines = group.entries
                    .map { $0.needsEstimateLabel ? "\($0.text) (estimated)" : $0.text }
                    .joined(separator: "; ")
                return "\(group.section.displayName): \(lines)"
            }
            .joined(separator: "\n")

        return .result(value: text, dialog: "\(brief.summaryLine).")
    }
}

struct UpcomingCelebrationsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Upcoming Celebrations"

    static let description = IntentDescription(
        "Birthdays, anniversaries, and milestones coming up.",
        categoryName: "People"
    )

    static let openAppWhenRun = false

    @Parameter(title: "Days ahead", default: 30)
    var days: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[String]> {
        let services = try CaptureBridge.services()

        let upcoming = CelebrationCalendar.upcoming(
            from: try services.persons.allCelebrations(),
            within: max(1, days),
            asOf: services.dateProvider.now,
            calendar: services.dateProvider.calendar
        )

        guard !upcoming.isEmpty else {
            return .result(value: [String](), dialog: "Nothing coming up in the next \(days) days.")
        }

        let lines = upcoming.map(\.summary)
        return .result(value: lines, dialog: "\(lines.prefix(3).joined(separator: ", ")).")
    }
}

// MARK: - Support

/// Shared plumbing for the People intents.
@MainActor
enum PeopleIntentRouting {
    /// Set by ``OpenPersonIntent`` and read by the app when it comes forward.
    ///
    /// A stored identifier rather than a URL scheme, because the intent runs in the same process and
    /// registering a scheme would be a second, externally-reachable entry point for no benefit.
    static var requestedPersonID: UUID?

    /// Finds one person by name, or `nil`.
    ///
    /// Uses the same search the interface does, so an automation and a human typing the same words
    /// reach the same person.
    static func resolve(_ name: String, in services: AppServices) throws -> Item? {
        guard let match = try services.personSearch.search(name, limit: 1).first else { return nil }
        return try services.persons.person(id: match.id)
    }
}

/// The People intents are surfaced through the app's single ``ElephruitShortcuts`` provider, which
/// App Intents allows exactly one of per target. Adding a second conformance compiles and then
/// silently registers nothing, which is the worst of both.
