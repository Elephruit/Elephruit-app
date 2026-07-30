import ElephruitCore
import Foundation
import SQLite3

/// The FTS5 sidecar: a SQLite database beside the store that exists only to answer searches.
///
/// ### What this is and is not
/// It is **derived**. Every row here is a projection of an `Item` that SwiftData owns. Deleting the
/// file costs a rebuild and nothing else, which is the property `docs/adr/0004-search-is-derived.md`
/// argues for and the reason the index can be rebuilt in the background without a migration, a
/// version negotiation, or a user-visible decision.
///
/// ### Why a second database rather than SwiftData
/// `#Predicate` compiles to a store query with no ranking, no tokenisation, no prefix index, and — as
/// the ceiling documented on `ItemPredicateBuilder` shows — a hard limit on how many clauses will
/// even type-check. Substring matching over a body column is a table scan. At fifty thousand items
/// that is hundreds of milliseconds per keystroke. FTS5 answers the same question from an inverted
/// index in single-digit milliseconds and hands back a ranked, highlighted result.
///
/// ### Isolation
/// An `actor`, owning one non-`Sendable` ``SQLiteConnection``. Nothing else may touch the connection,
/// so SQLite's threading modes never enter the picture. Everything crossing the boundary is a
/// `Sendable` value type.
actor SearchIndexStore {
    /// Bumped when the table shapes change. A mismatch drops and rebuilds rather than migrating —
    /// there is nothing here worth migrating.
    static let schemaVersion = 1

    /// Separates tag slugs inside the denormalised column. A control character, so it can never
    /// occur in a slug and never needs escaping.
    private static let slugSeparator = "\u{1}"

    private let url: URL
    private var connection: SQLiteConnection?

    /// How far a rebuild has got. Read by the search field so a query mid-rebuild can say
    /// "still indexing" instead of showing an empty list that looks like an answer.
    private(set) var rebuildProgress: RebuildProgress = .idle

    init(url: URL) {
        self.url = url
    }

    // MARK: - Opening

    /// Opens the database, creating and migrating the schema as needed.
    ///
    /// Idempotent. Called on every launch; only the first call does work.
    func open() throws(AppError) {
        guard connection == nil else { return }

        try createContainingDirectory()

        let connection = try SQLiteConnection(url: url)
        self.connection = connection

        do {
            try createSchema(in: connection)
        } catch {
            // A corrupt or foreign file is not worth diagnosing: it holds nothing authoritative.
            Diagnostics.search.error("Search index unusable, recreating: \(error.summary, privacy: .public)")
            self.connection = nil
            connection.close()
            try recreateFile()
            let fresh = try SQLiteConnection(url: url)
            try createSchema(in: fresh)
            self.connection = fresh
        }
    }

    /// Closes and deletes the file. The next `open()` starts from nothing.
    func destroy() throws(AppError) {
        connection?.close()
        connection = nil
        rebuildProgress = .idle
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
    /// The `-wal` and `-shm` files must go too. Leaving a WAL behind next to a deleted main database
    /// is how a "fresh" index comes back holding yesterday's rows.
    private func recreateFile(create: Bool = true) throws(AppError) {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let target = URL(filePath: url.path(percentEncoded: false) + suffix)
            guard fileManager.fileExists(atPath: target.path(percentEncoded: false)) else { continue }
            do {
                try fileManager.removeItem(at: target)
            } catch {
                throw .writeFailed(
                    path: target.path(percentEncoded: false),
                    reason: error.localizedDescription
                )
            }
        }
        if create {
            try createContainingDirectory()
        }
    }

    private func requireConnection() throws(AppError) -> SQLiteConnection {
        guard let connection else {
            throw .storeUnavailable(underlying: "The search index is not open.")
        }
        return connection
    }

    // MARK: - Schema

    private func createSchema(in connection: SQLiteConnection) throws(AppError) {
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS index_state (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """
        )

        let existing = try readState(connection, key: "schema_version").flatMap(Int.init)
        if let existing, existing != Self.schemaVersion {
            try dropEverything(in: connection)
        }

        // The searchable document. Five columns so ranking can weight them differently — a title
        // match means something quite different from a passing mention in a body.
        //
        // `remove_diacritics 2` folds accents across the full Unicode range, so "resume" finds
        // "résumé". `prefix = '2 3 4'` builds prefix indexes at those lengths, which is what makes
        // as-you-type search resolve without scanning the term list.
        try connection.execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS documents USING fts5(
                title,
                body,
                tags,
                container,
                people,
                tokenize = "unicode61 remove_diacritics 2",
                prefix = '2 3 4'
            );
            """
        )

        // Substring matching, titles only.
        //
        // Trigrams find "aunch" inside "Launch" — which ordinary tokenised search cannot, because
        // "aunch" is not a prefix of any token. Restricted to titles on purpose: a trigram index
        // over every body would roughly double the file for a case that almost never arises, since
        // people search bodies by word and titles by fragment.
        try connection.execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS title_trigrams USING fts5(
                title,
                tokenize = "trigram"
            );
            """
        )

        // Everything a result row needs to draw itself, plus every structural filter as a column.
        //
        // Both halves matter. The first means a result list renders without a single SwiftData
        // fetch. The second means `is:open type:task due:<7d` is a WHERE clause rather than a
        // post-filter over materialised objects — which is what the v1 engine did, and why it fell
        // over on a large library.
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS entries (
                rowid           INTEGER PRIMARY KEY,
                item_id         TEXT    NOT NULL UNIQUE,
                kind            TEXT    NOT NULL,
                status          TEXT    NOT NULL,
                priority        TEXT    NOT NULL,
                title           TEXT    NOT NULL,
                excerpt         TEXT    NOT NULL,
                tag_slugs       TEXT    NOT NULL,
                parent_id       TEXT,
                parent_title    TEXT,
                symbol_name     TEXT,
                color_name      TEXT,
                day_key         TEXT,
                sort_order      REAL    NOT NULL,
                created_at      REAL    NOT NULL,
                updated_at      REAL    NOT NULL,
                start_at        REAL,
                due_at          REAL,
                defer_until     REAL,
                completed_at    REAL,
                archived_at     REAL,
                deleted_at      REAL,
                is_favorite     INTEGER NOT NULL,
                is_pinned       INTEGER NOT NULL,
                is_archived     INTEGER NOT NULL,
                is_trashed      INTEGER NOT NULL,
                has_tags        INTEGER NOT NULL,
                is_filed        INTEGER NOT NULL,
                has_links       INTEGER NOT NULL,
                in_content_views INTEGER NOT NULL
            );
            """
        )

        // One row per tag per item, so `tag:` is an indexed lookup rather than a LIKE over a joined
        // string. Hierarchical matching — `tag:work` finding `work/clients` — becomes a range scan
        // over this index, which is the only reason it stays cheap on a big library.
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS entry_tags (
                entry_rowid INTEGER NOT NULL,
                slug        TEXT    NOT NULL,
                PRIMARY KEY (entry_rowid, slug)
            ) WITHOUT ROWID;
            """
        )

        for statement in [
            "CREATE INDEX IF NOT EXISTS entries_item_id ON entries(item_id);",
            "CREATE INDEX IF NOT EXISTS entries_scope ON entries(is_trashed, is_archived, in_content_views);",
            "CREATE INDEX IF NOT EXISTS entries_kind ON entries(kind);",
            "CREATE INDEX IF NOT EXISTS entries_due ON entries(due_at);",
            "CREATE INDEX IF NOT EXISTS entries_updated ON entries(updated_at);",
            "CREATE INDEX IF NOT EXISTS entries_title ON entries(title);",
            "CREATE INDEX IF NOT EXISTS entry_tags_slug ON entry_tags(slug, entry_rowid);",
        ] {
            try connection.execute(statement)
        }

        try writeState(connection, key: "schema_version", value: String(Self.schemaVersion))
    }

    private func dropEverything(in connection: SQLiteConnection) throws(AppError) {
        for statement in [
            "DROP TABLE IF EXISTS documents;",
            "DROP TABLE IF EXISTS title_trigrams;",
            "DROP TABLE IF EXISTS entry_tags;",
            "DROP TABLE IF EXISTS entries;",
        ] {
            try connection.execute(statement)
        }
        try connection.execute("DELETE FROM index_state WHERE key <> 'schema_version';")
    }

    // MARK: - State

    private func readState(_ connection: SQLiteConnection, key: String) throws(AppError) -> String? {
        let statement = try connection.prepared("SELECT value FROM index_state WHERE key = ?1;")
        statement.bind(key, at: 1)
        guard try statement.step() else { return nil }
        return statement.string(at: 0)
    }

    private func writeState(_ connection: SQLiteConnection, key: String, value: String) throws(AppError) {
        let statement = try connection.prepared(
            "INSERT INTO index_state(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = ?2;"
        )
        statement.bind(key, at: 1)
        statement.bind(value, at: 2)
        try statement.run()
    }

    /// Whether the index has ever finished a full build.
    ///
    /// A half-built index is still queryable — it simply has fewer rows — but the caller needs to
    /// know, so it can say so rather than presenting a short list as a complete answer.
    func isComplete() throws(AppError) -> Bool {
        let connection = try requireConnection()
        return try readState(connection, key: "complete") == "1"
    }

    func indexedCount() throws(AppError) -> Int {
        let connection = try requireConnection()
        let statement = try connection.prepared("SELECT count(*) FROM entries;")
        guard try statement.step() else { return 0 }
        return statement.int(at: 0)
    }

    // MARK: - Writing

    /// Inserts or replaces one item's row across all four tables.
    func upsert(_ document: IndexDocument) throws(AppError) {
        let connection = try requireConnection()
        try connection.transaction {
            try writeDocument(document, in: connection)
        }
    }

    /// Inserts or replaces a batch in a single transaction.
    func upsert(_ documents: [IndexDocument]) throws(AppError) {
        guard !documents.isEmpty else { return }
        let connection = try requireConnection()
        try connection.transaction {
            for document in documents {
                try writeDocument(document, in: connection)
            }
        }
    }

    private func writeDocument(_ document: IndexDocument, in connection: SQLiteConnection) throws(AppError) {
        let rowid = try existingRowID(for: document.snapshot.id, in: connection)

        if let rowid {
            try deleteSearchRows(rowid: rowid, in: connection)
            try updateEntry(document, rowid: rowid, in: connection)
            try insertSearchRows(document, rowid: rowid, in: connection)
        } else {
            let inserted = try insertEntry(document, in: connection)
            try insertSearchRows(document, rowid: inserted, in: connection)
        }
    }

    private func existingRowID(for id: UUID, in connection: SQLiteConnection) throws(AppError) -> Int? {
        let statement = try connection.prepared("SELECT rowid FROM entries WHERE item_id = ?1;")
        statement.bind(id.uuidString, at: 1)
        guard try statement.step() else { return nil }
        return statement.int(at: 0)
    }

    /// Column order is shared by the insert and the update, so the two can never drift apart.
    private static let entryColumns = [
        "item_id", "kind", "status", "priority", "title", "excerpt", "tag_slugs",
        "parent_id", "parent_title", "symbol_name", "color_name", "day_key", "sort_order",
        "created_at", "updated_at", "start_at", "due_at", "defer_until", "completed_at",
        "archived_at", "deleted_at", "is_favorite", "is_pinned", "is_archived", "is_trashed",
        "has_tags", "is_filed", "has_links", "in_content_views",
    ]

    private func bindEntry(_ document: IndexDocument, to statement: SQLiteStatement) {
        let snapshot = document.snapshot
        statement.bind(snapshot.id.uuidString, at: 1)
        statement.bind(snapshot.kind.rawValue, at: 2)
        statement.bind(snapshot.status.rawValue, at: 3)
        statement.bind(snapshot.priority.rawValue, at: 4)
        statement.bind(snapshot.title, at: 5)
        statement.bind(document.excerpt, at: 6)
        statement.bind(Self.slugSeparator + snapshot.tagSlugs.joined(separator: Self.slugSeparator), at: 7)
        statement.bind(snapshot.parentID?.uuidString, at: 8)
        statement.bind(snapshot.parentTitle, at: 9)
        statement.bind(snapshot.symbolName, at: 10)
        statement.bind(snapshot.colorName, at: 11)
        statement.bind(snapshot.dayKey, at: 12)
        statement.bind(snapshot.sortOrder, at: 13)
        statement.bind(snapshot.createdAt, at: 14)
        statement.bind(snapshot.updatedAt, at: 15)
        statement.bind(snapshot.startAt, at: 16)
        statement.bind(snapshot.dueAt, at: 17)
        statement.bind(snapshot.deferUntil, at: 18)
        statement.bind(snapshot.completedAt, at: 19)
        statement.bind(snapshot.archivedAt, at: 20)
        statement.bind(snapshot.deletedAt, at: 21)
        statement.bind(snapshot.isFavorite, at: 22)
        statement.bind(snapshot.isPinned, at: 23)
        statement.bind(snapshot.archivedAt != nil, at: 24)
        statement.bind(snapshot.deletedAt != nil, at: 25)
        statement.bind(!snapshot.tagSlugs.isEmpty, at: 26)
        statement.bind(document.isFiled, at: 27)
        statement.bind(document.hasLinks, at: 28)
        statement.bind(snapshot.kind.participatesInContentViews, at: 29)
    }

    private func insertEntry(_ document: IndexDocument, in connection: SQLiteConnection) throws(AppError) -> Int {
        let placeholders = (1...Self.entryColumns.count).map { "?\($0)" }.joined(separator: ", ")
        let sql = """
            INSERT INTO entries(\(Self.entryColumns.joined(separator: ", ")))
            VALUES(\(placeholders));
            """
        let statement = try connection.prepared(sql)
        bindEntry(document, to: statement)
        try statement.run()

        let rowID = try lastInsertRowID(in: connection)
        return rowID
    }

    private func updateEntry(
        _ document: IndexDocument,
        rowid: Int,
        in connection: SQLiteConnection
    ) throws(AppError) {
        let assignments = Self.entryColumns.enumerated()
            .map { "\($0.element) = ?\($0.offset + 1)" }
            .joined(separator: ", ")
        let sql = "UPDATE entries SET \(assignments) WHERE rowid = ?\(Self.entryColumns.count + 1);"
        let statement = try connection.prepared(sql)
        bindEntry(document, to: statement)
        statement.bind(rowid, at: Int32(Self.entryColumns.count + 1))
        try statement.run()
    }

    private func lastInsertRowID(in connection: SQLiteConnection) throws(AppError) -> Int {
        let statement = try connection.prepared("SELECT last_insert_rowid();")
        guard try statement.step() else {
            throw .writeFailed(path: "search index", reason: "The inserted row has no identifier.")
        }
        return statement.int(at: 0)
    }

    private func insertSearchRows(
        _ document: IndexDocument,
        rowid: Int,
        in connection: SQLiteConnection
    ) throws(AppError) {
        let documentStatement = try connection.prepared(
            """
            INSERT INTO documents(rowid, title, body, tags, container, people)
            VALUES(?1, ?2, ?3, ?4, ?5, ?6);
            """
        )
        documentStatement.bind(rowid, at: 1)
        documentStatement.bind(document.snapshot.title, at: 2)
        documentStatement.bind(document.body, at: 3)
        documentStatement.bind(document.tagText, at: 4)
        documentStatement.bind(document.containerText, at: 5)
        documentStatement.bind(document.peopleText, at: 6)
        try documentStatement.run()

        let trigramStatement = try connection.prepared(
            "INSERT INTO title_trigrams(rowid, title) VALUES(?1, ?2);"
        )
        trigramStatement.bind(rowid, at: 1)
        trigramStatement.bind(document.snapshot.title, at: 2)
        try trigramStatement.run()

        for slug in document.snapshot.tagSlugs {
            let tagStatement = try connection.prepared(
                "INSERT OR IGNORE INTO entry_tags(entry_rowid, slug) VALUES(?1, ?2);"
            )
            tagStatement.bind(rowid, at: 1)
            tagStatement.bind(slug, at: 2)
            try tagStatement.run()
        }
    }

    private func deleteSearchRows(rowid: Int, in connection: SQLiteConnection) throws(AppError) {
        for sql in [
            "DELETE FROM documents WHERE rowid = ?1;",
            "DELETE FROM title_trigrams WHERE rowid = ?1;",
            "DELETE FROM entry_tags WHERE entry_rowid = ?1;",
        ] {
            let statement = try connection.prepared(sql)
            statement.bind(rowid, at: 1)
            try statement.run()
        }
    }

    /// Removes one item from every table.
    func remove(id: UUID) throws(AppError) {
        let connection = try requireConnection()
        try connection.transaction {
            guard let rowid = try existingRowID(for: id, in: connection) else { return }
            try deleteSearchRows(rowid: rowid, in: connection)
            let statement = try connection.prepared("DELETE FROM entries WHERE rowid = ?1;")
            statement.bind(rowid, at: 1)
            try statement.run()
        }
    }

    // MARK: - Rebuilding

    /// Marks the start of a full rebuild.
    ///
    /// The existing rows are deliberately **left in place**. A rebuild that emptied the index first
    /// would give every search run during it a confident, wrong, empty answer — the exact failure
    /// the phase plan rules out. Stale rows are replaced as they are re-indexed, and anything left
    /// over is swept at the end.
    func beginRebuild(expecting total: Int) throws(AppError) {
        let connection = try requireConnection()
        try writeState(connection, key: "complete", value: "0")
        try writeState(connection, key: "rebuild_generation", value: UUID().uuidString)
        rebuildProgress = RebuildProgress(indexed: 0, expected: total, isRebuilding: true)
    }

    func recordRebuildProgress(indexed: Int) {
        guard rebuildProgress.isRebuilding else { return }
        rebuildProgress.indexed = indexed
    }

    /// Removes rows for items that no longer exist, and marks the index complete.
    func finishRebuild(keeping liveIDs: Set<UUID>) throws(AppError) {
        let connection = try requireConnection()

        try connection.transaction {
            let statement = try connection.prepared("SELECT rowid, item_id FROM entries;")
            var stale: [Int] = []
            while try statement.step() {
                let rowid = statement.int(at: 0)
                guard let id = UUID(uuidString: statement.string(at: 1)), liveIDs.contains(id) else {
                    stale.append(rowid)
                    continue
                }
            }

            for rowid in stale {
                try deleteSearchRows(rowid: rowid, in: connection)
                let delete = try connection.prepared("DELETE FROM entries WHERE rowid = ?1;")
                delete.bind(rowid, at: 1)
                try delete.run()
            }
        }

        try writeState(connection, key: "complete", value: "1")
        try connection.execute("INSERT INTO documents(documents) VALUES('optimize');")
        rebuildProgress = .idle
    }

    /// Abandons a rebuild without claiming completeness.
    func abandonRebuild() {
        rebuildProgress = .idle
    }

    // MARK: - Reading

    /// Runs a compiled query and returns ranked rows.
    func query(_ compiled: CompiledSearch) throws(AppError) -> [SearchResult] {
        let connection = try requireConnection()
        let statement = try connection.makeTransient(compiled.sql)
        compiled.bind(to: statement.statement)

        var results: [SearchResult] = []
        results.reserveCapacity(compiled.limit)

        while try statement.statement.step() {
            guard let result = Self.readResult(from: statement.statement, mode: compiled.mode) else { continue }
            results.append(result)
        }
        return results
    }

    /// Titles for `[[` completion and the palette. Prefix-matched, cheapest possible path.
    func titles(prefix: String, limit: Int) throws(AppError) -> [(id: UUID, title: String)] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let connection = try requireConnection()
        let statement = try connection.prepared(
            """
            SELECT item_id, title FROM entries
            WHERE is_trashed = 0 AND title LIKE ?1 ESCAPE '\\'
            ORDER BY length(title), updated_at DESC
            LIMIT ?2;
            """
        )
        statement.bind(Self.likePrefix(trimmed), at: 1)
        statement.bind(limit, at: 2)

        var matches: [(id: UUID, title: String)] = []
        while try statement.step() {
            guard let id = UUID(uuidString: statement.string(at: 0)) else { continue }
            matches.append((id, statement.string(at: 1)))
        }
        return matches
    }

    /// Escapes LIKE's own wildcards so a title containing `%` searches for a literal `%`.
    static func likePrefix(_ value: String) -> String {
        var escaped = ""
        for character in value {
            if character == "%" || character == "_" || character == "\\" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped + "%"
    }

    /// Rebuilds an `ItemSnapshot` from the columns the query selected.
    ///
    /// - Important: the snapshot's `body` carries the stored **excerpt**, not the full text. A
    ///   result row shows a short preview and nothing more, and holding every body in the index
    ///   twice over would multiply the file for no gain. Anything needing the real body — the
    ///   editor — loads the item from the store, where it is authoritative.
    private static func readResult(from statement: SQLiteStatement, mode: SearchMode) -> SearchResult? {
        guard let id = UUID(uuidString: statement.string(at: 0)),
              let kind = ItemKind(rawValue: statement.string(at: 1))
        else { return nil }

        let tagColumn = statement.string(at: 6)
        let tagSlugs = tagColumn
            .split(separator: Character(SearchIndexStore.slugSeparator))
            .map(String.init)

        let snapshot = ItemSnapshot(
            id: id,
            kind: kind,
            title: statement.string(at: 2),
            body: statement.string(at: 5),
            createdAt: statement.date(at: 12),
            updatedAt: statement.date(at: 13),
            status: ItemStatus(rawValue: statement.string(at: 3)) ?? .none,
            priority: Priority(rawValue: statement.string(at: 4)) ?? .normal,
            startAt: statement.optionalDate(at: 14),
            dueAt: statement.optionalDate(at: 15),
            deferUntil: statement.optionalDate(at: 16),
            completedAt: statement.optionalDate(at: 17),
            archivedAt: statement.optionalDate(at: 18),
            deletedAt: statement.optionalDate(at: 19),
            isFavorite: statement.bool(at: 20),
            isPinned: statement.bool(at: 21),
            tagSlugs: tagSlugs,
            parentID: UUID(uuidString: statement.optionalString(at: 7) ?? ""),
            parentTitle: statement.optionalString(at: 8),
            symbolName: statement.optionalString(at: 9),
            colorName: statement.optionalString(at: 10),
            dayKey: statement.optionalString(at: 11),
            sortOrder: statement.double(at: 22)
        )

        // BM25 returns a negative number, better matches being more negative. Flipping the sign
        // makes "higher is better" true everywhere in the app, which is what every call site and
        // every test already assumes.
        let rank = mode.rankColumn.map { -statement.double(at: $0) } ?? 0

        let excerpt = mode.snippetColumn.map { statement.string(at: $0) }
        let titleExcerpt = mode.titleSnippetColumn.map { statement.string(at: $0) }

        return SearchResult(
            item: snapshot,
            score: rank + mode.bonus(favorite: snapshot.isFavorite, pinned: snapshot.isPinned),
            titleMatchRanges: SearchHighlight.ranges(in: titleExcerpt),
            bodyExcerpt: excerpt.flatMap { SearchHighlight.plain($0) }
        )
    }
}

/// How far a rebuild has got.
public struct RebuildProgress: Sendable, Hashable {
    public var indexed: Int = 0
    public var expected: Int = 0
    public var isRebuilding: Bool = false

    public init(indexed: Int = 0, expected: Int = 0, isRebuilding: Bool = false) {
        self.indexed = indexed
        self.expected = expected
        self.isRebuilding = isRebuilding
    }

    public static let idle = RebuildProgress()

    public var fraction: Double {
        guard isRebuilding, expected > 0 else { return 1 }
        return min(1, Double(indexed) / Double(expected))
    }
}

/// Everything the index needs about one item, gathered on the actor that can safely read it.
///
/// A `Sendable` value, so the model object it came from never leaves its own context.
struct IndexDocument: Sendable {
    var snapshot: ItemSnapshot
    /// Full text, for the FTS document. Not stored in `entries`.
    var body: String
    /// A short preview, stored for display.
    var excerpt: String
    /// Tag slugs as searchable words, so `tag/child` matches a search for `child`.
    var tagText: String
    /// Ancestor titles, so `in:"Q3 Launch"` and a plain text search both find things by container.
    var containerText: String
    /// Names of linked people, for the `person:` operator.
    var peopleText: String
    var isFiled: Bool
    var hasLinks: Bool
}
