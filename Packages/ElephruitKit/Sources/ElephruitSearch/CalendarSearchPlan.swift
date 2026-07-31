import ElephruitCore
import Foundation

/// One calendar query, compiled to SQL.
///
/// ### Why the filters are a `WHERE` clause rather than a filter over results
/// Because "events in Austin last year" on a working calendar is a handful of rows out of tens of
/// thousands, and the difference between finding them in the index and materialising the year to
/// filter it is the difference between a search field that answers as you type and one that does not.
/// This is the same argument `SearchCompiler` makes for items, applied to the same substrate.
///
/// Every value is bound, never interpolated. The only thing built into the SQL string is the *shape*
/// of the query, which is composed here from literals.
struct CalendarSearchPlan {
    let query: EventSearchQuery
    let now: Date
    let limit: Int

    /// Whether the SELECT carries a snippet column, which only a text query does.
    var selectsSnippet: Bool { !matchExpression.isEmpty }

    /// The FTS5 MATCH expression, or empty when the query has no words.
    private var matchExpression: String {
        var pieces: [String] = []

        // Ordinary words match anywhere in the document, as prefixes, so typing resolves as you go.
        for term in query.terms {
            let cleaned = Self.escape(term)
            guard !cleaned.isEmpty else { continue }
            pieces.append("\"\(cleaned)\"*")
        }

        // A person narrows to the attendee and linked columns rather than to the document as a
        // whole: "with:maya" must not match a meeting whose notes happen to mention her.
        for name in query.peopleNames {
            let cleaned = Self.escape(name)
            guard !cleaned.isEmpty else { continue }
            pieces.append("(attendees : \"\(cleaned)\"* OR linked : \"\(cleaned)\"*)")
        }

        for place in query.locations {
            let cleaned = Self.escape(place)
            guard !cleaned.isEmpty else { continue }
            pieces.append("location : \"\(cleaned)\"*")
        }

        for project in query.projectNames {
            let cleaned = Self.escape(project)
            guard !cleaned.isEmpty else { continue }
            pieces.append("linked : \"\(cleaned)\"*")
        }

        return pieces.joined(separator: " AND ")
    }

    /// FTS5 syntax characters, removed; the remainder is then quoted at the call site.
    ///
    /// Both halves are needed. Stripping punctuation deals with `-` and `"`, which are operators
    /// rather than characters as far as FTS5 is concerned. Quoting deals with the words `AND`, `OR`,
    /// `NOT` and `NEAR`, which survive the strip intact and are still keywords — so a search for
    /// "and then what" would otherwise be a syntax error thrown at somebody for typing English.
    static func escape(_ term: String) -> String {
        let allowed = term.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == " " || scalar == "_"
        }
        return String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - SQL

    var sql: String {
        var clauses: [String] = []
        var parameter = 1

        let selection = selectsSnippet
            ? "SELECT \(CalendarIndexStore.selectedColumns), " +
              "snippet(event_documents, -1, '\u{2}', '\u{3}', '…', 12) FROM events " +
              "JOIN event_documents ON event_documents.rowid = events.rowid"
            : "SELECT \(CalendarIndexStore.selectedColumns) FROM events"

        if selectsSnippet {
            clauses.append("event_documents MATCH ?\(parameter)")
            parameter += 1
        }

        if query.dateRange != nil {
            clauses.append("events.start_at < ?\(parameter) AND events.end_at > ?\(parameter + 1)")
            parameter += 2
        }

        if !query.calendarNames.isEmpty {
            // Matched with `LIKE` rather than through the index, because a person types "work" for a
            // calendar called "Work — Acme" and expects it to match. There are tens of calendars,
            // never thousands, so the scan is over a column of a few dozen distinct values.
            let pieces = query.calendarNames.sorted().map { _ -> String in
                let clause = "LOWER(events.calendar_name) LIKE ?\(parameter)"
                parameter += 1
                return clause
            }
            clauses.append("(" + pieces.joined(separator: " OR ") + ")")
        }

        for flag in query.flags.sorted(by: { $0.rawValue < $1.rawValue }) {
            switch flag {
            case .recurring: clauses.append("events.is_recurring = 1")
            case .notRecurring: clauses.append("events.is_recurring = 0")
            case .allDay: clauses.append("events.is_all_day = 1")
            case .timed: clauses.append("events.is_all_day = 0")
            case .withNotes: clauses.append("events.has_notes = 1")
            case .withoutNotes: clauses.append("events.has_notes = 0")
            case .withPeople: clauses.append("events.has_attendees = 1")
            case .withAttachments: clauses.append("events.has_attachments = 1")
            case .withLinks: clauses.append("events.has_links = 1")
            case .declined: clauses.append("events.is_declined = 1")
            case .cancelled: clauses.append("events.is_cancelled = 1")
            case .past:
                clauses.append("events.end_at < ?\(parameter)")
                parameter += 1
            case .upcoming:
                clauses.append("events.start_at >= ?\(parameter)")
                parameter += 1
            }
        }

        // Declined events are hidden unless asked for by name. A meeting somebody said no to is not
        // part of their history, and it fills a search for "lunches" with lunches they did not eat.
        if !query.flags.contains(.declined) {
            clauses.append("events.is_declined = 0")
        }

        var statement = selection
        if !clauses.isEmpty {
            statement += " WHERE " + clauses.joined(separator: " AND ")
        }

        // Ranked by relevance when there are words, and by time when there are not — because a
        // structural query like "recurring events on my Work calendar" has no relevance to rank by,
        // and the useful order for it is the one a calendar is already in.
        statement += selectsSnippet
            ? " ORDER BY bm25(event_documents, 8.0, 4.0, 1.0, 4.0, 3.0), events.start_at DESC"
            : " ORDER BY events.start_at DESC"

        statement += " LIMIT ?\(parameter);"
        return statement
    }

    func bind(to statement: SQLiteStatement) {
        var parameter: Int32 = 1

        if selectsSnippet {
            statement.bind(matchExpression, at: parameter)
            parameter += 1
        }

        if let range = query.dateRange {
            statement.bind(range.upperBound, at: parameter)
            statement.bind(range.lowerBound, at: parameter + 1)
            parameter += 2
        }

        for name in query.calendarNames.sorted() {
            statement.bind("%\(name.lowercased())%", at: parameter)
            parameter += 1
        }

        for flag in query.flags.sorted(by: { $0.rawValue < $1.rawValue }) {
            switch flag {
            case .past, .upcoming:
                statement.bind(now, at: parameter)
                parameter += 1
            default:
                break
            }
        }

        statement.bind(limit, at: parameter)
    }
}
