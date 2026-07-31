import ElephruitCore
import ElephruitFeatures
import ElephruitModel
import ElephruitSearch
import Foundation
import Testing

/// The seam an App Intent uses.
///
/// ### Why these live here rather than in the app target
/// `CaptureIntent` is in the app, which has no test target and no test host. So the part worth
/// asserting — that a capture from outside the window is *complete* — was untestable where it lived,
/// and duly went wrong: the intent wrote the row and never touched the index, so everything captured
/// from Spotlight or Shortcuts was invisible to search.
///
/// `AppServices.captureText` is that logic moved somewhere it can be tested. The intent is now the
/// thin part.
@MainActor
@Suite("Capture wiring")
struct CaptureWiringTests {
    /// Indexing is deliberately not synchronous with the save — see ADR 0007 — so the assertion is
    /// "eventually findable", which is the real contract. A bounded poll is the honest encoding of
    /// it; a fixed sleep would be either flaky or slow.
    private func findable(_ term: String, in services: AppServices, within: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: within)
        while ContinuousClock.now < deadline {
            let results = (try? await services.search.search(SearchQueryParser.parse(term), limit: 20)) ?? []
            if !results.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test("Text captured without a view is findable by search")
    func capturedTextIsIndexed() async throws {
        let services = AppServices.inMemory(populated: false)
        await services.warmSearchIndex()

        let item = try #require(try services.captureText("Renew the studio insurance"))
        #expect(item.title == "Renew the studio insurance")

        #expect(await findable("studio insurance", in: services), "captured but never indexed")
    }

    @Test("The grammar still applies through this path")
    func grammarSurvivesTheSeam() async throws {
        let services = AppServices.inMemory(populated: false)
        await services.warmSearchIndex()

        let item = try #require(try services.captureText("- Call the framer #errand !tomorrow"))

        #expect(item.kind == .task)
        #expect(item.dueAt != nil)
        #expect(item.tags.contains { $0.slug == "errand" })
    }

    @Test("Empty text captures nothing and indexes nothing")
    func emptyTextIsRefused() async throws {
        let services = AppServices.inMemory(populated: false)
        #expect(try services.captureText("   \n ") == nil)
    }

    @Test("A person named in a capture is linked, and the link is committed")
    func peopleAreLinkedAndCommitted() async throws {
        let services = AppServices.inMemory(populated: false)

        let item = try #require(try services.captureText("Coffee with @Priya"))

        #expect(services.context.hasChanges == false)
        #expect(item.outgoingLinks.contains { $0.kind == .mentions })
    }
}
