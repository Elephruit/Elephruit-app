import ElephruitCore
import Foundation
import Testing

/// The spreadsheet a report leaves the app as.
///
/// Worth testing precisely because nothing in the app reads it back: the first sign of a broken CSV
/// is a column shifted by one halfway down somebody else's invoice.
@Suite("Time export")
struct TimeExportTests {
    private let clock = FixedDateProvider.reference

    private func entry(
        from start: TimeInterval,
        to end: TimeInterval,
        description: String = "",
        tags: [String] = [],
        billable: Bool = false
    ) -> TimeEntrySnapshot {
        TimeEntrySnapshot(
            id: UUID(),
            startedAt: clock.startOfToday.addingTimeInterval(start),
            endedAt: clock.startOfToday.addingTimeInterval(end),
            entryDescription: description,
            isBillable: billable,
            tagSlugs: tags
        )
    }

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
    }

    @Test("Every field is quoted, so a comma in a description cannot shift a column")
    func fieldsAreAlwaysQuoted() {
        let text = TimeExport.rows(
            for: [entry(from: 0, to: 3_600, description: "Wrote the brief, then rewrote it")],
            now: clock.now
        )

        #expect(text.contains("\"Wrote the brief, then rewrote it\""))
        #expect(lines(text).count == 2, "A comma must not become a row break")
    }

    @Test("A quote in a description is doubled rather than left to end the field")
    func quotesAreEscaped() {
        let text = TimeExport.rows(
            for: [entry(from: 0, to: 3_600, description: "Called it \"done\"")],
            now: clock.now
        )

        #expect(text.contains("\"Called it \"\"done\"\"\""))
        #expect(lines(text).count == 2)
    }

    @Test("Entries come out oldest first, which is the order a timesheet is read in")
    func entriesAreChronological() {
        let text = TimeExport.rows(
            for: [
                entry(from: 7_200, to: 10_800, description: "Second"),
                entry(from: 0, to: 3_600, description: "First"),
            ],
            now: clock.now
        )

        let rows = lines(text)
        #expect(rows.count == 3)
        #expect(rows[1].contains("First"))
        #expect(rows[2].contains("Second"))
    }

    @Test("Rounding reaches the exported duration as well as the screen")
    func roundingIsExported() {
        // Fifty-one minutes at a tenth of an hour is 0.90, not 0.85. A report that rounded on screen
        // and not in the file would be two documents that disagree.
        let text = TimeExport.rows(
            for: [entry(from: 0, to: 3_060)],
            rounding: .upSixMinutes,
            now: clock.now
        )

        #expect(text.contains("\"0.90\""))
    }

    @Test("A summary ends with the report's own total, not the sum of its rows")
    func summaryCarriesTheReportTotal() throws {
        // A tag report's rows deliberately add up to more than the period contains, because an entry
        // with two tags counts in full under each. The Total row has to be the period, or the file
        // says the week was longer than it was.
        let report = TimeReporting.report(
            entries: [entry(from: 0, to: 3_600, tags: ["writing", "client"])],
            grouping: .tag,
            range: clock.startOfToday..<clock.startOfToday.addingTimeInterval(86_400),
            calendar: clock.calendar,
            now: clock.now
        )

        let rows = lines(TimeExport.summary(for: report, grouping: .tag))
        let total = try #require(rows.last)

        #expect(rows.count == 4, "A header, two tags, and a total")
        #expect(total.hasPrefix("\"Total\""))
        #expect(total.contains("\"1.00\""))
    }

    @Test("A filename says what it holds and survives a period with punctuation in it")
    func filenamesAreSafe() {
        #expect(TimeExport.filename(for: "Last Week", kind: "summary") == "elephruit-time-summary-last-week.csv")
        #expect(TimeExport.filename(for: "3 Feb – 17 Feb 2026", kind: "entries").hasSuffix(".csv"))
        #expect(!TimeExport.filename(for: "3 Feb – 17 Feb 2026", kind: "entries").contains("/"))
    }
}
