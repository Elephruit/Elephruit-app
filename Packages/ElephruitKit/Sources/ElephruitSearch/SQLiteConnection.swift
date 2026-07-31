import ElephruitCore
import Foundation
import SQLite3

/// A thin, safe wrapper over the system SQLite C API.
///
/// ### Why raw SQLite rather than a wrapper library
/// FTS5 is the only full-text engine available on the platform that gives ranked, prefix-aware,
/// tokenised search with snippet extraction, and it is reached through `sqlite3_*`. Every Swift
/// wrapper worth using is a third-party dependency, and the brief rules those out unless they solve
/// something Apple's frameworks cannot. They do not: the surface actually needed here is *open,
/// prepare, bind, step, finalize*. That is this file, in about two hundred lines, with no
/// dependency, no version drift, and no unowned C pointers escaping past its own boundary.
///
/// ### Ownership
/// A connection is **not** `Sendable` and must not cross an isolation boundary. ``SearchIndexStore``
/// is an `actor` and owns exactly one, which is what makes the whole thing safe: SQLite's own
/// threading modes never come into it because the connection is only ever touched from one place.
final class SQLiteConnection {
    /// SQLite's "copy this buffer before returning" destructor.
    ///
    /// The C constant is a cast of `-1`, and the macro that defines it does not survive into Swift.
    /// Without it, a bound `String` would be freed while the statement still pointed at it — the
    /// classic use-after-free in this API.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var handle: OpaquePointer?

    /// Statements are compiled once and reused. Preparing SQL is the expensive half of a small
    /// query, and the hot path here runs on every keystroke.
    private var cachedStatements: [String: OpaquePointer] = [:]

    let path: String

    // MARK: - Lifecycle

    /// Opens — or creates — a database at `url`.
    init(url: URL) throws(AppError) {
        path = url.path(percentEncoded: false)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)

        guard status == SQLITE_OK, let handle else {
            // `sqlite3_open_v2` can hand back a handle even on failure, and it is the only way to
            // read the error message. Close it either way rather than leaking it.
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close_v2(handle) }
            throw .storeUnavailable(underlying: "Could not open the search index: \(message)")
        }

        self.handle = handle

        // WAL keeps readers from blocking on the writer, which matters because a rebuild writes for
        // seconds at a time while the user is still typing into the search field.
        try execute("PRAGMA journal_mode = WAL")

        // `OFF`, not `NORMAL`. This is the one place in the app where durability genuinely does not
        // matter: every row is derived from the store, so a power cut mid-write costs a rebuild and
        // nothing else. Paying for fsync here would slow every write to protect data that is already
        // safe somewhere else.
        try execute("PRAGMA synchronous = OFF")

        try execute("PRAGMA temp_store = MEMORY")
        try execute("PRAGMA foreign_keys = OFF")

        // No `mmap_size` or `cache_size` tuning here on purpose. Both were tried while chasing a
        // fifty-fold slowdown and neither moved the numbers — the cause turned out to be a failed
        // checkpoint silently switching search onto the store fallback. Left at SQLite's defaults
        // rather than kept as cargo, since nothing measured says they help.

        // Wait rather than fail if the writer holds the lock. A search running during a rebuild
        // should be a little slower, never an error.
        try execute("PRAGMA busy_timeout = 2000")
    }

    deinit {
        for statement in cachedStatements.values {
            sqlite3_finalize(statement)
        }
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    /// Closes the connection early, before deinit.
    ///
    /// Needed when the file is about to be deleted: an open handle on a unlinked file keeps the WAL
    /// alive and makes the recreate behave strangely.
    func close() {
        for statement in cachedStatements.values {
            sqlite3_finalize(statement)
        }
        cachedStatements.removeAll()
        if let handle {
            sqlite3_close_v2(handle)
        }
        handle = nil
    }

    // MARK: - Statements

    /// Runs SQL that returns no rows.
    func execute(_ sql: String) throws(AppError) {
        guard let handle else { throw Self.closedError }

        var errorPointer: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorPointer)

        guard status == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorPointer)
            throw Self.failure(sql: sql, message: message)
        }
        sqlite3_free(errorPointer)
    }

    /// Compiles `sql`, or returns the already-compiled statement for it.
    ///
    /// The returned statement is reset and cleared, so a caller always receives it in the same
    /// state regardless of how the previous use ended.
    func prepared(_ sql: String) throws(AppError) -> SQLiteStatement {
        guard let handle else { throw Self.closedError }

        if let cached = cachedStatements[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return SQLiteStatement(handle: cached, connection: self)
        }

        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)

        guard status == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw Self.failure(sql: sql, message: lastErrorMessage)
        }

        cachedStatements[sql] = statement
        return SQLiteStatement(handle: statement, connection: self)
    }

    /// Compiles a statement without caching it.
    ///
    /// For SQL built per call — the search query, whose shape varies with the filters in play.
    /// Caching those would grow without bound.
    func makeTransient(_ sql: String) throws(AppError) -> SQLiteTransientStatement {
        guard let handle else { throw Self.closedError }

        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)

        guard status == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw Self.failure(sql: sql, message: lastErrorMessage)
        }

        return SQLiteTransientStatement(handle: statement, connection: self)
    }

    // MARK: - Transactions

    /// Runs `body` inside a transaction, committing on success and rolling back on any throw.
    ///
    /// A rebuild inserting fifty thousand rows outside a transaction would be fifty thousand
    /// separate commits, each with its own fsync — minutes rather than seconds.
    func transaction<T>(_ body: () throws -> T) throws(AppError) -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            // A failed rollback would mean the connection is already unusable, so the original
            // error is the one worth reporting.
            try? execute("ROLLBACK")
            if let appError = error as? AppError { throw appError }
            throw .writeFailed(path: path, reason: error.localizedDescription)
        }
    }

    // MARK: - Errors

    var lastErrorMessage: String {
        guard let handle else { return "the connection is closed" }
        return String(cString: sqlite3_errmsg(handle))
    }

    private static var closedError: AppError {
        .storeUnavailable(underlying: "The search index connection is closed.")
    }

    /// Builds an error without putting the SQL's *values* anywhere near it.
    ///
    /// Only the statement text — which is a literal in this module — is included. Bound values are
    /// the user's own words, and an error string can reach a log.
    static func failure(sql: String, message: String) -> AppError {
        let firstLine = sql.split(separator: "\n").first.map(String.init) ?? sql
        return .writeFailed(path: "search index", reason: "\(message) [\(firstLine.prefix(80))]")
    }

    fileprivate static var transientDestructor: sqlite3_destructor_type { transient }
}

