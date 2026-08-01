import Foundation

/// How much a defect matters.
///
/// Severity is not priority, and keeping them apart is the point. **Severity is a property of the
/// defect** — how badly it behaves when it happens — and it does not change because the schedule
/// did. **Priority is a decision about the queue**, and it changes constantly. A cosmetic
/// misalignment on the screen every customer sees can be the next thing fixed; a critical crash in
/// a feature nobody has enabled yet can wait. Collapsing the two means the only way to say "fix
/// this now" is to lie about what the bug does, and the lie survives in the record long after the
/// schedule that motivated it is forgotten.
public enum BugSeverity: String, Codable, Sendable, Hashable, CaseIterable {
    /// Data loss, a crash, or a blocked path with no way around it.
    case critical

    /// A feature does not work, but there is a way around it.
    case major

    /// Wrong behaviour in a corner, or right behaviour that is awkward.
    case minor

    /// It looks wrong. It does the right thing.
    case cosmetic

    /// Ordering weight, most severe first. Not the raw value, so renaming a case for display never
    /// silently reorders every board in the app.
    private var weight: Int {
        switch self {
        case .critical: 0
        case .major: 1
        case .minor: 2
        case .cosmetic: 3
        }
    }

    public var displayName: String {
        switch self {
        case .critical: "Critical"
        case .major: "Major"
        case .minor: "Minor"
        case .cosmetic: "Cosmetic"
        }
    }

    /// One line saying what the level actually means, for the picker.
    ///
    /// Present because severity is the field people disagree about most, and a picker that offers
    /// four adjectives and no definitions gets four people's four definitions.
    public var hint: String {
        switch self {
        case .critical: "Data loss, a crash, or no way around it"
        case .major: "A feature does not work, but there is a workaround"
        case .minor: "Wrong in a corner, or awkward"
        case .cosmetic: "It looks wrong but does the right thing"
        }
    }

    public var symbolName: String {
        switch self {
        case .critical: "exclamationmark.octagon.fill"
        case .major: "exclamationmark.triangle.fill"
        case .minor: "exclamationmark.circle"
        case .cosmetic: "paintbrush"
        }
    }

    /// The design-system colour name, or `nil` for a level that gets no colour at all.
    ///
    /// Cosmetic is deliberately uncoloured. Giving all four a hue makes a bug list a stripe of
    /// warning colours in which nothing stands out, which is the opposite of what severity is for.
    /// Three coloured levels and one plain one means the coloured ones read as coloured.
    public var colorName: String? {
        switch self {
        case .critical: "red"
        case .major: "orange"
        case .minor: "yellow"
        case .cosmetic: nil
        }
    }
}

extension BugSeverity: Comparable {
    /// Orders most severe first, so `sorted()` puts critical at the top without every call site
    /// remembering to reverse it.
    public static func < (lhs: BugSeverity, rhs: BugSeverity) -> Bool {
        lhs.weight < rhs.weight
    }
}

/// Everything that makes a defect answerable, as a value.
///
/// The persisted `BugRecord` reads and writes this whole struct rather than exposing nine columns,
/// so the rules about what a bug is live in `ElephruitCore` where they can be tested without a
/// store, and the model layer stays a place things are kept rather than a place they are decided.
public struct BugFacts: Sendable, Hashable {
    public var severity: BugSeverity
    /// How to make it happen. The single most valuable field, and the one most often empty.
    public var stepsToReproduce: String?
    public var expectedBehavior: String?
    public var actualBehavior: String?
    /// Machine, OS, build — whatever made this reproducible here and not there.
    public var environment: String?
    /// The version it was found in.
    public var affectedVersion: String?
    /// The version it is fixed in. Set when the fix lands, not when the bug is filed.
    public var fixVersion: String?
    /// Whether this used to work. A regression is a different conversation from a defect that has
    /// always been there: something known-good broke, so something changed, and that is a lead.
    public var isRegression: Bool

    public init(
        severity: BugSeverity = .minor,
        stepsToReproduce: String? = nil,
        expectedBehavior: String? = nil,
        actualBehavior: String? = nil,
        environment: String? = nil,
        affectedVersion: String? = nil,
        fixVersion: String? = nil,
        isRegression: Bool = false
    ) {
        self.severity = severity
        self.stepsToReproduce = stepsToReproduce
        self.expectedBehavior = expectedBehavior
        self.actualBehavior = actualBehavior
        self.environment = environment
        self.affectedVersion = affectedVersion
        self.fixVersion = fixVersion
        self.isRegression = isRegression
    }

    /// Whether anything beyond a severity has been filled in.
    ///
    /// Severity is excluded because it always has a value — a bug with nothing written down still
    /// reports `.minor` — so counting it would make every empty report look answered.
    public var hasDetail: Bool {
        [stepsToReproduce, expectedBehavior, actualBehavior, environment, affectedVersion, fixVersion]
            .contains { $0?.isEmpty == false }
    }

    /// The names of the fields a report is missing, in the order worth asking for them.
    ///
    /// Used to nudge rather than to block. A bug filed in eight seconds with only a title is a bug
    /// that got filed, and demanding reproduction steps at that moment is how defects stop being
    /// reported at all. This says what is still missing, later, when there is time to answer.
    ///
    /// `fixVersion` is never listed: it is missing because the bug is not fixed yet, which is not an
    /// omission.
    public var missingFieldNames: [String] {
        var names: [String] = []
        if stepsToReproduce?.isEmpty != false { names.append("Steps to reproduce") }
        if expectedBehavior?.isEmpty != false { names.append("Expected") }
        if actualBehavior?.isEmpty != false { names.append("Actual") }
        if environment?.isEmpty != false { names.append("Environment") }
        if affectedVersion?.isEmpty != false { names.append("Affected version") }
        return names
    }
}
