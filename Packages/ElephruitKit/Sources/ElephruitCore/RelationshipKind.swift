import Foundation

/// How two people are related.
///
/// ### Why every kind names its own inverse
/// A relationship is one fact seen from two sides. Storing "Maya is Jack's parent" without storing
/// the other half means Jack's page has to search every person in the library for someone who
/// claims him — and storing both halves as independent rows means they can disagree, which is worse.
///
/// The resolution is that ``RelationshipKind/inverse`` is total: every kind has one, and the
/// repository maintains the pair as a unit. `ReciprocalRelationshipTests` asserts the involution —
/// that `a.inverse.inverse == a` for every case — so a kind added later cannot quietly break it.
public enum RelationshipKind: String, Codable, Sendable, Hashable, CaseIterable {
    case partner
    case parent
    case child
    case auntUncle
    case nieceNephew
    case sibling
    case friend
    case colleague
    case manager
    case directReport

    /// The person who introduced the subject to somebody.
    case introducedBy

    /// The other side of ``introducedBy``.
    case introduced

    case worksWith
    case householdMember

    /// The subject keeps this animal. Pets are lightweight person records — see
    /// `docs/21-people-module-scope.md` — because "Pepper is terrified of thunderstorms" is a fact
    /// that needs a subject, and inventing a second subject type for it would double every query.
    case petOwner

    /// The other side of ``petOwner``.
    case pet

    /// The relationship seen from the other person's side.
    ///
    /// Total by construction: adding a case without a mapping fails to compile, which is the whole
    /// reason this is a `switch` rather than a dictionary.
    public var inverse: RelationshipKind {
        switch self {
        case .partner: .partner
        case .parent: .child
        case .child: .parent
        case .auntUncle: .nieceNephew
        case .nieceNephew: .auntUncle
        case .sibling: .sibling
        case .friend: .friend
        case .colleague: .colleague
        case .manager: .directReport
        case .directReport: .manager
        case .introducedBy: .introduced
        case .introduced: .introducedBy
        case .worksWith: .worksWith
        case .householdMember: .householdMember
        case .petOwner: .pet
        case .pet: .petOwner
        }
    }

    /// Whether the relationship reads the same from both sides.
    public var isSymmetric: Bool {
        inverse == self
    }

    /// "parent" · "direct report".
    public var displayName: String {
        switch self {
        case .partner: "partner"
        case .parent: "parent"
        case .child: "child"
        case .auntUncle: "aunt / uncle"
        case .nieceNephew: "niece / nephew"
        case .sibling: "sibling"
        case .friend: "friend"
        case .colleague: "colleague"
        case .manager: "manager"
        case .directReport: "direct report"
        case .introducedBy: "introduced by"
        case .introduced: "introduced"
        case .worksWith: "works with"
        case .householdMember: "household"
        case .petOwner: "owner"
        case .pet: "pet"
        }
    }

    /// How the relationship reads on the subject's page — "Jack · Maya's son".
    ///
    /// Distinct from ``displayName`` because a label and a possessive phrase are not the same string,
    /// and because a gendered variant belongs here rather than in a view: the app only uses one when
    /// the user has recorded it themselves, through ``RelationshipKind/gendered(_:)``.
    ///
    /// The `label` is the user's own word, and it wins when there is one. This phrase is also what
    /// stands in for the *name* of somebody recorded before their name was known — see
    /// ``RelativeCapture/derivedTitle(subjectName:)`` — so "Maya's son" has to read as a description
    /// of a person rather than as a category, which "Maya's child" does not.
    public func possessivePhrase(subject: String, label: String? = nil) -> String {
        let word = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let noun = (word?.isEmpty == false ? word : nil) ?? displayName
        return "\(subject)'s \(noun)"
    }

    public var symbolName: String {
        switch self {
        case .partner: "heart"
        case .parent, .child, .auntUncle, .nieceNephew: "figure.2.and.child.holdinghands"
        case .sibling: "figure.2"
        case .friend: "hand.wave"
        case .colleague, .worksWith: "person.2"
        case .manager: "arrow.up.forward.square"
        case .directReport: "arrow.down.forward.square"
        case .introducedBy, .introduced: "arrow.triangle.branch"
        case .householdMember: "house"
        case .petOwner, .pet: "pawprint"
        }
    }

