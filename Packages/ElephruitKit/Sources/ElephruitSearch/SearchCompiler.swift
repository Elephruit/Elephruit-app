import ElephruitCore
import Foundation

/// A value bound to a statement parameter.
///
/// The point of this type is that **no user text ever reaches the SQL string**. Terms, tag slugs,
/// container titles and people's names all arrive as bound parameters, so a note titled
/// `"; DROP TABLE entries; --` is a search for that phrase and nothing more.
enum SQLiteBinding: Sendable, Hashable {
    case text(String)
    case number(Double)
    case integer(Int)

    func apply(to statement: SQLiteStatement, at index: Int32) {
        switch self {
        case .text(let value): statement.bind(value, at: index)
        case .number(let value): statement.bind(value, at: index)
        case .integer(let value): statement.bind(value, at: index)
        }
    }
}

/// Which extra columns a compiled query selects, and how to read them.
///
/// A structural-only query — `is:open type:task` with no words — never touches the full-text tables,
/// so there is no rank and no snippet to read. Encoding that here keeps the reader honest: it cannot
/// ask for a snippet column that the query did not select.
enum SearchMode: Sendable, Hashable {
    /// No text at all. Ordered by the caller's sort, not by relevance.
    case structural
    /// Tokenised full-text match, with rank and both snippets.
    case fullText
    /// Trigram substring match over titles. Ranked, with a title snippet only.
    case trigram

    var rankColumn: Int32? {
        switch self {
        case .structural: nil
        case .fullText, .trigram: 23
        }
    }

    var snippetColumn: Int32? {
        switch self {
        case .structural, .trigram: nil
        case .fullText: 24
        }
    }

    var titleSnippetColumn: Int32? {
        switch self {
        case .structural: nil
        case .fullText: 25
        case .trigram: 24
        }
    }

    /// Nudges applied after ranking.
    ///
    /// Deliberately small, and deliberately applied to the page rather than used to pull a distant
    /// result forward: pinning something is a statement about which of two equally good matches you
    /// meant, not a claim that it should beat a much better one.
    func bonus(favorite: Bool, pinned: Bool) -> Double {
        guard self != .structural else { return 0 }
        return (pinned ? 0.5 : 0) + (favorite ? 0.25 : 0)
    }
}

/// A query translated into SQL, ready to run.
struct CompiledSearch: Sendable {
    var sql: String
    var bindings: [SQLiteBinding]
    var limit: Int
    var mode: SearchMode

    func bind(to statement: SQLiteStatement) {
        for (offset, binding) in bindings.enumerated() {
            binding.apply(to: statement, at: Int32(offset + 1))
        }
    }
}

/// Turns a parsed ``SearchQuery`` into SQL.
///
/// ### Why every filter goes into SQL
/// The v1 engine matched text against an in-memory index, materialised every candidate as a
/// SwiftData object, and *then* applied kind, tag, state and date filters in Swift. A query like
/// `is:open due:<7d` therefore loaded the whole library to return eleven rows. Here the filters are
/// a `WHERE` clause and the database returns only what matches, so the cost tracks the size of the
/// answer rather than the size of the library.
enum SearchCompiler {
    /// Column weights for `bm25`, in the order the FTS table declares them.
    ///
    /// Title is worth ten times a body mention. Someone searching "launch" almost always wants the
    /// thing *called* launch, not the thirty notes that mention it in passing. People and tags sit
    /// above body for the same reason — they are labels, chosen deliberately, not prose.
    static let columnWeights = "10.0, 1.0, 3.0, 2.0, 4.0"

    /// Marks that wrap a match inside a snippet.
    ///
    /// Control characters rather than markup, because the result is plain text that must survive
    /// being rendered by SwiftUI without anyone parsing HTML. Nothing a user can type collides.
    static let highlightOpen = "\u{2}"
    static let highlightClose = "\u{3}"

    /// The display columns, always selected in this order. Positions 0…22.
    private static let selection = """
        e.item_id, e.kind, e.title, e.status, e.priority, e.excerpt, e.tag_slugs,
        e.parent_id, e.parent_title, e.symbol_name, e.color_name, e.day_key,
        e.created_at, e.updated_at, e.start_at, e.due_at, e.defer_until,
        e.completed_at, e.archived_at, e.deleted_at, e.is_favorite, e.is_pinned, e.sort_order
        """

