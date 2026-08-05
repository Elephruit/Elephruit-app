import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// The app-wide working day: reading it, writing it, and never being unable to answer.
///
/// ### Why every read succeeds
/// The question this service answers — *when do you work* — is asked by the briefing on every
/// assembly, several times a screen. A store error there must not become a page that will not draw,
/// so an unreadable table reads as "nobody has said" and the caller falls back to the assumed hours.
/// That is the same answer the app gave before this table existed, which makes failure a return to
/// the previous behaviour rather than a new one.
///
/// ### The singleton, and how two of them heal
/// CloudKit permits no unique constraints, so two devices that each write before either syncs will
/// each create a row. Reading takes the most recently updated, which is deterministic and is also
/// the answer a person would expect: the last decision wins. Writing folds the extras away, so the
/// duplicate survives exactly until the next time somebody changes their hours.
@MainActor
public final class WorkdayService {
    private let context: ModelContext
    private let dateProvider: any DateProvider

    public init(context: ModelContext, dateProvider: any DateProvider) {
        self.context = context
        self.dateProvider = dateProvider
    }

    /// The app-wide default, or `nil` when nobody has set one.
    ///
    /// `nil` and "nine to five" are deliberately different answers. The first is a question the user
    /// has never been asked and the interface should say so; the second is a decision they made that
    /// happens to match the assumption.
    public func appDefault() -> WorkingHours? {
        current()?.asValue()
    }

    /// Sets the app-wide working day, creating the record on first use.
    ///
    /// Nothing writes this on launch. A row exists because somebody opened Settings and said when
    /// they work, which is what makes the absence of a row meaningful.
    public func setAppDefault(_ hours: WorkingHours) throws(AppError) {
        let now = dateProvider.now
        let record = current() ?? {
            let fresh = WorkdaySettingsRecord()
            fresh.createdAt = now
            context.insert(fresh)
            return fresh
        }()

        record.absorb(hours, at: now)

        // Anything else is a row another device wrote before it had seen this one. The winner has
        // just been rewritten, so the losers carry nothing that is not already said better.
        for extra in all() where extra.id != record.id {
            context.delete(extra)
        }

        do {
            try context.save()
        } catch {
            throw .writeFailed(path: "workday hours", reason: error.localizedDescription)
        }
    }

    /// Forgets the app-wide default, returning the app to its assumption.
    public func clearAppDefault() throws(AppError) {
        let records = all()
        guard !records.isEmpty else { return }
        for record in records { context.delete(record) }

        do {
            try context.save()
        } catch {
            throw .writeFailed(path: "workday hours", reason: error.localizedDescription)
        }
    }

    /// The hours to use, and where they came from.
    ///
    /// The whole resolution order in one place, so that the briefing, the free-slot arithmetic, the
    /// settings screen and anything that proposes a block cannot disagree about when the day ends.
    /// A set overrides the app default while it is active — switching into Family is switching what
    /// "the working day" means for as long as you are in it — and the assumption is what is left.
    public func resolved(activeSet: CalendarSetDefinition?) -> WorkdayHours {
        if let activeSet {
            return WorkdayHours(hours: activeSet.workingHours, source: .calendarSet(name: activeSet.name))
        }
        if let stored = appDefault() {
            return WorkdayHours(hours: stored, source: .appDefault)
        }
        return .assumed
    }

    // MARK: - Rows

    private func current() -> WorkdaySettingsRecord? {
        all().max { $0.updatedAt < $1.updatedAt }
    }

    private func all() -> [WorkdaySettingsRecord] {
        (try? context.fetch(FetchDescriptor<WorkdaySettingsRecord>())) ?? []
    }
}