    /// What a capture form offers to record about somebody in this relationship.
    ///
    /// ### What this is, and what it very deliberately is not
    /// It is a list of *suggestions*, and it decides only which fields appear without being asked
    /// for. It does not decide what a person of this kind is allowed to have: every editor built on
    /// it also offers "anything else", and ``FactAttribute/custom(_:)`` will make an attribute out
    /// of whatever the user types. A partner finishing a PhD gets a grade by naming one.
    ///
    /// The distinction matters because the version of this that was hard-coded — `kind == .child`,
    /// in four places — read as a rule about people rather than a guess about forms. It said a
    /// colleague could not have an age and a partner could not have a job, and it was wrong about
    /// both while looking like a decision somebody had made.
    ///
    /// A `switch` rather than a table, so a kind added later has to be given an answer.
    public var suggestedAttributes: [FactAttribute] {
        switch self {
        case .child, .nieceNephew:
            [.observedAge, .schoolGrade, .school, .quickFact]
        case .partner, .parent, .auntUncle, .sibling, .householdMember:
            [.employer, .quickFact]
        case .colleague, .manager, .directReport, .worksWith:
            [.role, .employer, .quickFact]
        case .pet:
            // An age, because "Pepper is four" is the commonest thing anybody says about a dog, and
            // `AgeEstimator` carries it forward for a pet exactly as it does for a child.
            [.observedAge, .quickFact]
        case .friend, .introducedBy, .introduced, .petOwner:
            [.location, .quickFact]
        }
    }

    /// A gendered word for this relationship, when the user supplied one.
    ///
    /// The app never infers gender — not from a name, not from a pronoun, not from anything. This
    /// exists only so that a user who typed "Maya's son Jack" gets "son" back rather than "child",
    /// and the word is carried as free text on the relationship rather than derived here.
    public static func gendered(_ word: String) -> RelationshipKind? {
        switch word.lowercased() {
        case "son", "daughter", "kid", "child": .child
        case "niece", "nephew", "nibling": .nieceNephew
        case "aunt", "uncle", "pibling": .auntUncle
        case "mother", "father", "mum", "mom", "dad", "parent": .parent
        case "brother", "sister", "sibling": .sibling
        case "husband", "wife", "spouse", "partner", "boyfriend", "girlfriend": .partner
        case "boss", "manager": .manager
        case "report", "reports": .directReport
        case "colleague", "coworker", "co-worker", "teammate": .colleague
        case "friend": .friend
        case "dog", "cat", "pet": .pet
        case "roommate", "housemate", "flatmate": .householdMember
        default: nil
        }
    }
}

// MARK: - Grouping

/// How a person's relationships are gathered on their page.
///
/// ### Why not "Children" and "Everybody else"
/// Because that was the grouping, and it made two claims the app has no business making.
///
/// It said that one relationship is the interesting one and the rest are a remainder. Somebody's
/// partner, their mother, their sister and their oldest friend were all *Everybody else*, filed under
/// a heading whose only meaning is "not children" — which is a statement about whose life this is,
/// made by software, in a module that is otherwise careful not to. And it does not scale: a person
/// with no children got one unnamed group, a person with four got a wall of cards above a remainder,
/// and neither arrangement says anything about how the people in it are related.
///
/// These four are the same cut the charts already make — see ``RelationshipChartKind`` — so the
/// section and the family tree agree about what counts as family. Every group is a category rather
/// than an exception, no group is defined by what it is not, and a household of housemates, a family
/// with no children, and a person whose whole record is colleagues each get headings that describe
/// them rather than headings that place them.
public enum RelationshipGroup: String, Sendable, Hashable, CaseIterable, Identifiable {
    case family
    case household
    case work
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .family: "Family"
        case .household: "Household"
        case .work: "Work"
        case .other: "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .family: "figure.2.and.child.holdinghands"
        case .household: "house"
        case .work: "building.2"
        case .other: "person.2"
        }
    }

    /// The order the groups read in: closest first.
    public var sortOrder: Int {
        switch self {
        case .family: 0
        case .household: 1
        case .work: 2
        case .other: 3
        }
    }
}

extension RelationshipKind {
    /// Which group this relationship is shown under.
    ///
    /// A `switch` rather than a table, so a kind added later has to be placed rather than silently
    /// falling into *Other*.
    public var group: RelationshipGroup {
        switch self {
        case .partner, .parent, .child, .auntUncle, .nieceNephew, .sibling: .family
        case .householdMember, .petOwner, .pet: .household
        case .colleague, .manager, .directReport, .worksWith: .work
        case .friend, .introducedBy, .introduced: .other
        }
    }
}

// MARK: - Charts

