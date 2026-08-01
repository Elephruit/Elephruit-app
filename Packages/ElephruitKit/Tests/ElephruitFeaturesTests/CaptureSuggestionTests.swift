import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing
@testable import ElephruitFeatures

/// What the Quick Jot card offers when you ask it who and where.
///
/// ### Why this is worth a test at all
/// The failure this guards against does not throw, does not log and does not look broken. The person
/// picker opens, the search field takes focus, and it says *nobody here yet* — a complete, confident
/// sentence, in a library with a hundred people in it. Every other capture bug announces itself; this
/// one is indistinguishable from a new install, which is why it survived being shipped.
@MainActor
@Suite("Capture suggestions")
struct CaptureSuggestionTests {
    private let vocabulary = CaptureVocabulary(
        projects: ["Q3 Launch", "Studio Rebuild", "Loft insulation"],
        people: ["Priya Raman", "Sam Okonkwo", "Ramona Petit"]
    )

    private var source: CaptureSuggestionSource {
        CaptureSuggestionSource(services: nil, vocabulary: vocabulary)
    }

    /// The one the picker actually asks, every time it opens.
    @Test("An empty query lists the library rather than nothing")
    func emptyQueryListsEverything() {
        #expect(source.people(matching: "").count == 3)
        #expect(source.containers(matching: "").count == 3)
    }

    @Test("Names are offered in alphabetical order, not storage order")
    func emptyQueryIsSorted() {
        #expect(source.people(matching: "") == ["Priya Raman", "Ramona Petit", "Sam Okonkwo"])
    }

    /// The point of the two passes: Ramona begins with "ra", Priya merely contains it, and both are
    /// worth offering — in that order.
    @Test("A name beginning with the query comes before one merely containing it")
    func prefixesBeatContainments() {
        #expect(source.people(matching: "ra") == ["Ramona Petit", "Priya Raman"])
    }

    @Test("Matching ignores case and accents")
    func matchingIsFolded() {
        #expect(source.people(matching: "PETIT") == ["Ramona Petit"])
        #expect(source.people(matching: "petít") == ["Ramona Petit"])
    }

    @Test("A query nothing answers offers nothing rather than everything")
    func noMatchIsEmpty() {
        #expect(source.people(matching: "zzz").isEmpty)
    }

    @Test("The limit is respected")
    func limitIsRespected() {
        #expect(source.people(matching: "", limit: 2).count == 2)
    }

    /// The other half of the same wire. The picker can only be as right as the vocabulary handed to
    /// it, and that comes from the store — so this asserts the store answers with the people it
    /// holds, without anything having been indexed.
    @Test("The store names the people and projects it holds")
    func vocabularyComesFromTheStore() throws {
        let services = AppServices.inMemory(populated: false)

        _ = try services.items.create(ItemDraft(kind: .person, title: "Priya Raman"))
        _ = try services.items.create(ItemDraft(kind: .project, title: "Q3 Launch"))

        let vocabulary = try services.capture.vocabulary()

        #expect(vocabulary.people.contains("Priya Raman"))
        #expect(vocabulary.projects.contains("Q3 Launch"))

        let source = CaptureSuggestionSource(services: services, vocabulary: vocabulary)
        #expect(source.people(matching: "") == ["Priya Raman"])
        #expect(source.containers(matching: "") == ["Q3 Launch"])
    }
}
