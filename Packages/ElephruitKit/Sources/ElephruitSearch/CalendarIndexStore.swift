import ElephruitCore
import Foundation

/// One row of the calendar cache, as a search result or as an offline reading.
public struct IndexedEvent: Sendable, Hashable, Identifiable {
    public var identity: EventIdentity
    public var title: String
    public var startAt: Date
    public var endAt: Date
    public var isAllDay: Bool
    public var calendarIdentifier: String?
    public var calendarName: String?
    public var calendarColorName: String?
    public var accountName: String?
    public var locationName: String?
    public var notesExcerpt: String
    public var attendeeNames: [String]
    public var isRecurring: Bool
    public var isCancelled: Bool
    public var isDeclined: Bool

    /// Names of linked people, notes, and projects — Elephruit's own, never the calendar's.
    public var linkedNames: [String]

    /// A short piece of the match, with the matched words marked. `nil` when the match was
    /// structural rather than textual.
    public var snippet: String?

    public var id: String { identity.storageKey }

    public init(
        identity: EventIdentity,
        title: String,
        startAt: Date,
        endAt: Date,
        isAllDay: Bool = false,
        calendarIdentifier: String? = nil,
        calendarName: String? = nil,
        calendarColorName: String? = nil,
        accountName: String? = nil,
        locationName: String? = nil,
        notesExcerpt: String = "",
        attendeeNames: [String] = [],
        isRecurring: Bool = false,
        isCancelled: Bool = false,
        isDeclined: Bool = false,
        linkedNames: [String] = [],
        snippet: String? = nil
    ) {
        self.identity = identity
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.isAllDay = isAllDay
        self.calendarIdentifier = calendarIdentifier
        self.calendarName = calendarName
        self.calendarColorName = calendarColorName
        self.accountName = accountName
        self.locationName = locationName
        self.notesExcerpt = notesExcerpt
        self.attendeeNames = attendeeNames
        self.isRecurring = isRecurring
        self.isCancelled = isCancelled
        self.isDeclined = isDeclined
        self.linkedNames = linkedNames
        self.snippet = snippet
    }

    public var displayTitle: String {
        title.isEmpty ? "Untitled event" : title
    }
}

/// What Elephruit has attached to one event, in the form the index stores.
public struct IndexedEventLinks: Sendable, Hashable {
    public var identityKey: String
    public var personNames: [String]
    public var noteTitles: [String]
    public var projectTitles: [String]
    public var hasAttachments: Bool

    public init(
        identityKey: String,
        personNames: [String] = [],
        noteTitles: [String] = [],
        projectTitles: [String] = [],
        hasAttachments: Bool = false
    ) {
        self.identityKey = identityKey
        self.personNames = personNames
        self.noteTitles = noteTitles
        self.projectTitles = projectTitles
        self.hasAttachments = hasAttachments
    }
}