/// Which view of somebody's relationships is on screen.
///
/// Four charts rather than one, because a family tree and an organisation chart answer different
/// questions and drawing both at once produces a hairball that answers neither.
public enum RelationshipChartKind: String, Sendable, Hashable, CaseIterable, Identifiable {
    case family
    case household
    case professional
    case network

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .family: "Family"
        case .household: "Household"
        case .professional: "Organization"
        case .network: "Network"
        }
    }

    public var symbolName: String {
        switch self {
        case .family: "figure.2.and.child.holdinghands"
        case .household: "house"
        case .professional: "building.2"
        case .network: "point.3.connected.trianglepath.dotted"
        }
    }

    /// The relationship kinds this chart draws.
    public var includedKinds: Set<RelationshipKind> {
        switch self {
        case .family: [.partner, .parent, .child, .auntUncle, .nieceNephew, .sibling, .petOwner, .pet]
        case .household: [.householdMember, .partner, .child, .parent, .petOwner, .pet]
        case .professional: [.manager, .directReport, .colleague, .worksWith]
        case .network: Set(RelationshipKind.allCases)
        }
    }

    /// Whether this chart is hierarchical, which decides whether it is laid out in ranked rows or
    /// as a ring around the subject.
    public var isHierarchical: Bool {
        switch self {
        case .family, .professional: true
        case .household, .network: false
        }
    }

    /// The empty-state sentence for a person with no relationships of this kind.
    public var emptyMessage: String {
        switch self {
        case .family: "No family recorded yet. Add a partner, a parent, or a child to see them here."
        case .household: "Nobody else recorded in this household."
        case .professional: "No colleagues, manager, or reports recorded yet."
        case .network: "No relationships recorded yet."
        }
    }
}

/// One person in a chart.
///
/// A value type carrying only what the drawing needs, so the chart can be laid out, snapshot-tested,
/// and reasoned about without a `ModelContext` in sight.
public struct RelationshipNode: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String

    /// Distance from the subject in relationship hops. The subject is zero.
    public var depth: Int

    /// Vertical rank for a hierarchical chart: negative is above the subject (parents, managers),
    /// positive is below (children, reports), zero is level (partners, siblings, colleagues).
    public var rank: Int

    /// How this person reaches the subject, for the accessibility label.
    public var relationToSubject: RelationshipKind?

    /// A gendered or user-written label, when there is one — "son", "step-mother".
    public var customLabel: String?

    /// A record with no contact details of its own, created only so somebody could be mentioned.
    public var isPlaceholder: Bool

    public init(
        id: UUID,
        name: String,
        depth: Int,
        rank: Int,
        relationToSubject: RelationshipKind? = nil,
        customLabel: String? = nil,
        isPlaceholder: Bool = false
    ) {
        self.id = id
        self.name = name
        self.depth = depth
        self.rank = rank
        self.relationToSubject = relationToSubject
        self.customLabel = customLabel
        self.isPlaceholder = isPlaceholder
    }

    /// The label shown under the node, preferring what the user actually wrote.
    public var roleLabel: String? {
        customLabel ?? relationToSubject?.displayName
    }
}

/// One line in a chart.
public struct RelationshipEdge: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var fromID: UUID
    public var toID: UUID
    public var kind: RelationshipKind

    public init(id: UUID = UUID(), fromID: UUID, toID: UUID, kind: RelationshipKind) {
        self.id = id
        self.fromID = fromID
        self.toID = toID
        self.kind = kind
    }
}

/// A laid-out chart, ready to draw.
public struct RelationshipChart: Sendable, Hashable {
    public var kind: RelationshipChartKind
    public var subjectID: UUID
    public var nodes: [RelationshipNode]
    public var edges: [RelationshipEdge]

    public init(kind: RelationshipChartKind, subjectID: UUID, nodes: [RelationshipNode], edges: [RelationshipEdge]) {
        self.kind = kind
        self.subjectID = subjectID
        self.nodes = nodes
        self.edges = edges
    }

    public var isEmpty: Bool { nodes.count <= 1 }

    /// Nodes grouped into ranked rows, top to bottom.
    ///
    /// Rank ordering is what makes a family tree legible: parents above, the subject and their
    /// partner and siblings level, children below. A force-directed blob would be prettier in a
    /// screenshot and useless for answering "who is Jack's mother".
    public var rows: [(rank: Int, nodes: [RelationshipNode])] {
        Dictionary(grouping: nodes, by: \.rank)
            .sorted { $0.key < $1.key }
            .map { (rank: $0.key, nodes: $0.value.sorted { $0.name < $1.name }) }
    }

    /// The rank a relationship places somebody at, relative to the subject.
    ///
    /// Pure and shared, so the family chart and the organisation chart cannot come to different
    /// conclusions about which way is up.
    public static func rank(for kind: RelationshipKind) -> Int {
        switch kind {
        case .parent, .auntUncle, .manager: -1
        case .child, .nieceNephew, .directReport, .pet: 1
        case .partner, .sibling, .friend, .colleague, .worksWith, .householdMember,
             .introducedBy, .introduced, .petOwner: 0
        }
    }
}
