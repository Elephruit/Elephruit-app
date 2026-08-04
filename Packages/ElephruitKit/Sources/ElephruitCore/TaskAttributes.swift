import Foundation

/// Every answer the *When* control can give.
///
/// ### Why the choices are a value rather than five closures in a popover
/// Because of what they must never do. A start date says *do not ask me until then* and can never
/// make a task late; a deadline is an outside commitment and is the only date that can. The whole
/// scheduling model rests on that distinction, so "no route through this control writes a deadline"
/// is a property worth being able to state and assert — and a property spread across five button
/// actions inside a `body` is one that can only be checked by reading them all and hoping.
///
/// Named here, applied by ``ElephruitPersistence/ReminderLifecycleService/apply(_:to:)``, and walked case by case
/// in `TaskWhenChoiceTests`.
public enum TaskWhenChoice: Sendable, Hashable {
    /// On today's plan.
    case today

    /// Today, in the back half of it.
    case thisEvening

    /// Parked on purpose. Leaves every count and cannot be late.
    case someday

    /// Available from this day onwards.
    case startingOn(Date)

    /// No start date, and not parked.
    case clear

    /// One of each case, for a caller that has to cover all five.
    ///
    /// The day is a parameter rather than a default, and `CaseIterable` is deliberately not
    /// conformed to, because ``startingOn(_:)`` has no canonical value. A synthesised `allCases`
    /// would have to invent one — `Date()` was the first attempt — and that makes the list depend on
    /// the wall clock, which is how the first version of this failed against a fixed-clock store.
    public static func allChoices(startingOn day: Date) -> [TaskWhenChoice] {
        [.today, .thisEvening, .someday, .startingOn(day), .clear]
    }
}

/// Which of a task's six attributes are values and which are still offers.
///
/// ### Why this is a function over facts rather than a view
/// The rule it encodes — **a button appears if and only if its value is absent** — is the thing that
/// keeps the task card to one line of controls instead of six empty rows. A rule of that shape decays
/// into "mostly" the moment it lives inside a `body`, because the sixth case is the one somebody
/// forgets while moving code around. Here it is a value, and there is a suite that walks all six.
///
/// It reads ``TaskFacts`` and nothing else, so it runs without a store, without a view, and without
/// SwiftUI.
public enum TaskAttributes {
    /// The six, plus the two that are only ever chips.
    ///
    /// ``reminder`` and ``waiting`` have no button of their own: a reminder is set from inside
    /// *When*, and waiting is set from the context menu, because both are answers to a question
    /// another control already asks. They still appear as chips, because they are still true.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case when
        case tags
        case checklist
        case deadline
        case people
        case priority
        case reminder
        case waiting

        /// The six that are offered as buttons when absent, in the order they are drawn.
        public static let offered: [Kind] = [.when, .tags, .checklist, .deadline, .people, .priority]

