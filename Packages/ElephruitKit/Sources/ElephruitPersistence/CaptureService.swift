import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// Turning a capture into an item.
///
/// ### Why this is not in the capture panel
/// Quick Capture must eventually be reachable without the app being frontmost — from an App Intent,
/// from the Services menu, from a global hotkey. None of those can construct a SwiftUI view, so the
/// path from *text the user typed* to *item in the library* cannot run inside one.
///
/// So it lives here: a plain function over ``CaptureDraft`` with no UI in its signature. The panel
/// calls it, and so will everything else. Testable directly, without a window.
@MainActor
public struct CaptureService {
    private let items: any ItemRepository
    private let context: ModelContext
    private let dateProvider: any DateProvider

    public init(items: any ItemRepository, context: ModelContext, dateProvider: any DateProvider) {
        self.items = items
        self.context = context
        self.dateProvider = dateProvider
    }

    /// Captures a line of text, parsing its inline grammar.
    ///
    /// The whole entry point, in one call: `try capture(text: "Call Sarah #urgent !tomorrow")`.
    @discardableResult
    public func capture(text: String) throws(AppError) -> Item? {
        let draft = CaptureParser.parse(text, knowing: try vocabulary())
        guard !draft.isEmpty else { return nil }
        return try capture(draft)
    }

    /// The names `>` and `@` can spell out without quotes.
    ///
    /// Read here rather than in the parser, for the same reason resolution is: it needs the store.
    /// Every door into Quick Jot asks for this and hands it to the same parser, so the field, the
    /// interpretation row and the saved item cannot disagree about where a name ends.
    public func vocabulary() throws(AppError) -> CaptureVocabulary {
        var containers = ItemQuery()
        containers.kinds = [.project, .area, .goal]

        var people = ItemQuery()
        people.kinds = [.person]

        return CaptureVocabulary(
            projects: try items.items(matching: containers).map(\.title),
            people: try items.items(matching: people).map(\.title)
        )
    }

    /// Captures an already-parsed draft.
    ///
    /// Resolution of the hints — a project name, a person's name — happens here rather than in the
    /// parser, because it needs the store and parsing must not.
    @discardableResult
    public func capture(_ draft: CaptureDraft) throws(AppError) -> Item {
        var itemDraft = ItemDraft(
            kind: draft.kind,
            title: draft.title,
            body: draft.body,
            tagSlugs: draft.tagSlugs,
            source: .quickCapture,
            url: draft.url
        )

        // An unresolvable project hint is not an error: the item lands in the Inbox, which is exactly
        // where an unfiled capture belongs.
        if let hint = draft.projectHint, let container = try resolveContainer(named: hint) {
            itemDraft.parentID = container.id
        }

        if let interpretation = draft.dueInterpretation, draft.kind.supportedFields.contains(.dueDate) {
            itemDraft.dueAt = interpretation.resolve(using: dateProvider)
        }

        // `follow:` is a start date, not a deadline. It brings the item into Today on that day and
        // never becomes overdue — the whole reason it is a separate token from `due:`.
        if let expression = draft.followDate, draft.kind.supportedFields.contains(.deferDate) {
            itemDraft.deferUntil = expression.resolve(using: dateProvider)
        }

        if let priority = draft.priority, draft.kind.supportedFields.contains(.priority) {
            itemDraft.priority = priority
        }

        let item = try items.create(itemDraft)
        try linkPeople(named: draft.personHints, from: item)

        // Capture returns with nothing pending.
        //
        // `items.create` saves, but the links inserted after it did not, and were left to autosave.
        // That is a bet that the process outlives the capture — true in the app, and not true of an
        // App Intent invoked from Spotlight, whose process can exit the moment `perform()` returns.
        // The part that went missing was the person link, which is the whole point of typing
        // `@Sarah`.
        try commit()

        return item
    }

    /// Finds a container matching a `>hint`, exactly first and then by prefix.
    ///
    /// Prefix rather than fuzzy: `>Q3` should find "Q3 Launch", but nothing should guess wildly at
    /// what a two-letter hint meant.
    public func resolveContainer(named hint: String) throws(AppError) -> Item? {
        let folded = TextNormalizer.foldedForMatching(hint)
        guard !folded.isEmpty else { return nil }

        var query = ItemQuery()
        query.kinds = [.project, .area, .goal]

        let candidates = try items.items(matching: query)

        return candidates.first { TextNormalizer.foldedForMatching($0.title) == folded }
            ?? candidates.first { TextNormalizer.foldedForMatching($0.title).hasPrefix(folded) }
    }

    /// Links the people named with `@`, creating any that do not exist.
    ///
    /// Creating them is deliberate: writing `@Sarah` is a statement that Sarah is someone you track,
    /// and making the user create the record separately would mean the graph does not reflect what
    /// they wrote.
    private func linkPeople(named names: [String], from item: Item) throws(AppError) {
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let person = try resolveOrCreatePerson(named: trimmed)
            context.insert(
                ItemLink(kind: .mentions, source: item, target: person, createdAt: dateProvider.now)
            )
        }
    }

    private func resolveOrCreatePerson(named name: String) throws(AppError) -> Item {
        var query = ItemQuery()
        query.kinds = [.person]

        let folded = TextNormalizer.foldedForMatching(name)
        if let match = try items.items(matching: query)
            .first(where: { TextNormalizer.foldedForMatching($0.title) == folded }) {
            return match
        }

        return try items.create(
            ItemDraft(kind: .person, title: name, source: ItemSource(kind: .quickCapture, identifier: "mention"))
        )
    }

    private func commit() throws(AppError) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            throw .writeFailed(path: "store", reason: error.localizedDescription)
        }
    }
}
