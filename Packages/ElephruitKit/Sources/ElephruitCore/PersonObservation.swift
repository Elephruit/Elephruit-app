import Foundation

/// What a fact about a person is *about*.
///
/// A string wrapper rather than an enum, because the set is open: someone will want to record that a
/// friend is allergic to shellfish, and a closed enum would force either a schema change or a
/// second, worse mechanism beside it. The well-known attributes are declared as statics so that the
/// interface can group and label them, and anything else round-trips untouched.
public struct FactAttribute: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    // MARK: Life context

    public static let location = FactAttribute("location")
    public static let employer = FactAttribute("employer")
    public static let role = FactAttribute("role")
    public static let lifeEvent = FactAttribute("lifeEvent")
    public static let health = FactAttribute("health")

    // MARK: Preferences

    public static let like = FactAttribute("like")
    public static let dislike = FactAttribute("dislike")
    public static let giftIdea = FactAttribute("giftIdea")
    public static let communicationPreference = FactAttribute("communicationPreference")
    public static let foodAndDrink = FactAttribute("foodAndDrink")
    public static let family = FactAttribute("family")
    public static let interest = FactAttribute("interest")
    public static let conversationTopic = FactAttribute("conversationTopic")
    public static let quickFact = FactAttribute("quickFact")

    // MARK: Derived-from-dated-observation

    /// An age *as observed on a date*. The value is the age in whole years at that moment, and
    /// everything downstream treats it as a starting point rather than a current answer.
    public static let observedAge = FactAttribute("observedAge")

    /// A school grade, meaningful only alongside the school year it referred to.
    public static let schoolGrade = FactAttribute("schoolGrade")

    /// Which school somebody attends.
    ///
    /// ### Why a fact and not an organization record
    /// A record would cost a page nobody opens, and a link to it would not *supersede* when the
    /// child changes school — it would have to be found and removed by hand, which means the wrong
    /// school stays true by default. A single-valued dated fact changes school the same way somebody
    /// changes employer, keeps the old one as history, and reaches the brief's Family section
    /// without anything else being taught about it.
    public static let school = FactAttribute("school")

    /// Somebody is looking for something — a dog trainer, a plumber, a new job.
    public static let lookingFor = FactAttribute("lookingFor")

    /// Why this person matters. The one card that is never inferred.
    public static let significance = FactAttribute("significance")

    /// A private reflection. Always ``FactSensitivity/private``, never exported to a contact card.
    public static let reflection = FactAttribute("reflection")

    /// A promise made, tracked as a fact so it keeps its source and its date.
    public static let promise = FactAttribute("promise")

    /// Every attribute the interface offers a dedicated card for, in the order they are shown.
    public static let curated: [FactAttribute] = [
        .significance, .conversationTopic, .family, .observedAge, .schoolGrade, .school, .foodAndDrink, .interest,
        .like, .dislike, .lifeEvent, .location, .employer, .role,
        .giftIdea, .communicationPreference, .lookingFor, .quickFact,
        .promise, .reflection,
    ]

    /// The card heading this attribute belongs under.
    public var displayName: String {
        switch self {
        case .location: "Lives in"
        case .employer: "Works at"
        case .role: "Role"
        case .lifeEvent: "Life context"
        case .health: "Health"
        case .like: "Likes"
        case .dislike: "Avoid"
        case .giftIdea: "Gift ideas"
        case .communicationPreference: "How to reach them"
        case .foodAndDrink: "Food & drink"
        case .family: "Family"
        case .interest: "Interests"
        case .conversationTopic: "Ask about"
        case .quickFact: "Good to know"
        case .observedAge: "Age"
        // "Grade", not "School" — the two are separate cards now, and a heading that names the
        // building over a value that names the year is the sort of mismatch nobody reports and
        // everybody misreads.
        case .schoolGrade: "Grade"
        case .school: "School"
        case .lookingFor: "Looking for"
        case .significance: "Why they matter"
        case .reflection: "Private notes"
        case .promise: "Reminders"
        default: rawValue.capitalized
        }
    }

    public var symbolName: String {
        switch self {
        case .location: "mappin.and.ellipse"
        case .employer, .role: "briefcase"
        case .lifeEvent: "sparkles"
        case .health: "heart.text.square"
        case .like: "hand.thumbsup"
        case .dislike: "hand.thumbsdown"
        case .giftIdea: "gift"
        case .communicationPreference: "bubble.left.and.text.bubble.right"
        case .foodAndDrink: "fork.knife"
        case .family: "figure.2.and.child.holdinghands"
        case .interest: "star"
        case .conversationTopic: "questionmark.bubble"
        case .quickFact: "sparkles"
        case .observedAge: "birthday.cake"
        case .schoolGrade: "graduationcap"
        case .school: "building.columns"
        case .lookingFor: "magnifyingglass"
        case .significance: "heart"
        case .reflection: "lock"
        case .promise: "checkmark.circle"
        default: "text.alignleft"
        }
    }

    /// Whether more than one value can be true at once.
    ///
    /// Someone lives in exactly one place and likes many things. This is the difference between a
    /// new observation *superseding* the last one and merely joining it, and getting it wrong in
    /// either direction is visible immediately: a Likes card that shows only the most recent like,
    /// or a Lives-in card that lists three cities.
    public var isMultiValued: Bool {
        switch self {
        case .location, .employer, .role, .observedAge, .schoolGrade, .school, .significance: false
        default: true
        }
    }

    /// Attributes never included in an exported contact card, whatever the share profile says.
    public var isAlwaysPrivate: Bool {
        self == .reflection
    }
}

