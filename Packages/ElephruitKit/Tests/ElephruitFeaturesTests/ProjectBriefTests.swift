import Foundation
import Testing

@testable import ElephruitFeatures

/// The brief's reading mode, pinned at the model level.
///
/// The promise under test: stored Markdown is *rendered*, never shown as punctuation — and a
/// wiki link either becomes a real named link or degrades to a plain readable name, never to
/// bracket syntax.
@Suite("Project brief rendering")
struct ProjectBriefTests {
    private func plain(_ block: ProjectBrief.Block) -> String {
        NSAttributedString(block.text).string
    }

    @Test("Headings render as headings, not as hash marks")
    func headingsBecomeHeadings() {
        let blocks = ProjectBrief.blocks(from: "# Title\n\n## Section\n\nBody text.")

        #expect(blocks.count == 3)
        #expect(blocks[0].kind == .heading(level: 1))
        #expect(plain(blocks[0]) == "Title")
        #expect(blocks[1].kind == .heading(level: 2))
        #expect(plain(blocks[1]) == "Section")
        #expect(blocks[2].kind == .paragraph)
        #expect(!plain(blocks[2]).contains("#"))
    }

    @Test("Bulleted and numbered lists carry their structure, not their punctuation")
    func listsBecomeLists() {
        let blocks = ProjectBrief.blocks(from: "- First\n- Second\n\n1. One\n2. Two")

        #expect(blocks.count == 4)
        #expect(blocks[0].kind == .bulleted(indent: 0))
        #expect(plain(blocks[0]) == "First")
        #expect(blocks[1].kind == .bulleted(indent: 0))
        #expect(blocks[2].kind == .ordered(indent: 0, ordinal: 1))
        #expect(blocks[3].kind == .ordered(indent: 0, ordinal: 2))
        #expect(!plain(blocks[2]).contains("1."))
    }

    @Test("Block quotes are quotes")
    func quotesBecomeQuotes() {
        let blocks = ProjectBrief.blocks(from: "> The plan is the plan.")
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .quote)
        #expect(!plain(blocks[0]).contains(">"))
    }

    @Test("A redundant leading “# Brief” is suppressed; any other heading survives")
    func leadingBriefHeadingIsSuppressed() {
        let suppressed = ProjectBrief.displayBlocks(from: "# Brief\n\nShip it.")
        #expect(suppressed.count == 1)
        #expect(plain(suppressed[0]) == "Ship it.")

        let kept = ProjectBrief.displayBlocks(from: "# Goals\n\nShip it.")
        #expect(kept.count == 2)
        #expect(plain(kept[0]) == "Goals")

        // Only the *leading* heading is a duplicate of the section label.
        let midDocument = ProjectBrief.displayBlocks(from: "Intro.\n\n# Brief\n\nDetails.")
        #expect(midDocument.count == 3)
    }

    @Test("A resolved wiki link becomes a named Markdown link")
    func resolvedWikiLinksBecomeLinks() {
        let id = UUID()
        let out = ProjectBrief.resolvingWikiLinks(in: "See [[Pricing Notes]] first.") { link in
            #expect(link.targetTitle == "Pricing Notes")
            return ProjectBrief.wikiURL(for: id)
        }

        #expect(!out.contains("[["))
        #expect(out.contains("[Pricing Notes]("))
        #expect(out.contains(id.uuidString))
    }

    @Test("An unresolved wiki link degrades to its bare name")
    func unresolvedWikiLinksDegradeToNames() {
        let out = ProjectBrief.resolvingWikiLinks(in: "See [[Nowhere]] first.") { _ in nil }
        #expect(out == "See Nowhere first.")
    }

    @Test("The wiki URL round-trips its item identifier")
    func wikiURLRoundTrips() {
        let id = UUID()
        let url = try! #require(ProjectBrief.wikiURL(for: id))
        #expect(ProjectBrief.itemID(from: url) == id)
        #expect(ProjectBrief.itemID(from: URL(string: "https://example.com")!) == nil)
    }

    @Test("Rendered wiki links keep their display text")
    func wikiDisplayTextSurvives() {
        let id = UUID()
        let out = ProjectBrief.resolvingWikiLinks(in: "Ask [[Amara Okonjo|Amara]].") { _ in
            ProjectBrief.wikiURL(for: id)
        }
        #expect(out.contains("[Amara]("))
    }

    @Test("An empty or blank brief renders no blocks")
    func blankBriefIsEmpty() {
        #expect(ProjectBrief.blocks(from: "").isEmpty)
        #expect(ProjectBrief.blocks(from: "  \n\n  ").isEmpty)
    }

    @Test("Inline emphasis stays inline — one paragraph, no literal asterisks")
    func inlineEmphasisIsNotItsOwnBlock() {
        let blocks = ProjectBrief.blocks(from: "The pitch is *less bookkeeping*, not **more features**.")
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .paragraph)
        let text = plain(blocks[0])
        #expect(!text.contains("*"))
        #expect(text.contains("less bookkeeping"))
    }
}