    // MARK: - Entry point

    static func compile(
        _ query: SearchQuery,
        limit: Int,
        dateProvider: any DateProvider
    ) -> CompiledSearch {
        var bindings: [SQLiteBinding] = []
        let match = matchExpression(for: query)

        // The MATCH parameter must be bound first, because it appears first in the SQL.
        if let match {
            bindings.append(.text(match))
        }

        var clauses: [String] = []
        appendScopeClauses(query, to: &clauses, bindings: &bindings)
        appendKindClause(query, to: &clauses, bindings: &bindings)
        appendTagClauses(query, to: &clauses, bindings: &bindings)
        appendStateClauses(query, to: &clauses, bindings: &bindings, dateProvider: dateProvider)
        appendDateClauses(query, to: &clauses, bindings: &bindings, dateProvider: dateProvider)

        let whereClause = clauses.isEmpty ? "" : "\n  AND " + clauses.joined(separator: "\n  AND ")

        guard match != nil else {
            bindings.append(.integer(limit))
            return CompiledSearch(
                sql: structuralSQL(where: whereClause, limitIndex: bindings.count),
                bindings: bindings,
                limit: limit,
                mode: .structural
            )
        }

        bindings.append(.integer(limit))
        return CompiledSearch(
            sql: fullTextSQL(where: whereClause, limitIndex: bindings.count),
            bindings: bindings,
            limit: limit,
            mode: .fullText
        )
    }

    /// A substring query over titles, for when the tokenised search found too little.
    ///
    /// Separate rather than folded into the main query because the two match different things and
    /// combining them with `OR` would let a weak substring hit outrank a strong word hit.
    static func compileTrigram(
        _ query: SearchQuery,
        limit: Int,
        dateProvider: any DateProvider
    ) -> CompiledSearch? {
        // The trigram tokenizer cannot answer anything shorter than three characters.
        let usable = query.terms.filter { $0.count >= 3 }
        guard !usable.isEmpty else { return nil }

        var bindings: [SQLiteBinding] = [.text(usable.map(quoted).joined(separator: " AND "))]

        var clauses: [String] = []
        appendScopeClauses(query, to: &clauses, bindings: &bindings)
        appendKindClause(query, to: &clauses, bindings: &bindings)
        appendTagClauses(query, to: &clauses, bindings: &bindings)
        appendStateClauses(query, to: &clauses, bindings: &bindings, dateProvider: dateProvider)
        appendDateClauses(query, to: &clauses, bindings: &bindings, dateProvider: dateProvider)

        let whereClause = clauses.isEmpty ? "" : "\n  AND " + clauses.joined(separator: "\n  AND ")
        bindings.append(.integer(limit))

        let sql = """
            SELECT \(selection),
                   bm25(title_trigrams),
                   snippet(title_trigrams, 0, '\(highlightOpen)', '\(highlightClose)', '', 32)
            FROM title_trigrams
            JOIN entries e ON e.rowid = title_trigrams.rowid
            WHERE title_trigrams MATCH ?1\(whereClause)
            ORDER BY bm25(title_trigrams) ASC, e.updated_at DESC
            LIMIT ?\(bindings.count);
            """

        return CompiledSearch(sql: sql, bindings: bindings, limit: limit, mode: .trigram)
    }

    // MARK: - SQL shapes

    private static func fullTextSQL(where whereClause: String, limitIndex: Int) -> String {
        """
        SELECT \(selection),
               bm25(documents, \(columnWeights)),
               snippet(documents, 1, '\(highlightOpen)', '\(highlightClose)', '…', 12),
               snippet(documents, 0, '\(highlightOpen)', '\(highlightClose)', '', 32)
        FROM documents
        JOIN entries e ON e.rowid = documents.rowid
        WHERE documents MATCH ?1\(whereClause)
        ORDER BY bm25(documents, \(columnWeights)) ASC, e.updated_at DESC
        LIMIT ?\(limitIndex);
        """
    }