// MARK: - Confidence

/// How the app came to believe something.
///
/// Three values, not a percentage. A number would imply a precision nobody has and would invite
/// arithmetic on it; these three map onto questions a person can actually answer — *did they tell
/// you, did you work it out, or are you guessing?*
public enum FactConfidence: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    /// The person said it, or the user recorded it as fact. The strongest thing this app claims.
    case stated

    /// Derived by the app from something stated — an age that has advanced since it was given.
    case inferred

    /// Recorded with an explicit hedge, or grown old enough that the app will not vouch for it.
    case uncertain

    public var displayName: String {
        switch self {
        case .stated: "Confirmed"
        case .inferred: "Estimated"
        case .uncertain: "Unconfirmed"
        }
    }

    /// Whether the interface must label this rather than presenting it as plain fact.
    ///
    /// The product line that matters: an estimate that looks like a fact is worse than no estimate,
    /// because it is acted on with confidence that was never earned.
    public var needsLabel: Bool {
        self != .stated
    }

    public var symbolName: String {
        switch self {
        case .stated: "checkmark.seal"
        case .inferred: "function"
        case .uncertain: "questionmark.circle"
        }
    }

    private var order: Int {
        switch self {
        case .stated: 2
        case .inferred: 1
        case .uncertain: 0
        }
    }

    public static func < (lhs: FactConfidence, rhs: FactConfidence) -> Bool {
        lhs.order < rhs.order
    }
}

/// How carefully a fact should be handled.
public enum FactSensitivity: String, Codable, Sendable, Hashable, CaseIterable {
    /// Ordinary. Appears on the portrait, may be exported if a share profile includes it.
    case normal

    /// Shown but never exported and never included in a brief that might be read aloud.
    case sensitive

    /// Hidden behind an explicit reveal, never exported, never searched by default.
    case restricted

    public var displayName: String {
        switch self {
        case .normal: "Normal"
        case .sensitive: "Sensitive"
        case .restricted: "Private"
        }
    }

    /// Whether a fact at this level may leave the app in a vCard, a share sheet, or a QR code.
    public var isExportable: Bool {
        self == .normal
    }
}

// MARK: - The observation

/// One dated statement about a person.
///
/// ### Why this is not a field on `PersonProfile`
/// A field answers "what is Maya's address" and destroys the answer to "what was it, when did it
/// change, and who said so". Every one of those three questions gets asked in practice — usually at
/// the moment the current value turns out to be wrong — and none of them is recoverable from a
/// column that was overwritten.
///
/// A `Sendable` value type, so the ledger below can be computed, tested, and rendered without a
/// store anywhere near it.
public struct PersonObservation: Sendable, Hashable, Identifiable {
    public var id: UUID

