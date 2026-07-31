import Foundation

/// How old somebody is, and how sure we are.
///
/// Two cases rather than an `Int` and a flag, because the difference between *knowing* and
/// *estimating* is the whole feature. A view cannot accidentally render an estimate as a fact when
/// the estimate has no plain-integer form to render.
public enum AgeEstimate: Sendable, Hashable {
    /// A birthday is known, so this is arithmetic rather than inference.
    case exact(years: Int)

    /// Derived from an age given on a date. Inclusive bounds.
    case approximate(lower: Int, upper: Int)

    /// Nothing to go on.
    case unknown

    /// "6 years old" · "approximately 7–8 years old".
    ///
    /// The word *approximately* is not decoration. It is the difference between the interface making
    /// a claim and the interface showing its working, and it is why this string is built here rather
    /// than by whichever view happens to need it.
    public var displayText: String {
        switch self {
        case .exact(let years):
            years == 1 ? "1 year old" : "\(years) years old"
        case .approximate(let lower, let upper):
            lower == upper
                ? "approximately \(lower) years old"
                : "approximately \(lower)–\(upper) years old"
        case .unknown:
            "age unknown"
        }
    }

    public var isEstimate: Bool {
        if case .approximate = self { return true }
        return false
    }

    /// The best single number, for sorting and for a compact row. Never shown without its label.
    public var representativeYears: Int? {
        switch self {
        case .exact(let years): years
        case .approximate(let lower, let upper): (lower + upper) / 2
        case .unknown: nil
        }
    }
}

/// Works out how old somebody is now from what was true then.
///
/// ### The arithmetic, and why the range is what it is
/// "Jack is six" on 18 July 2026 does not fix a birthday — it fixes a *window*. If `A` is the age
/// given on date `O`, the birth date `b` satisfies `O - (A+1) years < b ≤ O - A years`. At a later
/// date `T`, with `Δ` the elapsed time in years:
///
/// - taking `b` at its latest — somebody who had just turned `A` — gives age `A + floor(Δ)`;
/// - taking `b` at its earliest — somebody about to turn `A + 1` — gives age `A + ceil(Δ)`.
///
/// So the answer is the closed range `A + floor(Δ) ... A + ceil(Δ)`, which collapses to a single
/// value whenever `Δ` is a whole number of years. Eighteen months after "Jack is six" that is 7…8,
/// which is exactly as much as anyone can honestly say.
///
/// Widening a range as time passes is the point. An estimate that stayed one number would be wrong
/// half the year, confidently.
public enum AgeEstimator {
    /// The estimate implied by an age observed on a date.
    ///
    /// - Parameters:
    ///   - observedAge: Whole years, as stated.
    ///   - observedOn: When it was stated.
    ///   - asOf: The date to answer for.
    public static func estimate(
        observedAge: Int,
        observedOn: Date,
        asOf: Date,
        calendar: Calendar
    ) -> AgeEstimate {
        guard observedAge >= 0 else { return .unknown }

        // Whole elapsed years, and whether any part-year remains. Counted with the calendar rather
        // than by dividing days, so leap years and the user's own calendar are handled by the thing
        // that knows about them.
        let from = calendar.startOfDay(for: observedOn)
        let to = calendar.startOfDay(for: asOf)

        guard to >= from else {
            // Asking about a date before the observation. The observation is the only thing known,
            // and extrapolating backwards would invent a precision nobody has.
            return .approximate(lower: max(0, observedAge - 1), upper: observedAge)
        }

        let wholeYears = calendar.dateComponents([.year], from: from, to: to).year ?? 0
        let anniversary = calendar.date(byAdding: .year, value: wholeYears, to: from) ?? from
        let hasPartYear = to > anniversary

        let lower = observedAge + wholeYears
        let upper = observedAge + wholeYears + (hasPartYear ? 1 : 0)

        return lower == upper ? .approximate(lower: lower, upper: lower) : .approximate(lower: lower, upper: upper)
    }

    /// The exact age from a known birth date.
    ///
    /// Separate from the estimate path rather than a special case of it, because a known birthday
    /// makes this ordinary arithmetic — and the moment one is recorded the interface should stop
    /// hedging entirely.
    public static func exactAge(bornOn birthDate: Date, asOf date: Date, calendar: Calendar) -> AgeEstimate {
        let from = calendar.startOfDay(for: birthDate)
        let to = calendar.startOfDay(for: date)
        guard to >= from else { return .unknown }

        let years = calendar.dateComponents([.year], from: from, to: to).year ?? 0
        return .exact(years: years)
    }
}

// MARK: - School year

/// A school year, named by the calendar year it starts in — 2026 is "2026–27".
///
/// A value type rather than a pair of dates, because the only questions ever asked of it are
/// "which one is this date in" and "how many have passed", and both are integer arithmetic once the
/// boundary is decided.
public struct SchoolYear: Sendable, Hashable, Comparable {
    public var startYear: Int

    public init(startYear: Int) {
        self.startYear = startYear
    }

    /// "2026–27".
    public var displayText: String {
        let end = (startYear + 1) % 100
        return String(format: "%d–%02d", startYear, end)
    }

    public static func < (lhs: SchoolYear, rhs: SchoolYear) -> Bool {
        lhs.startYear < rhs.startYear
    }

    /// The month a school year is taken to begin in. August, in the northern hemisphere.
    ///
    /// A stored default rather than a hard-coded literal so the southern hemisphere is a setting
    /// rather than a rewrite — and so a test can pin it instead of depending on where it runs.
    public static let defaultStartMonth = 8

    /// Which school year a date falls in.
    public static func containing(_ date: Date, calendar: Calendar, startMonth: Int = defaultStartMonth) -> SchoolYear {
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 1
        // January to July belongs to the year that began the previous August.
        return SchoolYear(startYear: month >= startMonth ? year : year - 1)
    }
}

