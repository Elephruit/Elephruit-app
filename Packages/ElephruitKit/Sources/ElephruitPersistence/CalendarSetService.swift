import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// Saved ways of looking at the calendar, and which one is active.
///
/// ### Where each half lives, and why they are not together
/// The **sets** are in the store: somebody composed them, named them, and chose their working hours,
/// and losing that when a Mac is replaced would be losing work. Which set is **active** is in
/// `UserDefaults`: it is a statement about this screen right now, it changes several times a day,
/// and syncing it would mean switching to Family on a laptop while presenting from a Mac in a
/// meeting room. Splitting them that way is the storage matrix's own rule applied twice, not an
/// inconsistency.
@MainActor
public final class CalendarSetService {
    private let context: ModelContext
    private let dateProvider: any DateProvider
    private let defaults: UserDefaults

    static let activeSetKey = "calendar.activeSetID"
    static let suggestionsOfferedKey = "calendar.suggestionsOffered"

    public init(context: ModelContext, dateProvider: any DateProvider, defaults: UserDefaults = .standard) {
        self.context = context
        self.dateProvider = dateProvider
        self.defaults = defaults
    }

    // MARK: - Reading

    /// Every set, in the user's order.
    public func sets() throws(AppError) -> [CalendarSetDefinition] {
        try records().map { $0.asValue() }
    }

    private func records() throws(AppError) -> [CalendarSetRecord] {
        let descriptor = FetchDescriptor<CalendarSetRecord>(sortBy: [SortDescriptor(\.sortOrder)])
        do {
            return try context.fetch(descriptor)
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }
    }

    private func record(id: UUID) throws(AppError) -> CalendarSetRecord? {
        try records().first { $0.id == id }
    }

    /// The set the interface is currently showing, if one is chosen and still exists.
    ///
    /// `nil` means "everything", which is a real state rather than a missing one: a calendar with no
    /// set applied shows every calendar, and that is what a person who has never made a set sees.
    public func activeSet() throws(AppError) -> CalendarSetDefinition? {
        guard let stored = defaults.string(forKey: Self.activeSetKey),
              let id = UUID(uuidString: stored)
        else { return nil }

        guard let found = try record(id: id) else {
            // A set deleted on another device, or by this one. Forget the selection rather than
            // leaving a preference pointing at nothing.
            defaults.removeObject(forKey: Self.activeSetKey)
            return nil
        }
        return found.asValue()
    }

    public func setActive(_ id: UUID?) {
        if let id {
            defaults.set(id.uuidString, forKey: Self.activeSetKey)
        } else {
            defaults.removeObject(forKey: Self.activeSetKey)
        }
    }

    // MARK: - Writing

    @discardableResult
    public func create(_ definition: CalendarSetDefinition) throws(AppError) -> CalendarSetDefinition {
        var definition = definition
        if definition.sortOrder == 0 {
            let existing = try records()
            definition.sortOrder = (existing.map(\.sortOrder).max() ?? 0) + 1
        }

        let record = CalendarSetRecord(id: definition.id, name: definition.name)
        record.absorb(definition, at: dateProvider.now)
        context.insert(record)
        try save()

        return record.asValue()
    }

    public func update(_ definition: CalendarSetDefinition) throws(AppError) {
        guard let record = try record(id: definition.id) else {
            throw .itemNotFound(id: definition.id)
        }
        record.absorb(definition, at: dateProvider.now)
        try save()
    }

    /// Deletes a set. Deletes nothing else — a set owns no event and no person.
    public func delete(id: UUID) throws(AppError) {
        guard let record = try record(id: id) else { return }
        context.delete(record)

        if defaults.string(forKey: Self.activeSetKey) == id.uuidString {
            defaults.removeObject(forKey: Self.activeSetKey)
        }
        try save()
    }

    /// Reorders the whole list from an array of identifiers.
    public func reorder(_ orderedIDs: [UUID]) throws(AppError) {
        let byID = Dictionary(uniqueKeysWithValues: try records().map { ($0.id, $0) })

        for (index, id) in orderedIDs.enumerated() {
            byID[id]?.sortOrder = Double(index)
            byID[id]?.updatedAt = dateProvider.now
        }
        try save()
    }

    // MARK: - Suggestions

    /// Whether the starter sets have been offered yet.
    ///
    /// Offered once, and never created unasked. Four sets appearing in somebody's sidebar on first
    /// launch is an app deciding how they organise their life before it has met them.
    public var hasOfferedSuggestions: Bool {
        get { defaults.bool(forKey: Self.suggestionsOfferedKey) }
        set { defaults.set(newValue, forKey: Self.suggestionsOfferedKey) }
    }

    /// Creates the chosen starter sets, each with the calendars the user picked for it.
    @discardableResult
    public func acceptSuggestions(_ chosen: [CalendarSetDefinition]) throws(AppError) -> [CalendarSetDefinition] {
        var created: [CalendarSetDefinition] = []
        for (index, var definition) in chosen.enumerated() {
            definition.sortOrder = Double(index)
            created.append(try create(definition))
        }
        hasOfferedSuggestions = true
        return created
    }

    private func save() throws(AppError) {
        do {
            try context.save()
        } catch {
            throw .writeFailed(path: "calendar sets", reason: error.localizedDescription)
        }
    }
}
