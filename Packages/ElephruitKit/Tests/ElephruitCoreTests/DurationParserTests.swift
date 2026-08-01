import ElephruitCore
import Foundation
import Testing

@Suite("Typed durations")
struct DurationParserTests {
    // MARK: - Clock form

    @Test(
        "A colon is hours and minutes",
        arguments: [
            ("1:30", 5_400.0),
            ("0:30", 1_800.0),
            (":30", 1_800.0),
            ("12:00", 43_200.0),
            ("1:30:15", 5_415.0),
            ("0:00:45", 45.0),
        ]
    )
    func clockForm(input: String, expected: TimeInterval) {
        #expect(DurationParser.parse(input) == expected)
    }

    @Test("Minutes past sixty are added rather than refused")
    func clockFormIsPermissive() {
        // Somebody adding half an hour to `1:60` in their head types this. Refusing it would leave
        // a field that will not commit and no explanation of why.
        #expect(DurationParser.parse("1:90") == 9_000)
    }

    @Test(
        "A colon that is not a duration is refused",
        arguments: ["1:", "::", "1:2:3:4", "a:30", "1:3o"]
    )
    func clockFormRejectsNonsense(input: String) {
        #expect(DurationParser.parse(input) == nil)
    }

    // MARK: - Unit form

    @Test(
        "Units are summed",
        arguments: [
            ("1h30m", 5_400.0),
            ("1h 30m", 5_400.0),
            ("1 h 30 m", 5_400.0),
            ("90m", 5_400.0),
            ("2h", 7_200.0),
            ("45s", 45.0),
            ("1h30m15s", 5_415.0),
            ("1.5h", 5_400.0),
            ("1,5h", 5_400.0),
        ]
    )
    func unitForm(input: String, expected: TimeInterval) {
        #expect(DurationParser.parse(input) == expected)
    }

    @Test("A bare number after the hours is minutes")
    func trailingMinutes() {
        #expect(DurationParser.parse("1h30") == 5_400)
    }

    @Test(
        "A trailing number nobody could place is refused",
        arguments: ["30m15", "1h30m15", "1 30m", "5x", "h", "hm"]
    )
    func unitFormRejectsNonsense(input: String) {
        #expect(DurationParser.parse(input) == nil)
    }

    @Test("A unit given twice is refused rather than added to itself")
    func repeatedUnits() {
        #expect(DurationParser.parse("1h2h") == nil)
        #expect(DurationParser.parse("10m20m") == nil)
    }

    // MARK: - Bare numbers

    @Test("A bare integer is minutes")
    func bareInteger() {
        #expect(DurationParser.parse("90") == 5_400)
        #expect(DurationParser.parse("5") == 300)
        #expect(DurationParser.parse("0") == 0)
    }

    @Test("A bare decimal is hours")
    func bareDecimal() {
        // The rule that looks inconsistent and is not: nobody types `1.5` meaning ninety seconds.
        #expect(DurationParser.parse("1.5") == 5_400)
        #expect(DurationParser.parse("1,5") == 5_400)
        #expect(DurationParser.parse("0.25") == 900)
        #expect(DurationParser.parse("8") == 480)
    }

    @Test("Two decimal points are not a number")
    func doubleDecimal() {
        #expect(DurationParser.parse("1.5.5") == nil)
    }

    // MARK: - Edges

    @Test("Nothing typed is not a duration")
    func emptyInput() {
        #expect(DurationParser.parse("") == nil)
        #expect(DurationParser.parse("   ") == nil)
    }

    @Test("Surrounding space and capitals do not matter")
    func lenientAboutShape() {
        #expect(DurationParser.parse("  1H30M ") == 5_400)
    }

    @Test("A typo that would swallow a decade is refused, not clamped")
    func absurdInputIsRefused() {
        // A stray digit turning `8` into `88888` is the realistic way to exceed the cap, and an
        // entry that quietly keeps *some* of it wrecks every total until somebody finds it.
        #expect(DurationParser.parse("88888") == nil)
        #expect(DurationParser.parse("1000:00") == nil)
        #expect(DurationParser.parse("999:00") == DurationParser.maximum)
    }

    @Test("A negative duration cannot be typed at all")
    func negativeInput() {
        #expect(DurationParser.parse("-30") == nil)
        #expect(DurationParser.parse("-1:30") == nil)
    }
}
