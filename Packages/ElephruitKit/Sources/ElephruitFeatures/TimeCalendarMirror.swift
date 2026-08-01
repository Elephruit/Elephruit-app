import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Observation
import SwiftUI

/// Writes finished stretches of tracked time into a calendar.
///
/// ### What this is for
/// A calendar is the one surface that already answers *what was I doing at three o'clock*, and it
/// answers it on every device and to anybody reconstructing a week. Mirroring puts the day that
/// actually happened beside the day that was planned, which is a comparison nothing else in this app
/// can make.
///
/// ### What it will not do
/// It is **outbound only and never a source of truth**. Nothing is ever read back: an event edited
/// in Calendar.app does not change the entry it came from, and it never will, because the entry is
/// the record and the event is a copy. The alternative — two writable copies of the same hour — is
/// exactly the failure `docs/03-storage-matrix.md` exists to prevent.
///
/// It also never writes anything private. The rules for that live in
/// ``ElephruitCore/TimeMirroring``, where they are a property of a type rather than a habit here.
///
/// ### Why it is off, and why turning it off does not tidy up
/// Off until asked for, like every other integration in this app. And turning it *off* leaves every
/// event it wrote in place, because deleting a month of somebody's calendar is a decision that
/// deserves its own button and its own confirmation — not a side effect of a toggle.
@Observable
@MainActor
public final class TimeCalendarMirror {
    private let entries: any TimeEntryRepository
    private let calendar: CalendarService
    private let dateProvider: any DateProvider
    private let defaults: UserDefaults

    private static let enabledKey = "time.mirror.enabled"
    private static let calendarKey = "time.mirror.calendarIdentifier"
    private static let subjectKey = "time.mirror.includesSubject"
    private static let tagsKey = "time.mirror.includesTags"
    private static let minimumKey = "time.mirror.minimumDuration"
    private static let busyKey = "time.mirror.marksAsBusy"

    /// How many events this app has written and still knows about.
    public private(set) var mirroredCount = 0

    /// The last write that failed, so the user is told rather than left with a silent gap.
    public private(set) var lastFailure: CalendarWriteFailure?

    /// Set while a backfill or a sweep is running, so a button can say so.
    public private(set) var isWorking = false

    public init(
        entries: any TimeEntryRepository,
        calendar: CalendarService,
        dateProvider: any DateProvider,
        defaults: UserDefaults = .standard
    ) {
        self.entries = entries
        self.calendar = calendar
        self.dateProvider = dateProvider
        self.defaults = defaults
    }

    // MARK: - Settings

    public var policy: TimeMirrorPolicy {
        get {
            TimeMirrorPolicy(
                isEnabled: defaults.bool(forKey: Self.enabledKey),
                calendarIdentifier: defaults.string(forKey: Self.calendarKey),
                includesSubject: defaults.object(forKey: Self.subjectKey) as? Bool ?? true,
                includesTags: defaults.bool(forKey: Self.tagsKey),
                minimumDuration: defaults.object(forKey: Self.minimumKey) as? Double ?? 5 * 60,
                marksAsBusy: defaults.bool(forKey: Self.busyKey)
            )
        }
        set {
            defaults.set(newValue.isEnabled, forKey: Self.enabledKey)
            defaults.set(newValue.calendarIdentifier, forKey: Self.calendarKey)
            defaults.set(newValue.includesSubject, forKey: Self.subjectKey)
            defaults.set(newValue.includesTags, forKey: Self.tagsKey)
            defaults.set(newValue.minimumDuration, forKey: Self.minimumKey)
            defaults.set(newValue.marksAsBusy, forKey: Self.busyKey)
        }
    }

    /// Whether anything can be written at all: the calendar is on, it can be written to, and a
    /// destination has been picked.
    public var isReady: Bool {
        guard calendar.isEnabled, policy.isUsable else { return false }
        return destination != nil
    }

    /// The calendar written to, if it still exists and still allows writing.
    ///
    /// Resolved every time rather than cached: a calendar can be deleted, unsubscribed, or turned
    /// read-only between one entry and the next, and a cached answer would turn that into a stream
    /// of failures nobody can explain.
    public var destination: CalendarInfo? {
        guard let identifier = policy.calendarIdentifier else { return nil }
        guard let found = calendar.calendar(withIdentifier: identifier), found.allowsModification else {
            return nil
        }
        return found
    }

    public func clearFailure() {
        lastFailure = nil
    }

    // MARK: - One entry

    /// Brings the calendar into line with one entry.
    ///
    /// Called when a timer stops, when an entry is edited, and when one is deleted. Does nothing at
    /// all when the mirror is off, which is the common case and has to cost nothing.
    public func synchronise(entryID: UUID) async {
        guard isReady, let calendarIdentifier = policy.calendarIdentifier else { return }
        guard let entry = try? entries.entry(id: entryID) else { return }

        await apply(to: entry, calendarIdentifier: calendarIdentifier)
    }

