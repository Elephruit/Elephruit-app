import Foundation

// MARK: - What the parser is told

/// Somebody the parser is allowed to recognise.
///
/// Handed in rather than looked up, so parsing stays pure and testable: the store is consulted once,
/// by the caller, and the grammar never learns what a `ModelContext` is.
public struct KnownPerson: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var fullName: String

    /// First name, nickname, initials — anything that should also match.
    public var aliases: [String]

    /// Group names this person belongs to, so `email Design Team` can be told from `email Maya`.
    public var groupNames: [String]

    public init(id: UUID, fullName: String, aliases: [String] = [], groupNames: [String] = []) {
        self.id = id
        self.fullName = fullName
        self.aliases = aliases
        self.groupNames = groupNames
    }

    /// Every string that identifies this person, folded for matching, longest first.
    var matchKeys: [String] {
        var names = [fullName] + aliases
        // A full name also matches on its first name alone, which is how people actually type.
        let parts = fullName.split(separator: " ").map(String.init)
        if parts.count > 1 {
            names.append(contentsOf: parts)
        }
        return names
            .map(TextNormalizer.foldedForMatching)
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }
}

/// A named group the parser may address.
public struct KnownGroup: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var memberCount: Int

    public init(id: UUID, name: String, memberCount: Int) {
        self.id = id
        self.name = name
        self.memberCount = memberCount
    }
}

/// Everything the parser needs to know about the library.
public struct CommandContext: Sendable {
    public var people: [KnownPerson]
    public var groups: [KnownGroup]

    public init(people: [KnownPerson] = [], groups: [KnownGroup] = []) {
        self.people = people
        self.groups = groups
    }

    public static let empty = CommandContext()
}

// MARK: - What the parser produces

/// One thing the parser recognised, and where it was.
public struct RecognizedEntity: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case person
        /// A name that matches nobody. Offered as a creation, never created silently.
        case newPerson
        case group
        case email
        case phone
        case address
        case company
        case jobTitle
        case relationship
        case date
        case time
        case age
        case grade
        case note
        case tag
        case url
    }

    public var id: UUID
    public var kind: Kind

    /// The recognised value, cleaned of syntax.
    public var text: String

    /// Character offsets into the input, so the field can underline what it understood.
    public var range: Range<Int>

    /// The matched person or group, when the entity resolved to one.
    public var resolvedID: UUID?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        range: Range<Int>,
        resolvedID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.range = range
        self.resolvedID = resolvedID
    }

    public var displayLabel: String {
        switch kind {
        case .person: "Person"
        case .newPerson: "New person"
        case .group: "Group"
        case .email: "Email"
        case .phone: "Phone"
        case .address: "Address"
        case .company: "Company"
        case .jobTitle: "Title"
        case .relationship: "Relationship"
        case .date: "Date"
        case .time: "Time"
        case .age: "Age"
        case .grade: "Grade"
        case .note: "Note"
        case .tag: "Tag"
        case .url: "Link"
        }
    }
}

/// Something the parser understood but cannot decide on its own.
///
/// Surfaced in the preview and blocking the command until answered. The alternative — picking one
/// and hoping — is how an app ends up calling the wrong number.
public enum CommandAmbiguity: Sendable, Hashable {
    /// A name matching nobody in the library.
    case unknownPerson(name: String)

    /// A name matching more than one person.
    case multiplePeople(name: String, candidateIDs: [UUID])

    /// A group name matching nobody.
    case unknownGroup(name: String)

    /// The person has several numbers or addresses and the command did not say which.
    case multipleDestinations(channel: ContactChannel)

    /// A date was expected and none parsed.
    case noDateFound(text: String)

    public var message: String {
        switch self {
        case .unknownPerson(let name):
            "No one called “\(name)” yet."
        case .multiplePeople(let name, let ids):
            "\(ids.count) people match “\(name)”."
        case .unknownGroup(let name):
            "No group called “\(name)”."
        case .multipleDestinations(let channel):
            "Which \(channel.destinationNoun)?"
        case .noDateFound(let text):
            "Could not read a date in “\(text)”."
        }
    }

    /// Whether the command can still run, with a choice made in the preview.
    ///
    /// An unknown person is *resolvable* — the answer is "create them". A missing date is not, and
    /// the command bar keeps the user in the field rather than running something half-understood.
    public var isResolvable: Bool {
        switch self {
        case .unknownPerson, .multiplePeople, .multipleDestinations: true
        case .unknownGroup, .noDateFound: false
        }
    }
}

