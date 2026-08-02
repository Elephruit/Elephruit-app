import Foundation

/// The decisions a Quick Jot has collected so far, independent of the words still in the field.
///
/// ### Why this is not ``CaptureDraft``
/// `CaptureDraft` is *the result of parsing one particular string*, and five of its fields say so.
/// ``CaptureDraft/originalText``, ``CaptureDraft/tokens`` and ``CaptureDraft/unresolvedTokens`` carry
/// offsets into a string that stops existing the moment a token is lifted out of the field, and
/// ``CaptureDraft/title``/``CaptureDraft/body`` are rebuilt from the words the parser did not claim,
/// which collapses runs of whitespace and so is deliberately *not* what the user typed. Holding that
/// as mutable state would mean carrying five fields that are stale by design, and the first bug would
/// be somebody reading `tokens` after a lift and getting ranges into a string from two keystrokes ago.
///
/// So this holds decisions and nothing else: no text, no ranges, no derived values. It is what the
/// chips below the field are drawn from, what the four icon menus write into, and what ``CaptureLift``
/// pours settled tokens into. `CaptureDraft` stays exactly what it was — the thing
/// ``CaptureService`` is handed — and ``merged(with:)`` is the one place the two meet.
///
/// ### The rule about kinds
/// Quick Jot promotes a note to a task whenever a decision is made that a note cannot hold: a date, a
/// priority, or a project. That is **a composer rule, not a grammar rule**. The parser deliberately
/// does *not* promote on a priority alone — writing `!high` is emphasis, not a commitment to act, and
/// there is a test saying so. But a user who has *clicked the flag icon* has done something with no
/// other possible meaning, and leaving them with a note that silently discards it would be the
/// interface offering a control that does nothing. Promotion therefore lives in the mutators here,
/// where a decision is being recorded, and nowhere else.
public struct QuickJotDraft: Sendable, Hashable {
    /// What will be created. Starts as a note, the same default the parser uses.
    public private(set) var kind: ItemKind

    /// Whether ``kind`` was chosen by the user rather than inferred.
    ///
    /// It exists for one sequence that is otherwise unfixable: tick Task, then paste a URL. The text
    /// now parses as a bookmark, and without this the checkbox unticks itself under the user's hands.
    /// An explicit choice outranks anything the words say.
    public private(set) var kindIsExplicit: Bool

    /// Tag slugs, already normalised, in the order they were added.
    public private(set) var tagSlugs: [String]

    /// The project, area or goal this should land in, as text — resolution needs the store.
    public private(set) var projectHint: String?

    /// The people to mention, in the order they were added.
    public private(set) var personHints: [String]

    /// A deadline. It can become overdue.
    public private(set) var dueDate: DateExpression?

    /// The time of day given alongside ``dueDate``.
    public private(set) var dueTime: TimeOfDay?

    /// A start date. It brings the item into Today and never becomes overdue.
    public private(set) var followDate: DateExpression?

    public private(set) var priority: Priority?

    /// A URL, which makes the capture a bookmark. Only ever set from the text — there is no icon for
    /// it, because there is nothing to choose.
    public private(set) var url: URL?

    public init(kind: ItemKind = .note, kindIsExplicit: Bool = false) {
        self.kind = kind
        self.kindIsExplicit = kindIsExplicit
        self.tagSlugs = []
        self.projectHint = nil
        self.personHints = []
        self.dueDate = nil
        self.dueTime = nil
        self.followDate = nil
        self.priority = nil
        self.url = nil
    }

    /// Whether any decision has been recorded — what the chip row asks before drawing itself.
    public var isEmpty: Bool {
        tagSlugs.isEmpty && projectHint == nil && personHints.isEmpty
            && dueDate == nil && followDate == nil && priority == nil && url == nil
    }

    /// The deadline and its time together, when there is one.
    public var dueInterpretation: DateInterpretation? {
        dueDate.map { DateInterpretation(day: $0, time: dueTime) }
    }

    // MARK: - Recording decisions

    /// The user said which of the two this is.
    public mutating func choose(_ kind: ItemKind) {
        self.kind = kind
        kindIsExplicit = true
    }

    /// Promotes a note to a task, because something has been recorded that a note cannot hold.
    ///
    /// Deliberately leaves ``kindIsExplicit`` alone. Being promoted is not the user choosing, and a
    /// promoted task must not then start outranking a URL the way a ticked box does.
    private mutating func promoteIfNeeded() {
        if kind == .note { kind = .task }
    }

    public mutating func addTag(_ slug: String) {
        let normalised = TextNormalizer.slug(slug)
        guard TextNormalizer.isValidSlug(normalised) else { return }

        // The tag picker and the typed grammar must agree about the handful of `#` words that
        // describe what an item is. In particular, choosing `bug` from the tag menu must create a
        // real bug (with severity, verification and reporting), not a task that merely wears a
        // decorative "bug" label.
        if let kind = CaptureKindWords.kind(for: normalised) {
            choose(kind)
            return
        }

        guard !tagSlugs.contains(normalised) else { return }
        tagSlugs.append(normalised)
    }

    public mutating func removeTag(_ slug: String) {
        tagSlugs.removeAll { $0 == slug }
    }

    public mutating func addPerson(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Folded rather than exact, so `@sarah` typed after picking "Sarah" from the menu does not
        // mention her twice. `CaptureService` would resolve both to the same person and link it twice.
        let folded = TextNormalizer.foldedForMatching(trimmed)
        guard !personHints.contains(where: { TextNormalizer.foldedForMatching($0) == folded }) else { return }
        personHints.append(trimmed)
    }