    /// The person this is about.
    public var subjectID: UUID

    public var attribute: FactAttribute

    /// What was said, verbatim where possible. Never re-worded by the app.
    public var value: String

    /// When the observation was made — the date the user heard it, not the date they typed it.
    ///
    /// This is the anchor for every temporal estimate. "Jack is six" means nothing without it.
    public var observedOn: Date

    /// When the value became or becomes true, if that differs from when it was observed.
    ///
    /// "Maya moves to Austin in September" is observed in July and effective in September. `nil`
    /// means it was already true when observed, which is the ordinary case.
    public var effectiveOn: Date?

    /// The last time this was checked and still held. Starts equal to ``observedOn``.
    public var lastConfirmedOn: Date

    public var confidence: FactConfidence
    public var sensitivity: FactSensitivity

    /// The note, interaction, or meeting this came out of.
    ///
    /// A fact with no source is still a fact — the user may simply have typed it — but a fact that
    /// *has* one must never lose it, because "where did I get this?" is the question that decides
    /// whether to act on it.
    public var sourceItemID: UUID?

    /// The observation this one replaces, forming the chain that makes correction non-destructive.
    public var supersedesID: UUID?

    /// Set when the user corrected or replaced this, so it leaves the current view without leaving
    /// the record.
    public var supersededOn: Date?

    /// Free text the user added when correcting — "I misheard this".
    public var correctionNote: String?

    /// The school year a ``FactAttribute/schoolGrade`` value referred to, as its starting year.
    ///
    /// "Entering second grade", said in July 2026, refers to the 2026–27 year even though July 2026
    /// falls in the 2025–26 one. Without this the estimate is off by a full grade for six weeks
    /// every summer, which is exactly when someone would mention it.
    public var schoolYearStart: Int?

    public init(
        id: UUID = UUID(),
        subjectID: UUID,
        attribute: FactAttribute,
        value: String,
        observedOn: Date,
        effectiveOn: Date? = nil,
        lastConfirmedOn: Date? = nil,
        confidence: FactConfidence = .stated,
        sensitivity: FactSensitivity = .normal,
        sourceItemID: UUID? = nil,
        supersedesID: UUID? = nil,
        supersededOn: Date? = nil,
        correctionNote: String? = nil,
        schoolYearStart: Int? = nil
    ) {
        self.id = id
        self.subjectID = subjectID
        self.attribute = attribute
        self.value = value
        self.observedOn = observedOn
        self.effectiveOn = effectiveOn
        self.lastConfirmedOn = lastConfirmedOn ?? observedOn
        self.confidence = confidence
        self.sensitivity = sensitivity
        self.sourceItemID = sourceItemID
        self.supersedesID = supersedesID
        self.supersededOn = supersededOn
        self.correctionNote = correctionNote
        self.schoolYearStart = schoolYearStart
    }

    /// Whether this is still the app's current answer.
    public var isCurrent: Bool { supersededOn == nil }

    /// How long since anyone checked, in days.
    public func daysSinceConfirmed(asOf date: Date, calendar: Calendar) -> Int {
        let from = calendar.startOfDay(for: lastConfirmedOn)
        let to = calendar.startOfDay(for: date)
        return max(0, calendar.dateComponents([.day], from: from, to: to).day ?? 0)
    }

    /// Whether this has gone long enough unchecked that the app stops vouching for it.
    ///
    /// Per-attribute, because the shelf life of "likes natural wine" and "works at Acme" are not the
    /// same fact about the world. A preference is close to permanent; an employer changes every few
    /// years and a life event is stale almost immediately.
    public func isStale(asOf date: Date, calendar: Calendar) -> Bool {
        guard let shelfLife = Self.shelfLifeDays[attribute] else { return false }
        return daysSinceConfirmed(asOf: date, calendar: calendar) > shelfLife
    }