    private static func structuralSQL(where whereClause: String, limitIndex: Int) -> String {
        // `1 = 1` so the generated `AND` chain needs no special case for the first clause.
        """
        SELECT \(selection)
        FROM entries e
        WHERE 1 = 1\(whereClause)
        ORDER BY e.is_pinned DESC, e.updated_at DESC
        LIMIT ?\(limitIndex);
        """
    }

    // MARK: - The MATCH expression

    /// Builds the FTS5 query string, or `nil` when nothing needs full-text matching.
    ///
    /// Every fragment is a quoted string, so FTS5's own operators — `AND`, `OR`, `NOT`, `*`, `(`,
    /// `"` — are inert when they appear in something the user typed.
    static func matchExpression(for query: SearchQuery) -> String? {
        var clauses: [String] = []

        // All but the last term are complete words. The last one is treated as a prefix, because
        // the user is very likely still typing it — that is what makes results appear as you go
        // rather than only once a word is finished.
        for (offset, term) in query.terms.enumerated() {
            let isLast = offset == query.terms.count - 1
            clauses.append(isLast ? quoted(term) + "*" : quoted(term))
        }

        for title in query.containerTitles.sorted() {
            clauses.append("{container} : \(quoted(title))")
        }

        for name in query.peopleNames.sorted() {
            clauses.append("{people} : \(quoted(name))")
        }

        guard !clauses.isEmpty else { return nil }
        return clauses.joined(separator: " AND ")
    }

    /// Wraps a value as an FTS5 string literal, doubling any embedded quote.
    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Structural clauses

    private static func appendScopeClauses(
        _ query: SearchQuery,
        to clauses: inout [String],
        bindings: inout [SQLiteBinding]
    ) {
        // The Trash is only ever searched when it is asked for by name. Finding a deleted item in
        // ordinary results would make deletion feel like it had not worked.
        clauses.append("e.is_trashed = \(query.states.contains(.trashed) ? 1 : 0)")

        if !query.states.contains(.archived) {
            clauses.append("e.is_archived = 0")
        }
    }

    private static func appendKindClause(
        _ query: SearchQuery,
        to clauses: inout [String],
        bindings: inout [SQLiteBinding]
    ) {
        guard !query.kinds.isEmpty else {
            // Structural kinds — headings — stay out of global results unless named. A heading is a
            // label inside a project, and a list of them answers no question anyone asked.
            clauses.append("e.in_content_views = 1")
            return
        }

        let placeholders = query.kinds.sorted { $0.rawValue < $1.rawValue }.map { kind -> String in
            bindings.append(.text(kind.rawValue))
            return "?\(bindings.count)"
        }
        clauses.append("e.kind IN (\(placeholders.joined(separator: ", ")))")
    }

    private static func appendTagClauses(
        _ query: SearchQuery,
        to clauses: inout [String],
        bindings: inout [SQLiteBinding]
    ) {
        for slug in query.tagSlugs.sorted() {
            bindings.append(.text(slug))
            let exact = bindings.count

            // A parent tag matches its children: `tag:work` finds `work/clients`. Expressed as a
            // range over the slug index rather than a `LIKE`, so it stays an index seek —
            // `/` is 0x2F, so every child sorts below the same prefix followed by `0`.
            bindings.append(.text(slug + "/"))
            let lowerBound = bindings.count
            bindings.append(.text(slug + "0"))
            let upperBound = bindings.count

            clauses.append(
                """
                EXISTS (
                    SELECT 1 FROM entry_tags t
                    WHERE t.entry_rowid = e.rowid
                      AND (t.slug = ?\(exact) OR (t.slug >= ?\(lowerBound) AND t.slug < ?\(upperBound)))
                )
                """
            )
        }
    }

    private static func appendStateClauses(
        _ query: SearchQuery,
        to clauses: inout [String],
        bindings: inout [SQLiteBinding],
        dateProvider: any DateProvider
    ) {
        for state in query.states.sorted(by: { $0.rawValue < $1.rawValue }) {
            switch state {
            case .open:
                clauses.append("e.status = 'open'")
            case .completed:
                clauses.append("e.status = 'completed'")
            case .cancelled:
                clauses.append("e.status = 'cancelled'")
            case .favorite:
                clauses.append("e.is_favorite = 1")
            case .pinned:
                clauses.append("e.is_pinned = 1")
            case .untagged:
                clauses.append("e.has_tags = 0")
            case .unfiled:
                clauses.append("e.is_filed = 0")
            case .linked:
                clauses.append("e.has_links = 1")
            case .unlinked:
                clauses.append("e.has_links = 0")
            case .overdue:
                // Mirrors `ContentItem.isOverdue`: only an open, actionable item can be overdue.
                // A completed task with a date in the past is simply done.
                bindings.append(.number(dateProvider.startOfToday.timeIntervalSinceReferenceDate))
                clauses.append("(e.due_at IS NOT NULL AND e.due_at < ?\(bindings.count) AND e.status = 'open')")
            case .archived, .trashed:
                // Handled as scope, above.
                continue
            }
        }
    }