/// The calendar's own SQLite sidecar: a cache of events and an index over them.
///
/// ### Why a cache exists at all when EventKit is right there
/// Three reasons, in order of how often they bite.
///
/// 1. **Search.** "Lunches last year" against EventKit means asking for a year of events and
///    filtering them in Swift, per keystroke. On a working calendar that is tens of thousands of
///    `EKEvent` objects materialised to answer one question. FTS5 answers it from an inverted index.
/// 2. **Offline and denied.** A calendar the app cannot currently read should still show what it
///    last knew, with a note saying so, rather than going blank.
/// 3. **Linked context.** "Meetings with Maya" is a question about *Elephruit's* links, which
///    EventKit knows nothing about. Indexing them together is what makes one query answer it.
///
/// ### It is derived, on the same terms as the search index
/// EventKit is authoritative. Every row here is a projection, deleting the file costs a refresh and
/// nothing else, and the schema version is a drop-and-rebuild rather than a migration. That is why
/// there is no SwiftData entity for an event — see `SchemaV6`.
///
/// ### Isolation
/// An `actor` owning one non-`Sendable` ``SQLiteConnection``, exactly as ``SearchIndexStore`` does.
/// Everything crossing the boundary is a value type.
actor CalendarIndexStore {
    /// Bumped when the table shapes change. A mismatch drops and rebuilds; there is nothing here
    /// worth migrating.
    static let schemaVersion = 1

    private static let listSeparator = "\u{1}"

    private let url: URL
    private var connection: SQLiteConnection?

    init(url: URL) {
        self.url = url
    }

    // MARK: - Opening

    func open() throws(AppError) {
        guard connection == nil else { return }

        try createContainingDirectory()

        let connection = try SQLiteConnection(url: url)
        self.connection = connection

        do {
            try createSchema(in: connection)
        } catch {
            // A corrupt or foreign file holds nothing authoritative, so it is not worth diagnosing.
            Diagnostics.search.error("Calendar index unusable, recreating: \(error.summary, privacy: .public)")
            self.connection = nil
            connection.close()
            try recreateFile()
            let fresh = try SQLiteConnection(url: url)
            try createSchema(in: fresh)
            self.connection = fresh
        }
    }

    func destroy() throws(AppError) {
        connection?.close()
        connection = nil
        try recreateFile(create: false)
    }

    private func createContainingDirectory() throws(AppError) {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw .writeFailed(path: directory.path(percentEncoded: false), reason: error.localizedDescription)
        }
    }

    /// Removes the database and both of its sidecar journals.
    ///
    /// The `-wal` and `-shm` files must go too: a WAL left beside a deleted main database is how a
    /// "fresh" index comes back holding yesterday's rows.
    private func recreateFile(create: Bool = true) throws(AppError) {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let target = URL(filePath: url.path(percentEncoded: false) + suffix)
            guard fileManager.fileExists(atPath: target.path(percentEncoded: false)) else { continue }
            do {
                try fileManager.removeItem(at: target)
            } catch {
                throw .writeFailed(path: target.path(percentEncoded: false), reason: error.localizedDescription)
            }
        }
        if create { try createContainingDirectory() }
    }

    private func requireConnection() throws(AppError) -> SQLiteConnection {
        guard let connection else {
            throw .storeUnavailable(underlying: "The calendar index is not open.")
        }
        return connection
    }

    // MARK: - Schema

    private func createSchema(in connection: SQLiteConnection) throws(AppError) {
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS calendar_index_state (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """
        )

        let existing = try readState(connection, key: "schema_version").flatMap(Int.init)
        if let existing, existing != Self.schemaVersion {
            try dropEverything(in: connection)
        }

        // Five columns, so ranking can weight a title match above a passing mention in the notes.
        // `linked` holds Elephruit's own names — the people, notes, and projects attached here —
        // which is what makes "meetings with Maya" one query rather than two.
        try connection.execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS event_documents USING fts5(
                title,
                location,
                notes,
                attendees,
                linked,
                tokenize = "unicode61 remove_diacritics 2",
                prefix = '2 3 4'
            );
            """
        )

        // Everything a result row draws, plus every filter as a column, so a structural query is a
        // WHERE clause rather than a post-filter over materialised rows.
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS events (
                rowid            INTEGER PRIMARY KEY,
                identity_key     TEXT    NOT NULL UNIQUE,
                external_id      TEXT    NOT NULL,
                occurrence_at    REAL,
                title            TEXT    NOT NULL,
                location         TEXT,
                notes_excerpt    TEXT    NOT NULL,
                calendar_id      TEXT,
                calendar_name    TEXT,
                calendar_color   TEXT,
                account_name     TEXT,
                start_at         REAL    NOT NULL,
                end_at           REAL    NOT NULL,
                is_all_day       INTEGER NOT NULL,
                is_recurring     INTEGER NOT NULL,
                is_cancelled     INTEGER NOT NULL,
                is_declined      INTEGER NOT NULL,
                has_notes        INTEGER NOT NULL,
                has_attendees    INTEGER NOT NULL,
                has_links        INTEGER NOT NULL,
                has_attachments  INTEGER NOT NULL,
                attendee_names   TEXT    NOT NULL,
                linked_names     TEXT    NOT NULL,
                indexed_at       REAL    NOT NULL
            );
            """
        )

        // A window's worth of events is fetched by time far more often than by anything else, and
        // the search path filters on the same column, so this index carries both.
        for statement in [
            "CREATE INDEX IF NOT EXISTS events_window ON events(start_at, end_at);",
            "CREATE INDEX IF NOT EXISTS events_external ON events(external_id);",
            "CREATE INDEX IF NOT EXISTS events_calendar ON events(calendar_id, start_at);",
        ] {
            try connection.execute(statement)
        }

        try writeState(connection, key: "schema_version", value: String(Self.schemaVersion))
    }

    private func dropEverything(in connection: SQLiteConnection) throws(AppError) {
        for statement in [
            "DROP TABLE IF EXISTS event_documents;",
            "DROP TABLE IF EXISTS events;",
        ] {
            try connection.execute(statement)
        }
    }

    private func readState(_ connection: SQLiteConnection, key: String) throws(AppError) -> String? {
        let statement = try connection.prepared("SELECT value FROM calendar_index_state WHERE key = ?1;")
        statement.bind(key, at: 1)
        guard try statement.step() else { return nil }
        return statement.optionalString(at: 0)
    }

    private func writeState(_ connection: SQLiteConnection, key: String, value: String) throws(AppError) {
        let statement = try connection.prepared(
            "INSERT INTO calendar_index_state (key, value) VALUES (?1, ?2) " +
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value;"
        )
        statement.bind(key, at: 1)
        statement.bind(value, at: 2)
        try statement.run()
    }

    // MARK: - Writing

    /// Replaces the cached events for a window.
    ///
    /// ### Why the window is deleted first rather than the rows being merged
    /// Because an event can *leave* a window without being deleted — somebody moves a Tuesday
    /// meeting to the following Monday — and a merge has no way to notice. Deleting what the window
    /// held and writing what it now holds is the only reconciliation that cannot leave a ghost, and
    /// it costs one indexed range delete.
    ///
    /// Rows outside the window are untouched, so refreshing this week does not discard last month.
    ///
    /// - Parameter calendarIdentifiers: Which calendars this replacement speaks for. `nil` means all
    ///   of them. When a Calendar Set or a hidden calendar narrowed the fetch, the rows for
    ///   calendars *outside* that scope are left alone — because the fetch never asked about them,
    ///   so their absence from `events` says nothing. Without this, ticking a calendar off would
    ///   quietly make its past unsearchable, which is not what ticking a box means.
    func replace(
        _ events: [CalendarEventSummary],
        inWindow window: Range<Date>,
        calendarIdentifiers: [String]?,
        links: [String: IndexedEventLinks],
        at now: Date
    ) throws(AppError) {
        let connection = try requireConnection()

        try connection.transaction {
            var sql = "DELETE FROM events WHERE start_at < ?1 AND end_at > ?2"
            if let calendarIdentifiers {
                let placeholders = calendarIdentifiers.indices.map { "?\($0 + 3)" }.joined(separator: ", ")
                sql += calendarIdentifiers.isEmpty
                    ? " AND 0"
                    : " AND calendar_id IN (\(placeholders))"
            }
            sql += ";"

            let delete = try connection.makeTransient(sql)
            delete.statement.bind(window.upperBound, at: 1)
            delete.statement.bind(window.lowerBound, at: 2)
            for (offset, identifier) in (calendarIdentifiers ?? []).enumerated() {
                delete.statement.bind(identifier, at: Int32(offset + 3))
            }
            try delete.statement.run()

            // FTS5 has no foreign keys, so its rows are swept by the same bounds.
            try pruneDocuments(connection)

            for event in events {
                try insert(event, links: links[event.identity.storageKey], at: now, using: connection)
            }
        }
    }

    /// Writes or replaces one event, for an incremental change.
    func upsert(
        _ event: CalendarEventSummary,
        links: IndexedEventLinks?,
        at now: Date
    ) throws(AppError) {
        let connection = try requireConnection()
        try connection.transaction {
            try remove(identityKey: event.identity.storageKey, using: connection)
            try insert(event, links: links, at: now, using: connection)
        }
    }

    func remove(identityKey: String) throws(AppError) {
        let connection = try requireConnection()
        try connection.transaction {
            try remove(identityKey: identityKey, using: connection)
        }
    }

    private func remove(identityKey: String, using connection: SQLiteConnection) throws(AppError) {
        let lookup = try connection.prepared("SELECT rowid FROM events WHERE identity_key = ?1;")
        lookup.bind(identityKey, at: 1)

        guard try lookup.step() else { return }
        let rowid = lookup.int(at: 0)

        let deleteDocument = try connection.prepared("DELETE FROM event_documents WHERE rowid = ?1;")
        deleteDocument.bind(rowid, at: 1)
        try deleteDocument.run()

        let deleteEvent = try connection.prepared("DELETE FROM events WHERE rowid = ?1;")
        deleteEvent.bind(rowid, at: 1)
        try deleteEvent.run()
    }

    /// Removes documents whose event row has gone.
    private func pruneDocuments(_ connection: SQLiteConnection) throws(AppError) {
        try connection.execute(
            """
            DELETE FROM event_documents
            WHERE rowid NOT IN (SELECT rowid FROM events);
            """
        )
    }

    private func insert(
        _ event: CalendarEventSummary,
        links: IndexedEventLinks?,
        at now: Date,
        using connection: SQLiteConnection
    ) throws(AppError) {
        let attendees = event.attendeeNames
        let linkedNames = (links?.personNames ?? []) + (links?.noteTitles ?? []) + (links?.projectTitles ?? [])
        let notes = event.notes ?? ""

        let statement = try connection.prepared(
            """
            INSERT INTO events (
                identity_key, external_id, occurrence_at, title, location, notes_excerpt,
                calendar_id, calendar_name, calendar_color, account_name,
                start_at, end_at, is_all_day, is_recurring, is_cancelled, is_declined,
                has_notes, has_attendees, has_links, has_attachments,
                attendee_names, linked_names, indexed_at
            ) VALUES (
                ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10,
                ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23
            );
            """
        )

        statement.bind(event.identity.storageKey, at: 1)
        statement.bind(event.identity.externalIdentifier, at: 2)
        statement.bind(event.identity.occurrenceDate, at: 3)
        statement.bind(event.title, at: 4)
        statement.bind(event.locationName, at: 5)
        statement.bind(Self.excerpt(of: notes), at: 6)
        statement.bind(event.calendarIdentifier, at: 7)
        statement.bind(event.calendarName, at: 8)
        statement.bind(event.calendarColorName, at: 9)
        statement.bind(event.accountName, at: 10)
        statement.bind(event.startAt, at: 11)
        statement.bind(event.endAt, at: 12)
        statement.bind(event.isAllDay, at: 13)
        statement.bind(event.isRecurring, at: 14)
        statement.bind(event.isCancelled, at: 15)
        statement.bind(event.participation == .declined, at: 16)
        statement.bind(!notes.isEmpty, at: 17)
        statement.bind(!attendees.isEmpty, at: 18)
        statement.bind(!linkedNames.isEmpty, at: 19)
        statement.bind(links?.hasAttachments ?? false, at: 20)
        statement.bind(attendees.joined(separator: Self.listSeparator), at: 21)
        statement.bind(linkedNames.joined(separator: Self.listSeparator), at: 22)
        statement.bind(now, at: 23)
        try statement.run()

        let rowid = try Self.lastInsertRowID(in: connection)

        // The full notes are indexed for matching even though only an excerpt is stored for display,
        // which is the same split `SearchIndexStore` makes and for the same reason.
        let document = try connection.prepared(
            """
            INSERT INTO event_documents (rowid, title, location, notes, attendees, linked)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6);
            """
        )
        document.bind(rowid, at: 1)
        document.bind(event.title, at: 2)
        document.bind(event.locationName ?? "", at: 3)
        document.bind(notes, at: 4)
        document.bind(attendees.joined(separator: " "), at: 5)
        document.bind(linkedNames.joined(separator: " "), at: 6)
        try document.run()
    }

    static func lastInsertRowID(in connection: SQLiteConnection) throws(AppError) -> Int {
        let statement = try connection.prepared("SELECT last_insert_rowid();")
        guard try statement.step() else { return 0 }
        return statement.int(at: 0)
    }

    /// The first couple of lines of a note, for a result row.
    static func excerpt(of notes: String, limit: Int = 180) -> String {
        let collapsed = notes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    // MARK: - Reading

    /// Every cached event overlapping a window, in display order.
    ///
    /// The offline path: what the app last knew, when EventKit cannot currently be asked.
    func events(in window: Range<Date>, calendarIdentifiers: [String]?) throws(AppError) -> [IndexedEvent] {
        let connection = try requireConnection()

        var sql = "SELECT \(Self.selectedColumns) FROM events WHERE start_at < ?1 AND end_at > ?2"
        if let calendarIdentifiers {
            guard !calendarIdentifiers.isEmpty else { return [] }
            let placeholders = calendarIdentifiers.indices.map { "?\($0 + 3)" }.joined(separator: ", ")
            sql += " AND calendar_id IN (\(placeholders))"
        }
        sql += " ORDER BY is_all_day DESC, start_at ASC, title ASC;"

        let transient = try connection.makeTransient(sql)
        transient.statement.bind(window.upperBound, at: 1)
        transient.statement.bind(window.lowerBound, at: 2)
        for (offset, identifier) in (calendarIdentifiers ?? []).enumerated() {
            transient.statement.bind(identifier, at: Int32(offset + 3))
        }

        var results: [IndexedEvent] = []
        while try transient.statement.step() {
            results.append(Self.event(from: transient.statement))
        }
        return results
    }

    /// How many events are cached, and when the cache was last written.
    func statistics() throws(AppError) -> (events: Int, lastIndexedAt: Date?) {
        let connection = try requireConnection()
        let statement = try connection.prepared("SELECT COUNT(*), MAX(indexed_at) FROM events;")
        guard try statement.step() else { return (0, nil) }
        return (statement.int(at: 0), statement.optionalDate(at: 1))
    }

    /// Every column a row draws from, qualified with its table.
    ///
    /// The qualification is not decoration: `title` and `location` exist on both `events` and the
    /// FTS table, so the search path — which joins them — fails to prepare at all without it, and the
    /// failure surfaces as an empty result set rather than as an error anybody would notice.
    static let selectedColumns = """
        events.identity_key, events.external_id, events.occurrence_at, events.title, \
        events.location, events.notes_excerpt, events.calendar_id, events.calendar_name, \
        events.calendar_color, events.account_name, events.start_at, events.end_at, \
        events.is_all_day, events.is_recurring, events.is_cancelled, events.is_declined, \
        events.attendee_names, events.linked_names
        """

    /// Reads one row. Column order matches ``selectedColumns`` exactly, and a change to one without
    /// the other is the classic off-by-one this arrangement makes at least visible in one place.
    static func event(from statement: SQLiteStatement) -> IndexedEvent {
        IndexedEvent(
            identity: EventIdentity(
                externalIdentifier: statement.string(at: 1),
                occurrenceDate: statement.optionalDate(at: 2)
            ),
            title: statement.string(at: 3),
            startAt: statement.date(at: 10),
            endAt: statement.date(at: 11),
            isAllDay: statement.bool(at: 12),
            calendarIdentifier: statement.optionalString(at: 6),
            calendarName: statement.optionalString(at: 7),
            calendarColorName: statement.optionalString(at: 8),
            accountName: statement.optionalString(at: 9),
            locationName: statement.optionalString(at: 4),
            notesExcerpt: statement.string(at: 5),
            attendeeNames: Self.split(statement.string(at: 16)),
            isRecurring: statement.bool(at: 13),
            isCancelled: statement.bool(at: 14),
            isDeclined: statement.bool(at: 15),
            linkedNames: Self.split(statement.string(at: 17))
        )
    }

    static func split(_ joined: String?) -> [String] {
        guard let joined, !joined.isEmpty else { return [] }
        return joined.components(separatedBy: listSeparator).filter { !$0.isEmpty }
    }

    // MARK: - Searching

    /// Runs a parsed query against the index.
    func search(_ query: EventSearchQuery, now: Date, limit: Int = 200) throws(AppError) -> [IndexedEvent] {
        let connection = try requireConnection()
        let plan = CalendarSearchPlan(query: query, now: now, limit: limit)

        let transient = try connection.makeTransient(plan.sql)
        plan.bind(to: transient.statement)

        var results: [IndexedEvent] = []
        while try transient.statement.step() {
            var event = Self.event(from: transient.statement)
            if plan.selectsSnippet { event.snippet = transient.statement.optionalString(at: 18) }
            results.append(event)
        }
        return results
    }
}