/// A school grade, or the fact that somebody is past or before one.
///
/// Modelled rather than stored as a string so that advancing a year is addition, and so that
/// kindergarten and "left school" are representable without a sentinel value that some later
/// caller forgets to check.
public enum SchoolGrade: Sendable, Hashable, Comparable {
    case preSchool
    case kindergarten

    /// 1 through 12.
    case grade(Int)

    /// Past secondary school.
    case graduated

    /// Reads a written grade — "2", "second", "2nd", "kindergarten", "pre-k".
    ///
    /// Returns `nil` rather than guessing. A grade the app cannot read stays as the user's own text
    /// on the card, which is always better than a wrong number that then advances every year.
    public static func parse(_ text: String) -> SchoolGrade? {
        let cleaned = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "grade", with: "")
            .replacingOccurrences(of: "year", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch cleaned {
        case "k", "kindergarten", "kinder": return .kindergarten
        case "pre-k", "prek", "pre-school", "preschool", "nursery": return .preSchool
        default: break
        }

        if let number = Int(cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "stndrdth "))),
           (1...12).contains(number) {
            return .grade(number)
        }

        let words = [
            "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
            "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12,
        ]
        if let number = words[cleaned] { return .grade(number) }

        return nil
    }

    /// This grade, `years` school years later.
    public func advanced(by years: Int) -> SchoolGrade {
        guard years != 0 else { return self }

        // Somebody who has left school does not un-leave it, whichever way the clock is wound.
        if case .graduated = self { return .graduated }

        let current: Int = switch self {
        case .preSchool: -1
        case .kindergarten: 0
        case .grade(let value): value
        case .graduated: 13
        }

        return switch current + years {
        case ...(-1): .preSchool
        case 0: .kindergarten
        case 1...12: .grade(current + years)
        default: .graduated
        }
    }

    /// "3rd grade" · "kindergarten" · "finished school".
    public var displayText: String {
        switch self {
        case .preSchool: "pre-school"
        case .kindergarten: "kindergarten"
        case .grade(let value): "\(Self.ordinal(value)) grade"
        case .graduated: "finished school"
        }
    }

    private var order: Int {
        switch self {
        case .preSchool: -1
        case .kindergarten: 0
        case .grade(let value): value
        case .graduated: 13
        }
    }

    public static func < (lhs: SchoolGrade, rhs: SchoolGrade) -> Bool {
        lhs.order < rhs.order
    }

    static func ordinal(_ value: Int) -> String {
        let suffix: String = switch (value % 10, value % 100) {
        case (1, 11), (2, 12), (3, 13): "th"
        case (1, _): "st"
        case (2, _): "nd"
        case (3, _): "rd"
        default: "th"
        }
        return "\(value)\(suffix)"
    }
}

/// What grade somebody is probably in now.
public struct GradeEstimate: Sendable, Hashable {
    public var grade: SchoolGrade

    /// The school year the estimate is for.
    public var schoolYear: SchoolYear

    /// Whether any school-year boundary has been crossed since the observation.
    ///
    /// `false` means the stated grade is still current and is not an estimate at all — a distinction
    /// worth keeping, because hedging a fact somebody told you last week reads as evasive.
    public var isEstimate: Bool

    public init(grade: SchoolGrade, schoolYear: SchoolYear, isEstimate: Bool) {
        self.grade = grade
        self.schoolYear = schoolYear
        self.isEstimate = isEstimate
    }

    /// "likely in 3rd grade" · "in 2nd grade".
    public var displayText: String {
        isEstimate ? "likely in \(grade.displayText)" : "in \(grade.displayText)"
    }
}

/// Advances a stated grade across school-year boundaries.
///
/// ### Why the school year is stored and not derived
/// "Jack starts second grade next month", said on 18 July 2026, is a statement about the 2026–27
/// year. July falls in the 2025–26 one, so deriving the year from the observation date would put
/// Jack a full grade behind for the six weeks of summer — the exact weeks in which people say this
/// sort of thing. The school year travels with the observation
/// (``PersonObservation/schoolYearStart``) and the estimate counts boundaries from *it*.
public enum GradeEstimator {
    public static func estimate(
        observedGrade: SchoolGrade,
        schoolYear: SchoolYear,
        asOf date: Date,
        calendar: Calendar,
        startMonth: Int = SchoolYear.defaultStartMonth
    ) -> GradeEstimate {
        let target = SchoolYear.containing(date, calendar: calendar, startMonth: startMonth)
        let yearsElapsed = target.startYear - schoolYear.startYear

        return GradeEstimate(
            grade: observedGrade.advanced(by: yearsElapsed),
            schoolYear: target,
            isEstimate: yearsElapsed != 0
        )
    }
}

// MARK: - Provenance

/// The sentence that says where an estimate came from.
///
/// Every estimate the interface shows is accompanied by one of these. Not as a tooltip, and not
/// behind a disclosure — beneath the claim, in the same glance, because a user who has to go looking
/// for the caveat has already believed the number.
public enum EstimateProvenance {
    /// "Estimated from information shared 18 July 2026."
    public static func sentence(observedOn: Date, locale: Locale = .autoupdatingCurrent) -> String {
        let text = observedOn.formatted(
            .dateTime.day().month(.wide).year().locale(locale)
        )
        return "Estimated from information shared \(text)."
    }

    /// "Confirmed 4 March 2026." — for a fact that was checked rather than derived.
    public static func confirmedSentence(on date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        let text = date.formatted(.dateTime.day().month(.wide).year().locale(locale))
        return "Confirmed \(text)."
    }
}
