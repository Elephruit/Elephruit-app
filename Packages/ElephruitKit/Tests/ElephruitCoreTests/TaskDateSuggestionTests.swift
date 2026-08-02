import ElephruitCore
import Foundation
import Testing

private let clock = FixedDateProvider.reference

/// ### Why one grammar rather than two
/// A date phrase can now be typed in two places: the capture field, which has understood "next tue"
/// since the module was built, and the *When* and *Deadline* fields on a task. If those two were
/// parsed separately they would agree on the easy cases and diverge on the ones that matter —
/// month rollover, "next" on the current weekday, a phrase the second parser had never been taught.
/// The user would have no way to know which surface they were talking to.
///
/// So both go through ``NaturalDateParser/interpret(_:)``, and this suite is what stops that becoming
/// two functions again.
@Suite("The date fields and quick entry read the same phrase the same way")
struct TaskDateSuggestionTests {
    /// Phrases the capture field's own documentation advertises, plus the ones a person types when
    /// they are in a hurry.
    private static let phrases = [
        "today",
        "tomorrow",
        "next tue",
        "next monday",
        "friday",
        "in 3 days",
        "next week",
        "august 15",
    ]

    @Test("Every phrase resolves to the same day in a task field as in quick entry")
    func oneGrammar() throws {
        for phrase in Self.phrases {
            let typed = try #require(
                TaskDateSuggestion.resolving(phrase, using: clock),
                "the task field did not understand “\(phrase)”"
            )

            // The capture field parses a whole sentence and lifts the date out of it, so the phrase
            // is given to it the way somebody would actually type it.
            let draft = TaskEntryParser.parse("Draft the brief \(phrase)")
            let captured = try #require(
                draft.startDate?.resolve(using: clock),
                "quick entry did not understand “\(phrase)”"
            )

            #expect(
                clock.calendar.isDate(typed.date, inSameDayAs: captured),
                "“\(phrase)” means \(typed.date) in a task field and \(captured) in quick entry"
            )
        }
    }

    @Test("Nothing is offered for text that is not a date")
    func nonsenseResolvesToNothing() {
        // The field is a date field, and a field that guesses is worse than one that waits. An empty
        // popover suggestion is how the user finds out the phrase was not understood, before
        // anything has been written.
        for text in ["", "   ", "buy milk", "asdf", "the tuesday after the bank holiday"] {
            #expect(TaskDateSuggestion.resolving(text, using: clock) == nil, "“\(text)” resolved")
        }
    }

    @Test("Surrounding whitespace is not part of the phrase")
    func trimsBeforeParsing() throws {
        let plain = try #require(TaskDateSuggestion.resolving("tomorrow", using: clock))
        let padded = try #require(TaskDateSuggestion.resolving("  tomorrow  ", using: clock))
        #expect(plain == padded)
    }

    @Test("The row says how far away the day is, in words")
    func relativeWording() throws {
        #expect(TaskDateSuggestion.resolving("today", using: clock)?.detail == "today")
        #expect(TaskDateSuggestion.resolving("tomorrow", using: clock)?.detail == "tomorrow")
        #expect(TaskDateSuggestion.resolving("in 3 days", using: clock)?.detail == "in 3 days")
        #expect(TaskDateSuggestion.resolving("yesterday", using: clock)?.detail == "yesterday")
    }
}
