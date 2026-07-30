import ElephruitCore
import Foundation
import Testing

/// Relationships, their inverses, and the charts drawn from them.
///
/// The involution test is the important one and is written against `allCases` rather than against a
/// list: a relationship kind added later without a correct inverse fails here rather than producing
/// a family tree in which Jack is his own mother's parent.
@Suite("Relationships")
struct RelationshipTests {
    @Test("Every relationship's inverse is its own inverse")
    func inverseIsAnInvolution() {
        for kind in RelationshipKind.allCases {
            #expect(kind.inverse.inverse == kind, "\(kind.rawValue) does not round-trip")
        }
    }

    @Test("Parent and child are each other's inverse")
    func parentChildReciprocal() {
        #expect(RelationshipKind.parent.inverse == .child)
        #expect(RelationshipKind.child.inverse == .parent)
    }

    @Test("Manager and direct report are each other's inverse")
    func managementReciprocal() {
        #expect(RelationshipKind.manager.inverse == .directReport)
        #expect(RelationshipKind.directReport.inverse == .manager)
    }

    @Test("Symmetric relationships are their own inverse")
    func symmetricKinds() {
        let symmetric: [RelationshipKind] = [.partner, .sibling, .friend, .colleague, .worksWith, .householdMember]
        for kind in symmetric {
            #expect(kind.isSymmetric, "\(kind.rawValue) should read the same from both sides")
        }
    }

    @Test("Introduction runs one way")
    func introductionIsDirectional() {
        #expect(!RelationshipKind.introducedBy.isSymmetric)
        #expect(RelationshipKind.introducedBy.inverse == .introduced)
    }

    // MARK: - The words people use

    @Test("Son and daughter are both children, without inferring anything else")
    func genderedWordsMapToKinds() {
        #expect(RelationshipKind.gendered("son") == .child)
        #expect(RelationshipKind.gendered("daughter") == .child)
        #expect(RelationshipKind.gendered("mother") == .parent)
        #expect(RelationshipKind.gendered("husband") == .partner)
        #expect(RelationshipKind.gendered("brother") == .sibling)
        #expect(RelationshipKind.gendered("boss") == .manager)
        #expect(RelationshipKind.gendered("roommate") == .householdMember)
    }

    @Test("A word that is not a relationship is not forced into being one")
    func unknownWordsAreRejected() {
        #expect(RelationshipKind.gendered("plumber") == nil)
        #expect(RelationshipKind.gendered("") == nil)
    }

    // MARK: - Charts

    @Test("A family chart draws family and leaves work out")
    func familyChartMembership() {
        let kinds = RelationshipChartKind.family.includedKinds
        #expect(kinds.contains(.parent))
        #expect(kinds.contains(.partner))
        #expect(kinds.contains(.pet))
        #expect(!kinds.contains(.manager))
        #expect(!kinds.contains(.colleague))
    }

    @Test("An organisation chart draws work and leaves family out")
    func professionalChartMembership() {
        let kinds = RelationshipChartKind.professional.includedKinds
        #expect(kinds.contains(.manager))
        #expect(kinds.contains(.directReport))
        #expect(!kinds.contains(.child))
        #expect(!kinds.contains(.partner))
    }

    @Test("The network chart draws everything")
    func networkChartIsComplete() {
        #expect(RelationshipChartKind.network.includedKinds.count == RelationshipKind.allCases.count)
    }

    @Test("Parents sit above and children below")
    func rankingPutsGenerationsInOrder() {
        #expect(RelationshipChart.rank(for: .parent) == -1)
        #expect(RelationshipChart.rank(for: .child) == 1)
        #expect(RelationshipChart.rank(for: .partner) == 0)
        #expect(RelationshipChart.rank(for: .sibling) == 0)
    }

    @Test("Managers sit above and reports below")
    func rankingPutsHierarchyInOrder() {
        #expect(RelationshipChart.rank(for: .manager) == -1)
        #expect(RelationshipChart.rank(for: .directReport) == 1)
        #expect(RelationshipChart.rank(for: .colleague) == 0)
    }

    @Test("A chart's rows come out top to bottom")
    func chartRowsAreOrdered() {
        let subject = UUID()
        let parent = UUID()
        let child = UUID()

        let chart = RelationshipChart(
            kind: .family,
            subjectID: subject,
            nodes: [
                RelationshipNode(id: child, name: "Jack", depth: 1, rank: 1, relationToSubject: .child),
                RelationshipNode(id: subject, name: "Maya", depth: 0, rank: 0),
                RelationshipNode(id: parent, name: "Wei", depth: 1, rank: -1, relationToSubject: .parent),
            ],
            edges: [
                RelationshipEdge(fromID: subject, toID: child, kind: .child),
                RelationshipEdge(fromID: subject, toID: parent, kind: .parent),
            ]
        )

        #expect(chart.rows.map(\.rank) == [-1, 0, 1])
        #expect(chart.rows.first?.nodes.first?.name == "Wei")
        #expect(chart.rows.last?.nodes.first?.name == "Jack")
        #expect(!chart.isEmpty)
    }

    @Test("A chart with only the subject in it is empty")
    func loneSubjectIsAnEmptyChart() {
        let subject = UUID()
        let chart = RelationshipChart(
            kind: .family,
            subjectID: subject,
            nodes: [RelationshipNode(id: subject, name: "Maya", depth: 0, rank: 0)],
            edges: []
        )

        #expect(chart.isEmpty, "one node is not a relationship")
    }

    @Test("A node prefers the word the user actually wrote")
    func customLabelsWin() {
        let node = RelationshipNode(
            id: UUID(), name: "Jack", depth: 1, rank: 1,
            relationToSubject: .child, customLabel: "son"
        )

        #expect(node.roleLabel == "son")
    }

    @Test("And falls back to the relationship's own name")
    func labelFallsBackToTheKind() {
        let node = RelationshipNode(id: UUID(), name: "Jack", depth: 1, rank: 1, relationToSubject: .child)
        #expect(node.roleLabel == "child")
    }
}