/// Everything a new person record might carry, straight from one line of typing.
public struct PersonDraftFields: Sendable, Hashable {
    public var name: String
    public var emails: [String] = []
    public var phones: [String] = []
    public var company: String?
    public var jobTitle: String?
    public var address: String?

    public init(
        name: String,
        emails: [String] = [],
        phones: [String] = [],
        company: String? = nil,
        jobTitle: String? = nil,
        address: String? = nil
    ) {
        self.name = name
        self.emails = emails
        self.phones = phones
        self.company = company
        self.jobTitle = jobTitle
        self.address = address
    }
}

/// A fact the command bar wants to record.
public struct ObservationDraft: Sendable, Hashable {
    public var attribute: FactAttribute
    public var value: String
    public var effective: DateExpression?
    public var schoolYearStart: Int?

    public init(
        attribute: FactAttribute,
        value: String,
        effective: DateExpression? = nil,
        schoolYearStart: Int? = nil
    ) {
        self.attribute = attribute
        self.value = value
        self.effective = effective
        self.schoolYearStart = schoolYearStart
    }
}

/// What a line of command-bar text means.
public enum CommandIntent: Sendable, Hashable {
    /// Nothing recognised — fall through to search.
    case search(query: String)

    /// Open somebody's page.
    case open(personID: UUID)

    /// Show one detail of somebody — `Maya mobile`.
    case reveal(personID: UUID, channel: ContactChannel)

    /// Show one of somebody's relationship charts — `show Maya's family`.
    case chart(personID: UUID, chart: RelationshipChartKind)

    /// Reach somebody. **Always previewed** — see ``ParsedCommand/requiresConfirmation``.
    case contact(personID: UUID, channel: ContactChannel)

    /// Put a meeting in the calendar with somebody.
    case schedule(personID: UUID, day: DateExpression, time: TimeOfDay?)

    /// Create a person from a line of details.
    case createPerson(PersonDraftFields)

    /// Add details to somebody who already exists.
    case addDetails(personID: UUID, fields: PersonDraftFields)

    /// Record a celebration date.
    case setCelebration(personID: UUID, kind: CelebrationKind, date: PartialDate)

    /// Record a dated fact.
    case recordFact(personID: UUID, draft: ObservationDraft)

    /// Record a related person, plus anything said about them in the same breath.
    case recordRelation(
        personID: UUID,
        kind: RelationshipKind,
        label: String?,
        relatedName: String,
        observations: [ObservationDraft]
    )

    /// Append a timestamped note to somebody.
    case addNote(personID: UUID, text: String)

    /// Create a follow-up task, optionally about some people.
    case createTask(text: String, personIDs: [UUID], day: DateExpression?)

    /// Act on a whole group. **Always previewed.**
    case groupAction(groupID: UUID, action: GroupAction)

    public var isExternallyVisible: Bool {
        switch self {
        case .contact, .schedule:
            true
        case .groupAction(_, let action):
            action.isExternallyVisible
        default:
            false
        }
    }
}

/// What to do with a whole group.
public enum GroupAction: Sendable, Hashable {
    case email
    case message
    case invite(day: DateExpression, time: TimeOfDay?, title: String)
    case tag(String)
    case export

    public var isExternallyVisible: Bool {
        switch self {
        case .email, .message, .invite: true
        case .tag, .export: false
        }
    }

    public var displayName: String {
        switch self {
        case .email: "Email everyone"
        case .message: "Message everyone"
        case .invite: "Send an invitation"
        case .tag(let slug): "Tag with #\(slug)"
        case .export: "Export"
        }
    }
}

/// One line of command-bar text, understood.
public struct ParsedCommand: Sendable, Hashable {
    public var intent: CommandIntent
    public var entities: [RecognizedEntity]
    public var ambiguities: [CommandAmbiguity]

    /// What the user typed, verbatim.
    public var originalText: String

    /// One line describing what will happen, shown live under the field.
    public var summary: String

    public init(
        intent: CommandIntent,
        entities: [RecognizedEntity] = [],
        ambiguities: [CommandAmbiguity] = [],
        originalText: String = "",
        summary: String = ""
    ) {
        self.intent = intent
        self.entities = entities
        self.ambiguities = ambiguities
        self.originalText = originalText
        self.summary = summary
    }

    /// Whether running this needs an explicit confirmation step.
    ///
    /// Two reasons, kept separate: the command is externally visible — it sends, calls, or
    /// invites — or it is ambiguous and somebody has to choose. Either way the command bar shows the
    /// details and waits.
    public var requiresConfirmation: Bool {
        intent.isExternallyVisible || !ambiguities.isEmpty
    }

