@testable import ElephruitFeatures
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
}
