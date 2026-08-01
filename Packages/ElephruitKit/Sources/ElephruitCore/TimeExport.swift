import Foundation

/// Tracked time as a spreadsheet.
///
/// ### Why CSV and not the archive format
/// The archive exists so a library can be restored; this exists so a *report* can be argued with.
/// The person who wants these rows is putting them in an invoice, a timesheet, or somebody else's
/// spreadsheet, and none of those can open a JSON archive. It is deliberately one flat table with no
/// nesting: every tool that reads CSV reads that, and nothing else is guaranteed.
///
/// ### Why the entries and not the report
/// Both, and they answer different questions. ``rows(for:)`` writes one line per stretch, which is
/// what a client asks for when they want to see the work. ``summary(for:)`` writes the report as it
/// is on screen, which is what goes at the bottom of an invoice. Offering only the second would mean
/// the detail could never be produced; only the first would mean every recipient has to rebuild the
/// totals and can get them wrong.
public enum TimeExport {
    /// One line per tracked stretch.
    public static func rows(
        for entries: [TimeEntrySnapshot],
        rounding: TimeRounding = .exact,
        now: Date
    ) -> String {
        let header = [
            "Date", "Start", "End", "Duration", "Hours",
            "Description", "Subject", "Type", "Project", "People", "Tags",
            "Billable", "Source", "Focus blocks",
        ]

        // Oldest first, which is the order a timesheet is read in. The log shows newest first
        // because it is a thing you correct; a spreadsheet is a thing you total.
        let lines = entries
            .sorted { $0.startedAt < $1.startedAt }
            .map { entry -> String in
                let duration = rounding.apply(entry.duration(at: now))
                return field([
                    entry.startedAt.formatted(.iso8601.year().month().day().dateSeparator(.dash)),
                    clockTime(entry.startedAt),
                    entry.endedAt.map(clockTime) ?? "",
                    TimeFormatting.clock(duration),
                    TimeFormatting.decimalHours(duration),
                    entry.entryDescription,
                    entry.itemTitle ?? "",
                    entry.itemKind?.displayName ?? "",
                    entry.projectTitle ?? "",
                    entry.people.map(\.name).joined(separator: "; "),
                    entry.tagSlugs.sorted().joined(separator: "; "),
                    entry.isBillable ? "Yes" : "No",
                    entry.source.displayName,
                    entry.focusRounds == 0 ? "" : "\(entry.focusRounds)",
                ])
            }

        return ([field(header)] + lines).joined(separator: "\r\n") + "\r\n"
    }

    /// One line per report row, plus the total.
    public static func summary(for report: TimeReport, grouping: TimeGrouping) -> String {
        let header = [grouping.displayName, "Entries", "Duration", "Hours", "Billable hours"]

        let lines = report.rows.map { row in
            field([
                row.title,
                "\(row.entryCount)",
                TimeFormatting.clock(row.total),
                TimeFormatting.decimalHours(row.total),
                TimeFormatting.decimalHours(row.billable),
            ])
        }

        // The total is a row, not a footnote, because that is where a spreadsheet expects to find it
        // — and it is the report's own total rather than the sum of the column above, which for a
        // tag or person grouping is deliberately larger.
        let total = field([
            "Total",
            "\(report.entryCount)",
            TimeFormatting.clock(report.total),
            TimeFormatting.decimalHours(report.total),
            TimeFormatting.decimalHours(report.billable),
        ])

        return ([field(header)] + lines + [total]).joined(separator: "\r\n") + "\r\n"
    }

    /// A filename that says what the file holds without being opened.
    public static func filename(for period: String, kind: String) -> String {
        let slug = TextNormalizer.slug(period)
        return "elephruit-time-\(kind)-\(slug.isEmpty ? "report" : slug).csv"
    }

    // MARK: - Escaping

    /// One CSV line.
    ///
    /// Every field is quoted rather than only the ones that need it. Conditional quoting is where
    /// CSV writers go wrong — a description containing a comma, a quote, or a newline is not
    /// unusual, it is Tuesday — and a file that is right for most rows is worse than one that is
    /// obviously verbose, because the failure appears halfway down somebody else's spreadsheet.
    private static func field(_ values: [String]) -> String {
        values
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: ",")
    }

    /// `14:32`, always twenty-four hour and never localised.
    ///
    /// A spreadsheet column has to sort, and a locale that writes "2:32 PM" sorts the afternoon
    /// before the morning. What the user reads on screen is localised; what leaves the app is not.
    private static func clockTime(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return "\(DayKey.padded(parts.hour ?? 0)):\(DayKey.padded(parts.minute ?? 0))"
    }
}