    /// How long a fact of each kind is believed without rechecking.
    ///
    /// Absent means "does not go stale". A birthday does not expire and neither does why somebody
    /// matters to you.
    static let shelfLifeDays: [FactAttribute: Int] = [
        .location: 730,
        .employer: 548,
        .role: 548,
        .lifeEvent: 180,
        .health: 180,
        .lookingFor: 120,
        // Longer than an employer because school is changed at transitions rather than at will, and
        // short enough to be asked once per phase of somebody's schooling rather than never. Unlike
        // ``FactAttribute/schoolGrade`` there is nothing here to estimate forward: the app has no way
        // to know which building a child moves to, so asking is the only honest option it has.
        .school: 1095,
    ]

    // `observedAge` and `schoolGrade` are deliberately absent. They are the *inputs* to
    // `AgeEstimator` and `GradeEstimator`, which already label everything derived from them and say
    // which date it came from. Asking "is Jack still six? Still true?" two years on is the wrong
    // question — of course he is not, and the app knows it — so nagging about them would be the
    // interface admitting it has not read its own estimate.

    /// The confidence to *display*, which decays even though the record does not.
    ///
    /// The stored confidence is what was true when the observation was made and is never rewritten —
    /// rewriting it would destroy the distinction between "they told me this" and "they told me this
    /// a long time ago". What ages is the app's willingness to present it without a hedge.
    public func effectiveConfidence(asOf date: Date, calendar: Calendar) -> FactConfidence {
        guard isStale(asOf: date, calendar: calendar) else { return confidence }
        return .uncertain
    }
}

// MARK: - The ledger

/// Everything currently believed about one person, derived from their observations.
///
/// Pure, and the only place the supersede-and-multi-value rules live. A view asks this what to show;
/// it never works it out from a raw list, because two views doing that independently is how two
/// parts of one screen come to disagree.
public struct FactLedger: Sendable {
    public let observations: [PersonObservation]

    public init(observations: [PersonObservation]) {
        self.observations = observations
    }

    /// The current values for one attribute, newest first.
    ///
    /// For a single-valued attribute this is at most one entry: the newest current observation wins
    /// and the rest are history, whether or not anyone remembered to mark them superseded. Deriving
    /// that rather than relying on the `supersedesID` chain means an import, a sync merge, or a bug
    /// that leaves two unsuperseded "lives in" rows produces a right answer instead of two.
    public func current(_ attribute: FactAttribute) -> [PersonObservation] {
        let live = observations
            .filter { $0.attribute == attribute && $0.isCurrent }
            .sorted { $0.observedOn > $1.observedOn }

        return attribute.isMultiValued ? live : Array(live.prefix(1))
    }

    /// Superseded observations for one attribute, newest first — the "was" list.
    public func history(_ attribute: FactAttribute) -> [PersonObservation] {
        let current = Set(self.current(attribute).map(\.id))
        return observations
            .filter { $0.attribute == attribute && !current.contains($0.id) }
            .sorted { $0.observedOn > $1.observedOn }
    }

    /// Every attribute this person has anything recorded for, in curated order first.
    public var populatedAttributes: [FactAttribute] {
        let present = Set(observations.filter(\.isCurrent).map(\.attribute))
        let curated = FactAttribute.curated.filter(present.contains)
        let rest = present.subtracting(curated).sorted { $0.rawValue < $1.rawValue }
        return curated + rest
    }

    /// Facts the app has stopped vouching for, oldest-confirmed first.
    ///
    /// Surfaced so the user can confirm or correct them — never acted on, never quietly hidden.
    public func stale(asOf date: Date, calendar: Calendar) -> [PersonObservation] {
        observations
            .filter { $0.isCurrent && $0.isStale(asOf: date, calendar: calendar) }
            .sorted { $0.lastConfirmedOn < $1.lastConfirmedOn }
    }

    /// The single current value of an attribute, if it has one.
    public func value(of attribute: FactAttribute) -> String? {
        current(attribute).first?.value
    }
}
