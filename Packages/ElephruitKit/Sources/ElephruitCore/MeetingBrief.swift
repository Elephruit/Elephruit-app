import Foundation

/// One line of a meeting brief, with its source and its certainty attached.
///
/// Every entry carries both. A brief is read in the ninety seconds before walking into a room, which
/// is precisely when somebody will act on a sentence without checking it — so the sentence has to
/// say for itself whether it is a fact or a guess, and where it came from.
public struct BriefEntry: Sendable, Hashable, Identifiable {
    public enum Section: String, Sendable, Hashable, CaseIterable {
        case lastInteraction
        case lifeContext
        case recentChanges
        case openPromises
        case upcomingDates
        case family
        case conversationStarters
        case relatedWork

        public var displayName: String {
            switch self {
            case .lastInteraction: "Last time"
            case .lifeContext: "What's going on"
            case .recentChanges: "Since you last spoke"
            case .openPromises: "Reminders"
            case .upcomingDates: "Coming up"
            case .family: "Family"
            case .conversationStarters: "Worth asking about"
            case .relatedWork: "Related notes and projects"
            }
        }

        public var symbolName: String {
            switch self {
            case .lastInteraction: "clock.arrow.circlepath"
            case .lifeContext: "sparkles"
            case .recentChanges: "arrow.triangle.branch"
            case .openPromises: "checkmark.circle"
            case .upcomingDates: "calendar"
            case .family: "figure.2.and.child.holdinghands"
            case .conversationStarters: "bubble.left.and.text.bubble.right"
            case .relatedWork: "doc.text"
            }
        }

        /// Sections that must never appear in a brief a user might read aloud or share.
        ///
        /// None, today — private reflections are excluded from the brief entirely rather than
        /// filtered out of it, which is a stronger guarantee than a flag somebody has to remember.
        public var isAlwaysPrivate: Bool { false }
    }

    public var id: UUID
    public var section: Section
    public var text: String

    /// What the app is willing to claim about this line.
    public var confidence: FactConfidence

    /// The note, interaction, meeting, or task this came from — tappable, always.
    public var sourceItemID: UUID?

    /// When the underlying observation was made, for the estimate's provenance sentence.
    public var observedOn: Date?

    /// A secondary line — a date, a provenance sentence, an estimate's working.
    public var detail: String?

    public init(
        id: UUID = UUID(),
        section: Section,
        text: String,
        confidence: FactConfidence = .stated,
        sourceItemID: UUID? = nil,
        observedOn: Date? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.section = section
        self.text = text
        self.confidence = confidence
        self.sourceItemID = sourceItemID
        self.observedOn = observedOn
        self.detail = detail
    }

    /// Whether the interface has to label this rather than stating it plainly.
    public var needsEstimateLabel: Bool {
        confidence.needsLabel
    }
}

/// Everything worth knowing before seeing somebody.
///
/// ### Why this is assembled rather than written
/// A brief nobody has to maintain is a brief that is still right in six months. Every line here is
/// derived — from observations, from the timeline, from open tasks, from celebrations — so there is
/// no second document to update and no way for the brief to disagree with the page it summarises.
public struct MeetingBrief: Sendable, Hashable {
    public var personID: UUID
    public var personName: String

    /// When it was assembled, so a stale brief can say so.
    public var assembledAt: Date

    public var entries: [BriefEntry]

    public init(personID: UUID, personName: String, assembledAt: Date, entries: [BriefEntry]) {
        self.personID = personID
        self.personName = personName
        self.assembledAt = assembledAt
        self.entries = entries
    }

    /// Entries grouped into their sections, in the order the sections are declared.
    public var sections: [(section: BriefEntry.Section, entries: [BriefEntry])] {
        BriefEntry.Section.allCases.compactMap { section in
            let matching = entries.filter { $0.section == section }
            return matching.isEmpty ? nil : (section: section, entries: matching)
        }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// How many lines are estimates rather than stated facts.
    ///
    /// Shown at the top of the brief. A brief that is mostly estimates is still useful, and saying so
    /// once is more honest than labelling nine lines and hoping the reader notices the pattern.
    public var estimateCount: Int {
        entries.count(where: \.needsEstimateLabel)
    }

    public var summaryLine: String {
        guard !isEmpty else { return "Nothing recorded yet." }
        let base = "\(entries.count) thing\(entries.count == 1 ? "" : "s") to know"
        return estimateCount == 0 ? base : "\(base) · \(estimateCount) estimated"
    }
}
