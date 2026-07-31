import ElephruitCore
@testable import ElephruitFeatures
import Foundation
import Testing

@Suite("Person capture sheets")
struct PersonCaptureSheetTests {
    @Test("A note title can come from its first line")
    func noteTitleFallback() {
        let draft = PersonNoteDraft(body: "Remember the gallery opening\nBring Maya's book")

        #expect(draft.resolvedTitle(personName: "Maya") == "Remember the gallery opening")
        #expect(draft.cleanedBody == "Remember the gallery opening\nBring Maya's book")
    }

    @Test("Quick note choices become searchable tags")
    func noteCategoriesBecomeTags() {
        #expect(PersonNoteDraft(category: .general).tagSlugs.isEmpty)
        #expect(PersonNoteDraft(category: .personal).tagSlugs == ["personal"])
        #expect(PersonNoteDraft(category: .work).tagSlugs == ["work"])
        #expect(PersonNoteDraft(category: .idea).tagSlugs == ["idea"])
    }

    @Test("Interaction action lists become individual records")
    func interactionListsSplitOnLines() {
        let draft = PersonInteractionDraft(
            kind: .phone,
            summary: "Project catch-up",
            discussion: "Launch timing",
            followUps: "Send the deck\n\nBook Tuesday",
            commitments: "Introduce Maya to Sam\nShare the brief"
        )

        #expect(draft.followUpItems == ["Send the deck", "Book Tuesday"])
        #expect(draft.commitmentItems == ["Introduce Maya to Sam", "Share the brief"])
        #expect(draft.kind.tagSlug == "interaction/phone")
    }

    @Test("The chosen interaction kind reads back in the timeline")
    func interactionKindRoundTripsIntoTimelineLanguage() {
        let stored = PersonInteractionKind(tagSlugs: ["interaction/video"])
        let entry = PersonTimelineEntry(
            id: UUID(),
            kind: .interaction,
            title: "Project catch-up",
            date: Date(),
            provenance: .logged,
            interactionKind: stored
        )

        #expect(stored == .video)
        #expect(entry.provenanceLine == "video — logged")
    }

    @Test("Quick facts use searchable, practical categories")
    func quickFactCategories() {
        #expect(QuickFactCategory.foodAndDrink.attribute == .foodAndDrink)
        #expect(QuickFactCategory.family.attribute == .family)
        #expect(QuickFactCategory.askAbout.attribute == .conversationTopic)
        #expect(QuickFactCategory.foodAndDrink.suggestions.contains("Vegetarian"))
        #expect(QuickFactCategory.foodAndDrink.suggestions.contains("Doesn’t drink alcohol"))
        #expect(QuickFactCategory.foodAndDrink.suggestions.contains("Likes wine"))
    }
}