    /// Whether the command can run at all.
    public var isRunnable: Bool {
        if case .search = intent { return false }
        return ambiguities.allSatisfy(\.isResolvable)
    }
}

// MARK: - The protocol

/// Reads a line of command-bar text.
///
/// A protocol with one deterministic implementation today. An AI-backed parser is an additional
/// conformance — it receives the same ``CommandContext`` and returns the same ``ParsedCommand``, so
/// the preview, the confirmation rules, and every test written against the grammar apply to it
/// unchanged. The deterministic one stays as the offline default and as the thing the AI one is
/// measured against.
public protocol PersonCommandParsing: Sendable {
    func parse(_ input: String, context: CommandContext) -> ParsedCommand
}

// MARK: - The deterministic implementation

/// Verb-first, then name-first. No machine learning, no network, no surprises.
///
/// ### The shape of the grammar
/// A line is read as a leading verb (`call`, `email`, `note`, `task`, `show`, `add`, `invite`)
/// applied to a person or a group, or — failing that — as a person's name followed by something said
/// about them. Anything the parser cannot claim becomes a search, which is the honest fallback: the
/// user gets results rather than an error, and nothing happens that they did not ask for.
///
/// Every recognised span is recorded with its range, so the field underlines what it understood
/// while it is being typed. That live preview is the safety mechanism — a command that is about to
/// do the wrong thing looks wrong before Return is pressed.
public struct DeterministicPersonCommandParser: PersonCommandParsing {
    public init() {}

    public func parse(_ input: String, context: CommandContext) -> ParsedCommand {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedCommand(intent: .search(query: ""), originalText: input, summary: "")
        }

        var state = ParseState(input: trimmed, context: context)

        if let command = parseVerbLed(&state) { return command }
        if let command = parseNameLed(&state) { return command }