    /// Brings the calendar into line with everything finished in a window.
    ///
    /// What *Mirror this period now* runs. Sequential rather than concurrent: EventKit writes are
    /// serialised anyway, and a hundred parallel calls to it produce a hundred chances to interleave
    /// with the user's own calendar app.
    @discardableResult
    public func backfill(_ range: Range<Date>) async -> Int {
        guard isReady, let calendarIdentifier = policy.calendarIdentifier else { return 0 }
        guard let candidates = try? entries.finishedEntries(in: range) else { return 0 }

        isWorking = true
        defer { isWorking = false }

        var written = 0
        for entry in candidates {
            let before = entry.mirroredEventIdentifier
            await apply(to: entry, calendarIdentifier: calendarIdentifier)
            if before != entry.mirroredEventIdentifier { written += 1 }
        }

        refreshCount()
        return written
    }

    /// Removes every event this app has written, and forgets them.
    ///
    /// The button that exists so that turning the mirror off does not have to mean deleting things
    /// silently. Failures are counted rather than fatal: an event somebody has already deleted by
    /// hand is not an error worth stopping the sweep for.
    @discardableResult
    public func removeEverythingWritten() async -> Int {
        guard let mirrored = try? entries.mirroredEntries() else { return 0 }

        isWorking = true
        defer { isWorking = false }

        var removed = 0
        for entry in mirrored {
            guard let identifier = entry.mirroredEventIdentifier,
                  let identity = EventIdentity.fromStorageKey(identifier)
            else { continue }

            _ = await calendar.delete(identity, scope: .thisEvent)
            try? entries.setMirror(eventIdentifier: nil, calendarIdentifier: nil, on: entry)
            removed += 1
        }

        refreshCount()
        return removed
    }

    public func refreshCount() {
        mirroredCount = (try? entries.mirroredEntries().count) ?? 0
    }

    // MARK: - Applying

    private func apply(to entry: TimeEntry, calendarIdentifier: String) async {
        let action = TimeMirroring.action(
            for: entry.snapshot(),
            existingIdentifier: entry.mirroredEventIdentifier,
            isDeleted: entry.isDeleted,
            policy: policy,
            now: dateProvider.now
        )

        switch action {
        case .none:
            return

        case .create(let fields):
            let outcome = await calendar.create(draft(from: fields, in: calendarIdentifier))
            switch outcome {
            case .success(let event):
                try? entries.setMirror(
                    eventIdentifier: event.identity.storageKey,
                    calendarIdentifier: calendarIdentifier,
                    on: entry
                )
            case .failure(let failure):
                lastFailure = failure
            }

        case .update(let identifier, let fields):
            guard let identity = EventIdentity.fromStorageKey(identifier) else { return }
            let outcome = await calendar.update(
                identity,
                with: draft(from: fields, in: entry.mirroredCalendarIdentifier ?? calendarIdentifier),
                scope: .thisEvent
            )
            switch outcome {
            case .success(let event):
                try? entries.setMirror(
                    eventIdentifier: event.identity.storageKey,
                    calendarIdentifier: entry.mirroredCalendarIdentifier ?? calendarIdentifier,
                    on: entry
                )
            case .failure:
                // An event that cannot be updated is most often one the user deleted by hand, and
                // re-creating it would be the app arguing with them. The link is dropped instead, so
                // the entry stops claiming to have an event it does not.
                try? entries.setMirror(eventIdentifier: nil, calendarIdentifier: nil, on: entry)
            }

        case .remove(let identifier):
            guard let identity = EventIdentity.fromStorageKey(identifier) else { return }
            _ = await calendar.delete(identity, scope: .thisEvent)
            try? entries.setMirror(eventIdentifier: nil, calendarIdentifier: nil, on: entry)
        }
    }

    /// The event a set of mirror fields becomes.
    ///
    /// This is the only place a `TimeMirrorFields` turns into an `EventDraft`, which is what keeps
    /// the guarantee narrow: the fields type has nowhere to put a person or a note, so neither can
    /// arrive here to be written.
    private func draft(from fields: TimeMirrorFields, in calendarIdentifier: String) -> EventDraft {
        EventDraft(
            calendarIdentifier: calendarIdentifier,
            title: fields.title,
            startAt: fields.startedAt,
            endAt: fields.endedAt,
            isAllDay: false,
            timeZoneIdentifier: TimeZone.current.identifier,
            notes: fields.notes,
            // Free by default. These describe time already spent, and marking it busy tells
            // everybody's scheduling assistant that yesterday afternoon is unavailable.
            availability: policy.marksAsBusy ? .busy : .free,
            // Never an alarm. A reminder about work that is already finished is a notification with
            // nothing on the other end of it.
            alarms: []
        )
    }
}