    private static func appendDateClauses(
        _ query: SearchQuery,
        to clauses: inout [String],
        bindings: inout [SQLiteBinding],
        dateProvider: any DateProvider
    ) {
        appendDateClause(query.due, column: "e.due_at", to: &clauses, bindings: &bindings, dateProvider: dateProvider)
        appendDateClause(
            query.created,
            column: "e.created_at",
            to: &clauses,
            bindings: &bindings,
            dateProvider: dateProvider
        )
        appendDateClause(
            query.updated,
            column: "e.updated_at",
            to: &clauses,
            bindings: &bindings,
            dateProvider: dateProvider
        )
    }

    private static func appendDateClause(
        _ constraint: DateConstraint?,
        column: String,
        to clauses: inout [String],
        bindings: inout [SQLiteBinding],
        dateProvider: any DateProvider
    ) {
        guard let constraint else { return }

        switch constraint {
        case .absent:
            clauses.append("\(column) IS NULL")

        case .before(let expression):
            guard let bound = expression.resolve(using: dateProvider) else {
                // An unresolvable date must not silently widen the search to everything.
                clauses.append("0 = 1")
                return
            }
            bindings.append(.number(bound.timeIntervalSinceReferenceDate))
            clauses.append("(\(column) IS NOT NULL AND \(column) < ?\(bindings.count))")

        case .after(let expression):
            guard let bound = expression.resolve(using: dateProvider) else {
                clauses.append("0 = 1")
                return
            }
            bindings.append(.number(bound.timeIntervalSinceReferenceDate))
            clauses.append("(\(column) IS NOT NULL AND \(column) >= ?\(bindings.count))")

        case .on(let expression):
            guard let start = expression.resolve(using: dateProvider),
                  let end = dateProvider.calendar.date(byAdding: .day, value: 1, to: start)
            else {
                clauses.append("0 = 1")
                return
            }
            bindings.append(.number(start.timeIntervalSinceReferenceDate))
            let lower = bindings.count
            bindings.append(.number(end.timeIntervalSinceReferenceDate))
            clauses.append("(\(column) IS NOT NULL AND \(column) >= ?\(lower) AND \(column) < ?\(bindings.count))")
        }
    }
}

// MARK: - Highlighting

/// Reads the marks `snippet()` leaves around a match.
///
/// `snippet()` returns the matched text wrapped in whatever delimiters we asked for. Turning those
/// into ranges here — rather than shipping marked-up text to the view — keeps presentation out of
/// the search layer and means a result can be rendered as plain text, attributed text, or read
/// aloud, without the markers leaking into any of them.
enum SearchHighlight {
    /// Strips the markers, returning the plain text.
    static func plain(_ marked: String) -> String? {
        let stripped = marked
            .replacingOccurrences(of: SearchCompiler.highlightOpen, with: "")
            .replacingOccurrences(of: SearchCompiler.highlightClose, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped.replacingOccurrences(of: "\n", with: " ")
    }

    /// Character ranges of each marked run, measured in the *stripped* string.
    static func ranges(in marked: String?) -> [Range<Int>] {
        guard let marked else { return [] }

        var ranges: [Range<Int>] = []
        var plainOffset = 0
        var openedAt: Int?

        for character in marked {
            if String(character) == SearchCompiler.highlightOpen {
                openedAt = plainOffset
                continue
            }
            if String(character) == SearchCompiler.highlightClose {
                if let start = openedAt, start < plainOffset {
                    ranges.append(start..<plainOffset)
                }
                openedAt = nil
                continue
            }
            plainOffset += 1
        }

        return ranges
    }
}
