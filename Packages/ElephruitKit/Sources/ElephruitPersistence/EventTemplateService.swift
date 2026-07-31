import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// Saved event shapes, and the order somebody actually reaches for them in.
@MainActor
public final class EventTemplateService {
    private let context: ModelContext
    private let dateProvider: any DateProvider

    public init(context: ModelContext, dateProvider: any DateProvider) {
        self.context = context
        self.dateProvider = dateProvider
    }

    // MARK: - Reading

    /// Every template, in the user's order.
    public func templates() throws(AppError) -> [EventTemplate] {
        try records().map { $0.asValue() }
    }

    /// The templates worth putting in a menu, most recently useful first.
    ///
    /// Ranked by use rather than left in creation order, because a list of fifteen templates in the
    /// order they happened to be made is a list nobody reads to the bottom of. Ties fall back to the
    /// user's own ordering so the ranking never looks arbitrary.
    public func mostUsed(limit: Int = 6) throws(AppError) -> [EventTemplate] {
        let ranked = try templates().sorted { left, right in
            if left.useCount != right.useCount { return left.useCount > right.useCount }
            if let leftUsed = left.lastUsedAt, let rightUsed = right.lastUsedAt, leftUsed != rightUsed {
                return leftUsed > rightUsed
            }
            return left.sortOrder < right.sortOrder
        }
        return Array(ranked.prefix(limit))
    }

    private func records() throws(AppError) -> [EventTemplateRecord] {
        let descriptor = FetchDescriptor<EventTemplateRecord>(sortBy: [SortDescriptor(\.sortOrder)])
        do {
            return try context.fetch(descriptor)
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }
    }

    private func record(id: UUID) throws(AppError) -> EventTemplateRecord? {
        try records().first { $0.id == id }
    }

    public func template(id: UUID) throws(AppError) -> EventTemplate? {
        try record(id: id)?.asValue()
    }

    // MARK: - Writing

    @discardableResult
    public func create(_ template: EventTemplate) throws(AppError) -> EventTemplate {
        var template = template
        if template.sortOrder == 0 {
            template.sortOrder = (try records().map(\.sortOrder).max() ?? 0) + 1
        }

        let record = EventTemplateRecord(id: template.id, name: template.name)
        record.absorb(template, at: dateProvider.now)
        context.insert(record)
        try save()

        return record.asValue()
    }

    public func update(_ template: EventTemplate) throws(AppError) {
        guard let record = try record(id: template.id) else { throw .itemNotFound(id: template.id) }
        record.absorb(template, at: dateProvider.now)
        try save()
    }

    public func delete(id: UUID) throws(AppError) {
        guard let record = try record(id: id) else { return }
        context.delete(record)
        try save()
    }

    /// Records that a template produced an event.
    ///
    /// Separate from ``update(_:)`` so that using a template does not have to round-trip its whole
    /// value — and so that a use recorded while the editor happens to be open cannot overwrite what
    /// the user is typing into it.
    public func noteUse(of id: UUID) throws(AppError) {
        guard let record = try record(id: id) else { return }
        record.noteUse(at: dateProvider.now)
        try save()
    }

    public func reorder(_ orderedIDs: [UUID]) throws(AppError) {
        let byID = Dictionary(uniqueKeysWithValues: try records().map { ($0.id, $0) })
        for (index, id) in orderedIDs.enumerated() {
            byID[id]?.sortOrder = Double(index)
            byID[id]?.updatedAt = dateProvider.now
        }
        try save()
    }

    private func save() throws(AppError) {
        do {
            try context.save()
        } catch {
            throw .writeFailed(path: "event templates", reason: error.localizedDescription)
        }
    }
}