        return ParsedCommand(
            intent: .search(query: trimmed),
            entities: state.entities,
            originalText: input,
            summary: "Search for “\(trimmed)”"
        )
    }

    // MARK: Verb-led

    private func parseVerbLed(_ state: inout ParseState) -> ParsedCommand? {
        guard let verb = state.leadingWord?.lowercased() else { return nil }

        switch verb {
        case "call", "ring", "phone":
            return contactCommand(&state, verb: verb, channel: .call)
        case "message", "text", "sms", "imessage":
            return contactCommand(&state, verb: verb, channel: .message)
        case "email", "mail":
            return emailCommand(&state, verb: verb)
        case "facetime":
            return facetimeCommand(&state)
        case "meet", "schedule":
            return meetCommand(&state, verb: verb)
        case "note":
            return noteCommand(&state)
        case "task", "remind":
            return taskCommand(&state, verb: verb)
        case "show", "open", "find":
            return showCommand(&state, verb: verb)
        case "add", "new":
            return addCommand(&state, verb: verb)
        case "invite":
            return inviteCommand(&state)
        default:
            return nil
        }
    }

    /// `call Maya` · `message Maya`.
    private func contactCommand(_ state: inout ParseState, verb: String, channel: ContactChannel) -> ParsedCommand? {
        state.consumeLeadingWord()
        guard let subject = state.consumePerson() else { return state.unknownSubject(verb: verb, channel: channel) }

        return state.command(
            intent: .contact(personID: subject.id, channel: channel),
            summary: "\(channel.verbPhrase) \(subject.fullName)"
        )
    }

    /// `email Maya` or `email Design Team` — the one verb that addresses either.
    private func emailCommand(_ state: inout ParseState, verb: String) -> ParsedCommand? {
        state.consumeLeadingWord()

        if let group = state.consumeGroup() {
            return state.command(
                intent: .groupAction(groupID: group.id, action: .email),
                summary: "Email \(group.name) — \(group.memberCount) \(group.memberCount == 1 ? "person" : "people")"
            )
        }

        guard let subject = state.consumePerson() else { return state.unknownSubject(verb: verb, channel: .email) }
        return state.command(
            intent: .contact(personID: subject.id, channel: .email),
            summary: "Email \(subject.fullName)"
        )
    }

    /// `facetime Maya` · `facetime audio Maya`.
    private func facetimeCommand(_ state: inout ParseState) -> ParsedCommand? {
        state.consumeLeadingWord()

        var channel = ContactChannel.facetimeVideo
        if let next = state.leadingWord?.lowercased(), next == "audio" || next == "voice" {
            state.consumeLeadingWord()
            channel = .facetimeAudio
        }

        guard let subject = state.consumePerson() else {
            return state.unknownSubject(verb: "facetime", channel: channel)
        }
        return state.command(
            intent: .contact(personID: subject.id, channel: channel),
            summary: "\(channel.verbPhrase) \(subject.fullName)"
        )
    }

    /// `meet Maya next Tuesday at 2`.
    private func meetCommand(_ state: inout ParseState, verb: String) -> ParsedCommand? {
        state.consumeLeadingWord()
        guard let subject = state.consumePerson() else {
            return state.unknownSubject(verb: verb, channel: nil)
        }

        guard let when = state.consumeDate() else {
            return state.command(
                intent: .open(personID: subject.id),
                ambiguities: [.noDateFound(text: state.remainingText)],
                summary: "Meet \(subject.fullName) — when?"
            )
        }

        return state.command(
            intent: .schedule(personID: subject.id, day: when.day, time: when.time),
            summary: "Meet \(subject.fullName) \(when.summary)"
        )
    }

    /// `note Maya prefers small restaurants`.
    private func noteCommand(_ state: inout ParseState) -> ParsedCommand? {
        state.consumeLeadingWord()
        guard let subject = state.consumePerson() else { return state.unknownSubject(verb: "note", channel: nil) }

        let text = state.remainingText
        guard !text.isEmpty else {
            return state.command(intent: .open(personID: subject.id), summary: "Open \(subject.fullName)")
        }

        state.claimRemainder(as: .note)
        return state.command(
            intent: .addNote(personID: subject.id, text: text),
            summary: "Note on \(subject.fullName): “\(text)”"
        )
    }

    /// `task introduce Maya to Danielle Friday`.
    ///
    /// Unlike every other verb this does *not* consume a leading person — the people named in a task
    /// are its subject matter, not its target, and eating the first one would turn "introduce Maya to
    /// Danielle" into a task called "to Danielle".
    private func taskCommand(_ state: inout ParseState, verb: String) -> ParsedCommand? {
        state.consumeLeadingWord()
        if verb == "remind", state.leadingWord?.lowercased() == "me" { state.consumeLeadingWord() }

        let mentioned = state.markPeopleInRemainder()
        let when = state.consumeTrailingDate()
        let text = state.remainingText

        guard !text.isEmpty else { return nil }

        var summary = "New reminder: “\(text)”"
        if let when { summary += " \(when.summary)" }

        return state.command(
            intent: .createTask(text: text, personIDs: mentioned.map(\.id), day: when?.day),
            summary: summary
        )
    }

    /// `show Maya's family` · `find Maya`.
    private func showCommand(_ state: inout ParseState, verb: String) -> ParsedCommand? {
        state.consumeLeadingWord()
        guard let subject = state.consumePerson() else {
            let rest = state.remainingText
            guard !rest.isEmpty else { return nil }
            return state.command(
                intent: .search(query: rest),
                ambiguities: [.unknownPerson(name: rest)],
                summary: "Search for “\(rest)”"
            )
        }

        if let chart = state.consumeChartKind() {
            return state.command(
                intent: .chart(personID: subject.id, chart: chart),
                summary: "\(subject.fullName)'s \(chart.displayName.lowercased())"
            )
        }

        return state.command(intent: .open(personID: subject.id), summary: "Open \(subject.fullName)")
    }

    /// `add Maya Chen maya@example.com 512-555-0192`.
    private func addCommand(_ state: inout ParseState, verb: String) -> ParsedCommand? {
        state.consumeLeadingWord()
        if state.leadingWord?.lowercased() == "person" { state.consumeLeadingWord() }

        // Details first, so the name is whatever is left rather than whatever came first — which is
        // how `add maya@example.com Maya Chen` still works.
        let details = state.consumeContactDetails()

        // Exhaustive, not partial: `add Theo Ramirez` in a library holding Theo Brandt must create
        // somebody new rather than appending the word "Ramirez" to Brandt.
        if let existing = state.consumePersonIfExhaustive() {
            var fields = details
            fields.name = existing.fullName
            return state.command(
                intent: .addDetails(personID: existing.id, fields: fields),
                summary: "Add \(fields.summaryPhrase) to \(existing.fullName)"
            )
        }

        let name = state.remainingText
        guard !name.isEmpty else { return nil }
        state.claimRemainder(as: .newPerson)

        var fields = details
        fields.name = name
        return state.command(
            intent: .createPerson(fields),
            summary: fields.detailCount == 0
                ? "Create \(name)"
                : "Create \(name) with \(fields.summaryPhrase)"
        )
    }

    /// `invite Family to dinner Saturday at 6`.
    private func inviteCommand(_ state: inout ParseState) -> ParsedCommand? {
        state.consumeLeadingWord()
        guard let group = state.consumeGroup() else {
            let name = state.leadingWord ?? ""
            guard !name.isEmpty else { return nil }
            return state.command(
                intent: .search(query: state.remainingText),
                ambiguities: [.unknownGroup(name: name)],
                summary: "No group called “\(name)”"
            )
        }

        if state.leadingWord?.lowercased() == "to" { state.consumeLeadingWord() }

        let when = state.consumeTrailingDate()
        let title = state.remainingText.isEmpty ? "Get together" : state.remainingText

        guard let when else {
            return state.command(
                intent: .groupAction(groupID: group.id, action: .email),
                ambiguities: [.noDateFound(text: state.remainingText)],
                summary: "Invite \(group.name) — when?"
            )
        }

        return state.command(
            intent: .groupAction(
                groupID: group.id,
                action: .invite(day: when.day, time: when.time, title: title)
            ),
            summary: "Invite \(group.name) (\(group.memberCount)) to \(title) \(when.summary)"
        )
    }

    // MARK: Name-led

    /// `Maya` · `Maya mobile` · `Maya birthday October 12` · `Maya moved to Austin` ·
    /// `Maya son Jack age 6 entering second grade`.
    private func parseNameLed(_ state: inout ParseState) -> ParsedCommand? {
        guard let subject = state.consumePerson() else { return nil }

        // `Maya` alone.
        if state.isExhausted {
            return state.command(intent: .open(personID: subject.id), summary: "Open \(subject.fullName)")
        }

        if let channel = state.consumeChannelWord() {
            return state.command(
                intent: .reveal(personID: subject.id, channel: channel),
                summary: "\(subject.fullName) — \(channel.destinationNoun)"
            )
        }

        if let chart = state.consumeChartKind() {
            return state.command(
                intent: .chart(personID: subject.id, chart: chart),
                summary: "\(subject.fullName)'s \(chart.displayName.lowercased())"
            )
        }

        if let celebration = state.consumeCelebration() {
            return state.command(
                intent: .setCelebration(
                    personID: subject.id,
                    kind: celebration.kind,
                    date: celebration.date
                ),
                summary: "\(subject.fullName)'s \(celebration.kind.displayName.lowercased()): \(celebration.date.displayText)"
            )
        }

        if let relation = state.consumeRelation() {
            let phrase = relation.label ?? relation.kind.displayName
            // Says out loud that nobody was named, rather than reading as a sentence with a hole in
            // it — " is Maya's son" would look like the parser lost a word.
            var summary = relation.relatedName.isEmpty
                ? "A \(phrase) of \(subject.fullName), name not known yet"
                : "\(relation.relatedName) is \(subject.fullName)'s \(phrase)"
            if !relation.observations.isEmpty {
                summary += " · " + relation.observations.map(\.value).joined(separator: ", ")
            }
            return state.command(
                intent: .recordRelation(
                    personID: subject.id,
                    kind: relation.kind,
                    label: relation.label,
                    relatedName: relation.relatedName,
                    observations: relation.observations
                ),
                summary: summary
            )
        }

        if let fact = state.consumeFact() {
            return state.command(
                intent: .recordFact(personID: subject.id, draft: fact),
                summary: "\(subject.fullName) — \(fact.attribute.displayName.lowercased()): \(fact.value)"
            )
        }

        // A name plus contact details, with no verb: `Maya maya@example.com`.
        let details = state.consumeContactDetails()
        if details.detailCount > 0 {
            var fields = details
            fields.name = subject.fullName
            return state.command(
                intent: .addDetails(personID: subject.id, fields: fields),
                summary: "Add \(fields.summaryPhrase) to \(subject.fullName)"
            )
        }

        // A name followed by something unreadable. Opening them is the safe reading: nothing is
        // written, and the rest of the line is still in the field to be corrected.
        return state.command(intent: .open(personID: subject.id), summary: "Open \(subject.fullName)")
    }
}

extension PersonDraftFields {
    public var detailCount: Int {
        emails.count + phones.count
            + (company == nil ? 0 : 1) + (jobTitle == nil ? 0 : 1) + (address == nil ? 0 : 1)
    }

    /// "an email and a phone number" — for the preview line.
    public var summaryPhrase: String {
        var parts: [String] = []
        if !emails.isEmpty { parts.append(emails.count == 1 ? "an email" : "\(emails.count) emails") }
        if !phones.isEmpty { parts.append(phones.count == 1 ? "a phone number" : "\(phones.count) phone numbers") }
        if company != nil { parts.append("a company") }
        if jobTitle != nil { parts.append("a title") }
        if address != nil { parts.append("an address") }

        switch parts.count {
        case 0: return "no details"
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
        }
    }
}
