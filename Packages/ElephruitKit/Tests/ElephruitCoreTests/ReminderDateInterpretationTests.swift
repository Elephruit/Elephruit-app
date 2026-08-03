import ElephruitCore
import Foundation
import Testing

private let clock = FixedDateProvider.reference

@Suite("Reminder date suggestions")
struct ReminderDateInterpretationTests {
    /// Phrases people type when they are in a hurry.
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

    @Test("Common phrases resolve")
    func commonPhrasesResolve() throws {
        for phrase in Self.phrases {
            _ = try #require(
                ReminderDateInterpretation.resolving(phrase, using: clock),
                "the reminder field did not understand “\(phrase)”"
            )
        }
    }

    @Test("Nothing is offered for text that is not a date")
    func nonsenseResolvesToNothing() {
        // The field is a date field, and a field that guesses is worse than one that waits. An empty
        // popover suggestion is how the user finds out the phrase was not understood, before
        // anything has been written.
        for text in ["", "   ", "buy milk", "asdf", "the tuesday after the bank holiday"] {
            #expect(ReminderDateInterpretation.resolving(text, using: clock) == nil, "“\(text)” resolved")
        }
    }

    @Test("Surrounding whitespace is not part of the phrase")
    func trimsBeforeParsing() throws {
        let plain = try #require(ReminderDateInterpretation.resolving("tomorrow", using: clock))
        let padded = try #require(ReminderDateInterpretation.resolving("  tomorrow  ", using: clock))
        #expect(plain == padded)
    }

    @Test("The row says how far away the day is, in words")
    func relativeWording() throws {
        #expect(ReminderDateInterpretation.resolving("today", using: clock)?.detail == "today")
        #expect(ReminderDateInterpretation.resolving("tomorrow", using: clock)?.detail == "tomorrow")
        #expect(ReminderDateInterpretation.resolving("in 3 days", using: clock)?.detail == "in 3 days")
        #expect(ReminderDateInterpretation.resolving("yesterday", using: clock)?.detail == "yesterday")
    }
}