// MARK: - Statement

/// A borrowed handle on a cached, compiled statement.
///
/// Deliberately not the owner: the connection finalizes it. This exists so binding and stepping read
/// as ordinary Swift rather than as a run of C calls, and so an index off by one becomes a compile
/// error rather than a silent `NULL`.
struct SQLiteStatement {
    fileprivate let handle: OpaquePointer
    fileprivate let connection: SQLiteConnection

    // MARK: Binding

    /// Binds one-based parameter `index`. `nil` binds SQL NULL.
    func bind(_ value: String?, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(handle, index)
            return
        }
        sqlite3_bind_text(handle, index, value, -1, SQLiteConnection.transientDestructor)
    }

    func bind(_ value: Double?, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(handle, index)
            return
        }
        sqlite3_bind_double(handle, index, value)
    }

    func bind(_ value: Int, at index: Int32) {
        sqlite3_bind_int64(handle, index, Int64(value))
    }

    func bind(_ value: Bool, at index: Int32) {
        sqlite3_bind_int(handle, index, value ? 1 : 0)
    }

    func bind(_ value: Date?, at index: Int32) {
        bind(value?.timeIntervalSinceReferenceDate, at: index)
    }

    // MARK: Stepping

    /// Advances to the next row. Returns `false` when the statement is done.
    @discardableResult
    func step() throws(AppError) -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            throw SQLiteConnection.failure(sql: sqlText, message: connection.lastErrorMessage)
        }
    }

    /// Runs a statement expected to produce no rows.
    func run() throws(AppError) {
        while try step() {}
    }

    // MARK: Reading

    func string(at column: Int32) -> String {
        guard let pointer = sqlite3_column_text(handle, column) else { return "" }
        return String(cString: pointer)
    }

    func optionalString(at column: Int32) -> String? {
        guard sqlite3_column_type(handle, column) != SQLITE_NULL else { return nil }
        return string(at: column)
    }

    func int(at column: Int32) -> Int {
        Int(sqlite3_column_int64(handle, column))
    }

    func bool(at column: Int32) -> Bool {
        sqlite3_column_int(handle, column) != 0
    }

    func double(at column: Int32) -> Double {
        sqlite3_column_double(handle, column)
    }

    func date(at column: Int32) -> Date {
        Date(timeIntervalSinceReferenceDate: sqlite3_column_double(handle, column))
    }

    func optionalDate(at column: Int32) -> Date? {
        guard sqlite3_column_type(handle, column) != SQLITE_NULL else { return nil }
        return date(at: column)
    }

    private var sqlText: String {
        sqlite3_sql(handle).map { String(cString: $0) } ?? "statement"
    }
}

/// A statement this type owns and finalizes.
///
/// A `class` rather than a `struct` because the finalize has to happen exactly once, at a
/// well-defined moment, however the caller leaves scope.
final class SQLiteTransientStatement {
    let statement: SQLiteStatement

    fileprivate init(handle: OpaquePointer, connection: SQLiteConnection) {
        statement = SQLiteStatement(handle: handle, connection: connection)
    }

    deinit {
        sqlite3_finalize(statement.handle)
    }
}