    public mutating func removePerson(_ name: String) {
        personHints.removeAll { $0 == name }
    }

    public mutating func setProject(_ hint: String?) {
        let trimmed = hint?.trimmingCharacters(in: .whitespaces)
        projectHint = (trimmed?.isEmpty ?? true) ? nil : trimmed
        if projectHint != nil { promoteIfNeeded() }
    }

    public mutating func setDue(_ interpretation: DateInterpretation?) {
        dueDate = interpretation?.day
        dueTime = interpretation?.time
        if dueDate != nil { promoteIfNeeded() }
    }

    public mutating func setFollow(_ expression: DateExpression?) {
        followDate = expression
        if followDate != nil { promoteIfNeeded() }
    }

    public mutating func setPriority(_ priority: Priority?) {
        self.priority = priority
        if priority != nil { promoteIfNeeded() }
    }

    public mutating func setURL(_ url: URL?) {
        self.url = url
    }

    // MARK: - Taking in what was lifted out of the field

    /// Folds the tokens ``CaptureLift`` removed from the text into these decisions.
    ///
    /// Every field goes through the mutators above rather than being assigned, so a lifted `due:`
    /// promotes the kind by exactly the same rule a clicked flag does.
    ///
    /// ### Why the newcomer wins here, and loses in ``merged(with:)``
    /// A lift happens because the user *just typed* the token and then moved off it. Somebody who
    /// picked Today from the menu and then wrote `due:friday` has changed their mind, and a chip that
    /// refused to budge would be the interface arguing with them. So the last writer wins.
    ///
    /// That is safe only because a lift is flushed before any menu is opened, which is what stops the
    /// mirror-image sequence from going wrong: type `due:friday`, leave it sitting in the sentence,
    /// then pick Today. The stale text becomes a chip *first*, and the click then replaces it — so
    /// the later act still wins, and nothing is replayed out of order.
    ///
    /// ``merged(with:)`` is the opposite because it is looking at something else: words that could
    /// never be lifted at all. Those are leftovers, not decisions, and they defer.
    public mutating func apply(_ lifted: CaptureDraft) {
        for slug in lifted.tagSlugs { addTag(slug) }
        for name in lifted.personHints { addPerson(name) }

        if let hint = lifted.projectHint { setProject(hint) }
        if let interpretation = lifted.dueInterpretation { setDue(interpretation) }
        if let follow = lifted.followDate { setFollow(follow) }
        if let priority = lifted.priority { setPriority(priority) }
        if let url = lifted.url { setURL(url) }

        // A `- ` prefix is the one lift with no token behind it, so the lifter reports it as a kind.
        if !kindIsExplicit, lifted.kind != .note { kind = lifted.kind }
    }

    // MARK: - Becoming something that can be saved

    /// Combines these decisions with a fresh parse of whatever is still in the fields.
    ///
    /// ### Why there is a residual parse at all
    /// Lifting is allowed to be late. A token only leaves the text once it has plainly stopped
    /// growing, so at the moment Save is pressed there may still be a `due:friday` sitting in the
    /// sentence that never became a chip. Parsing what is left and merging it here is what makes
    /// lateness harmless: an unlifted token is *un-chipped*, never *lost*. Without this, every gap in
    /// the lift rule would be a silently dropped instruction.
    ///
    /// Precedence throughout is **decisions over text**. A chip is something the user placed; words
    /// in the field are a proposal that lands only if nothing has claimed the slot. The two
    /// collection fields union instead, because `#admin` in the text and `#urgent` from the menu are
    /// not competing answers to one question.
    public func merged(with residual: CaptureDraft) -> CaptureDraft {
        var merged = residual

        merged.kind = mergedKind(with: residual)

        merged.tagSlugs = tagSlugs + residual.tagSlugs.filter { !tagSlugs.contains($0) }

        let known = Set(personHints.map(TextNormalizer.foldedForMatching))
        merged.personHints = personHints
            + residual.personHints.filter { !known.contains(TextNormalizer.foldedForMatching($0)) }

        merged.projectHint = projectHint ?? residual.projectHint

        // The day and its time move together. Taking the day from a chip and the time from the text
        // would build a deadline neither the chip nor the sentence ever said.
        if let dueDate {
            merged.dueDate = dueDate
            merged.dueTime = dueTime
        }

        merged.followDate = followDate ?? residual.followDate
        merged.priority = priority ?? residual.priority
        merged.url = url ?? residual.url

        // Last, because the fields above are what decide whether a note can still be one. A residual
        // `due:` that was never lifted has to promote here, since it never passed through a mutator.
        if merged.kind == .note, !kindIsExplicit,
           merged.dueDate != nil || merged.followDate != nil || merged.projectHint != nil {
            merged.kind = .task
        }

        return merged
    }

    /// Which kind wins.
    ///
    /// An explicit choice beats everything. Failing that, a kind these decisions already moved away
    /// from the default beats the text — somebody who set a deadline and then pasted a URL has made a
    /// task with a link in it, not a bookmark that cannot hold the deadline. Only a draft with no
    /// opinion at all lets the words decide.
    private func mergedKind(with residual: CaptureDraft) -> ItemKind {
        if kindIsExplicit { return kind }
        if kind != .note { return kind }
        return residual.kind
    }
}