        public var hint: String {
            switch self {
            case .when: "When you will get to this. Never a deadline."
            case .tags: "Words you file by, shared with the rest of the library."
            case .checklist: "Short steps inside this one action."
            case .deadline: "The date this must be finished by. The only date that can make it overdue."
            case .people: "Who this involves. It appears on their page too."
            case .priority: "How much this matters relative to everything else you could do instead."
            case .reminder: "A time this reminder appears."
            case .waiting: "Somebody else has the next move."
            }
        }
    }

    /// A value, ready to draw.
    ///
    /// Carries no colour of its own — ``tintName`` names one of a small set the surface resolves —
    /// so this stays free of SwiftUI and testable.
    public struct Chip: Sendable, Hashable, Identifiable {
        public var kind: Kind
        public var symbolName: String
        public var text: String

        /// Whether the chip offers a way to undo itself. Everything does except a checklist, which
        /// is cleared by removing its steps.
        public var isClearable: Bool

        /// `nil` is the quiet default. A colour here means the value has *arrived* — an overdue
        /// deadline, a deadline today — and never merely that it exists.
        public var tintName: TintName?

        public var hint: String { kind.hint }
        public var id: Kind { kind }

        public init(
            kind: Kind,
            symbolName: String,
            text: String,
            isClearable: Bool = true,
            tintName: TintName? = nil
        ) {
            self.kind = kind
            self.symbolName = symbolName
            self.text = text
            self.isClearable = isClearable
            self.tintName = tintName
        }
    }

    /// The colours a chip may ask for, named rather than spelled.
    public enum TintName: String, Sendable, Hashable {
        /// A date that has arrived or passed. Amber, never red.
        case dueToday
    }

    /// The whole answer for one task.
    public struct Layout: Sendable, Hashable {
        public var chips: [Chip]
        public var buttons: [Kind]

        public init(chips: [Chip], buttons: [Kind]) {
            self.chips = chips
            self.buttons = buttons
        }
    }

    /// The names ``TaskFacts`` does not carry.
    ///
    /// Facts hold person *identifiers*, deliberately: they are computed over ten thousand tasks and
    /// resolving a name per task per evaluation is a traversal nobody asked for. A chip needs the
    /// name, so the surface that already has the store hands it in.
    public struct Names: Sendable, Hashable {
        public var people: [String]
        public var waitingOn: String?

        public init(people: [String] = [], waitingOn: String? = nil) {
            self.people = people
            self.waitingOn = waitingOn
        }
    }

    /// Splits a task's six attributes into what it has and what it is offered.
    ///
    /// - Parameter offersChecklist: whether this surface has anywhere to put steps. A surface that
    ///   already has a step field below does not also want a button that reveals one.
    public static func layout(
        for facts: TaskFacts,
        names: Names = Names(),
        now: Date,
        calendar: Calendar,
        offersChecklist: Bool = true
    ) -> Layout {
        var chips: [Chip] = []
        var present: Set<Kind> = []

        // MARK: When
        //
        // One chip for the whole question, because Someday, a start date and a place in today's plan
        // are three answers to it and a task can only have given one. Showing "Someday" beside
        // "Starts 4 Aug" would be showing a contradiction the invariants do not permit.
        if facts.isSomeday {
            chips.append(Chip(kind: .when, symbolName: "archivebox", text: "Someday"))
            present.insert(.when)
        } else if let start = facts.startAt {
            let arrived = calendar.startOfDay(for: start) <= calendar.startOfDay(for: now)
            chips.append(
                Chip(
                    kind: .when,
                    symbolName: "calendar",
                    text: arrived
                        ? "Started " + Self.dayText(start, calendar: calendar)
                        : "Starts " + Self.dayText(start, calendar: calendar)
                )
            )
            present.insert(.when)
        } else if let committed = facts.todayCommittedOn,
                  calendar.isDate(committed, inSameDayAs: now) {
            chips.append(
                Chip(
                    kind: .when,
                    symbolName: "star",
                    text: facts.isLaterToday ? "This Evening" : "Today"
                )
            )
            present.insert(.when)
        }

        // MARK: Deadline
        if let deadline = facts.deadlineAt {
            let urgency = facts.deadlineUrgency(on: now, calendar: calendar)
            chips.append(
                Chip(
                    kind: .deadline,
                    symbolName: "flag.pattern.checkered",
                    text: Self.deadlineText(deadline, urgency: urgency, calendar: calendar),
                    // Amber only once the date is here or gone. A deadline three weeks out is a
                    // fact, not news, and a list where every deadline is coloured is a list where
                    // none of them is.
                    tintName: Self.isPressing(urgency) ? .dueToday : nil
                )
            )
            present.insert(.deadline)
        }

        // MARK: Reminder
        if let reminder = facts.reminderAt {
            chips.append(
                Chip(
                    kind: .reminder,
                    symbolName: "bell",
                    text: facts.reminderIsTimed
                        ? reminder.formatted(date: .omitted, time: .shortened)
                        : Self.dayText(reminder, calendar: calendar)
                )
            )
            present.insert(.reminder)
        }

        // MARK: Tags
        if !facts.tagSlugs.isEmpty {
            chips.append(
                Chip(
                    kind: .tags,
                    symbolName: "tag",
                    text: facts.tagSlugs.sorted().joined(separator: ", ")
                )
            )
            present.insert(.tags)
        }

        // MARK: People
        if !facts.relatedPersonIDs.isEmpty {
            chips.append(
                Chip(
                    kind: .people,
                    symbolName: "person.2",
                    // One name, or a count. Two names rarely fit and never help — the same rule the
                    // people picker uses for its own chip.
                    text: names.people.count == 1
                        ? names.people[0]
                        : "\(facts.relatedPersonIDs.count) people"
                )
            )
            present.insert(.people)
        }

        // MARK: Waiting
        //
        // A chip and never a button: waiting is set by saying who you are waiting on, which is a
        // different question from "does this task have a waiting flag".
        if facts.lifecycle == .waiting {
            chips.append(
                Chip(
                    kind: .waiting,
                    symbolName: "hourglass",
                    text: names.waitingOn.map { "Waiting on \($0)" } ?? "Waiting"
                )
            )
            present.insert(.waiting)
        }

        // MARK: Checklist
        if facts.checklistTotal > 0 {
            chips.append(
                Chip(
                    kind: .checklist,
                    symbolName: "checklist",
                    text: "\(facts.checklistCompleted)/\(facts.checklistTotal)",
                    // Cleared by removing its steps, one at a time, where they are. A single ✕ that
                    // silently threw away six of them is not an undo anybody meant to ask for.
                    isClearable: false
                )
            )
            present.insert(.checklist)
        }

        // MARK: Priority
        //
        // `.normal` is the absence of a priority rather than a middle value, which is why it is the
        // one case that draws no chip.
        if facts.priority != .normal {
            chips.append(
                Chip(
                    kind: .priority,
                    symbolName: facts.priority.symbolName ?? "exclamationmark",
                    text: facts.priority.displayName
                )
            )
            present.insert(.priority)
        }

        let buttons = Kind.offered.filter { kind in
            guard !present.contains(kind) else { return false }
            return kind == .checklist ? offersChecklist : true
        }

        return Layout(chips: chips, buttons: buttons)
    }

    /// Amber only once the date is here or gone.
    private static func isPressing(_ urgency: DeadlineUrgency) -> Bool {
        switch urgency {
        case .overdue, .today: true
        case .none, .distant, .soon: false
        }
    }

    private static func deadlineText(
        _ deadline: Date,
        urgency: DeadlineUrgency,
        calendar: Calendar
    ) -> String {
        switch urgency {
        case .overdue(let days): days == 1 ? "1 day late" : "\(days) days late"
        case .today: "Due today"
        case .soon(let days): days == 1 ? "Due tomorrow" : "Due in \(days) days"
        case .none, .distant: "Due " + dayText(deadline, calendar: calendar)
        }
    }

    private static func dayText(_ date: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle().day().month(.abbreviated)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}
