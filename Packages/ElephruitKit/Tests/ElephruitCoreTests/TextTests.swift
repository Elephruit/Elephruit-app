import ElephruitCore
import Foundation
import Testing

@Suite("Text normalisation")
struct TextNormalizerTests {
    @Test("Slugs fold case, diacritics, and punctuation")
    func slugNormalises() {
        #expect(TextNormalizer.slug("Q3 Läunch — Planning!") == "q3-launch-planning")
        #expect(TextNormalizer.slug("Work") == "work")
        #expect(TextNormalizer.slug("WORK") == "work")
        #expect(TextNormalizer.slug("  spaced   out  ") == "spaced-out")
        #expect(TextNormalizer.slug("Café") == "cafe")
    }

    @Test("Hierarchy separators survive slugging")
    func slugPreservesHierarchy() {
        #expect(TextNormalizer.slug("Work/Clients/Acme Corp") == "work/clients/acme-corp")
        #expect(TextNormalizer.slugComponents("work/clients/acme") == ["work", "clients", "acme"])
        #expect(TextNormalizer.slugComponents("work") == ["work"])
    }

    @Test("A name with no letters or digits is not a usable slug")
    func punctuationOnlyIsInvalid() {
        #expect(!TextNormalizer.isValidSlug(TextNormalizer.slug("!!!")))
        #expect(!TextNormalizer.isValidSlug(""))
        #expect(TextNormalizer.isValidSlug(TextNormalizer.slug("a")))
    }

    @Test("Matching form is case- and diacritic-insensitive with collapsed whitespace")
    func foldedMatching() {
        #expect(TextNormalizer.foldedForMatching("Café  Planning") == "cafe planning")
        #expect(TextNormalizer.foldedForMatching("CAFE PLANNING") == "cafe planning")
        #expect(TextNormalizer.foldedForMatching("\n Leading\tand trailing \n") == "leading and trailing")
    }

    @Test("Search terms are deduplicated and exclude single characters")
    func searchTerms() {
        let terms = TextNormalizer.searchTerms(in: "The quick quick brown fox a b c")
        #expect(terms.contains("quick"))
        #expect(terms.count(where: { $0 == "quick" }) == 1)
        #expect(!terms.contains("a"))
        #expect(terms.contains("the"))
    }

    @Test("Excerpts strip Markdown noise and show content")
    func excerptStripsSyntax() {
        let body = """
        # A Heading

        > A quote

        - [ ] A task item
        Some actual prose.
        """
        let excerpt = TextNormalizer.excerpt(from: body)

        #expect(excerpt.hasPrefix("A Heading"))
        #expect(!excerpt.contains("#"))
        #expect(!excerpt.contains("- [ ]"))
        #expect(excerpt.contains("A task item"))
    }

    @Test("Excerpts truncate at a word boundary")
    func excerptTruncatesCleanly() {
        let body = String(repeating: "word ", count: 200)
        let excerpt = TextNormalizer.excerpt(from: body, limit: 50)

        #expect(excerpt.count <= 51)
        #expect(excerpt.hasSuffix("…"))
        #expect(!excerpt.contains("wor…"), "Should not cut mid-word")
    }

    @Test("A fence line alone contributes nothing")
    func excerptSkipsCodeFences() {
        let excerpt = TextNormalizer.excerpt(from: "```swift\nlet x = 1\n```")
        #expect(excerpt == "let x = 1")
    }
}

@Suite("Wiki links")
struct WikiLinkParserTests {
    @Test("Finds simple links")
    func findsSimpleLinks() {
        let text = "See [[First Note]] and [[Second Note]] for detail."
        let links = WikiLinkParser.links(in: text)

        #expect(links.count == 2)
        #expect(links[0].targetTitle == "First Note")
        #expect(links[1].targetTitle == "Second Note")
        #expect(links[0].displayText == nil)
    }

    @Test("Reads alias syntax")
    func readsAliases() {
        let links = WikiLinkParser.links(in: "See [[Quarterly Planning|the plan]].")

        #expect(links.count == 1)
        #expect(links[0].targetTitle == "Quarterly Planning")
        #expect(links[0].displayText == "the plan")
        #expect(links[0].label == "the plan")
    }

    @Test("An unterminated opening produces nothing rather than an error")
    func unterminatedIsIgnored() {
        #expect(WikiLinkParser.links(in: "Halfway through typing [[Some ti").isEmpty)
        #expect(WikiLinkParser.links(in: "[[").isEmpty)
    }

    @Test("Empty and whitespace-only targets are not links")
    func emptyTargetsIgnored() {
        #expect(WikiLinkParser.links(in: "[[]]").isEmpty)
        #expect(WikiLinkParser.links(in: "[[   ]]").isEmpty)
    }

    @Test("Match keys fold case and diacritics")
    func matchKeysAreFolded() {
        let links = WikiLinkParser.links(in: "[[Café Planning]]")
        #expect(links.first?.matchKey == "cafe planning")
    }

    @Test("Text with no brackets is not scanned at all")
    func fastPathForPlainText() {
        #expect(WikiLinkParser.links(in: "Just some ordinary prose.").isEmpty)
    }

    @Test("Detects the partial link the caret sits inside")
    func detectsActiveCompletion() {
        let text = "See [[Quart"
        let caret = text.endIndex

        let active = WikiLinkParser.activeCompletion(in: text, caretAt: caret)
        #expect(active?.query == "Quart")
    }

    @Test("No completion outside a link, after a close, or across a line")
    func noCompletionWhenNotInLink() {
        let plain = "Just typing"
        #expect(WikiLinkParser.activeCompletion(in: plain, caretAt: plain.endIndex) == nil)

        let closed = "See [[Done]] now"
        #expect(WikiLinkParser.activeCompletion(in: closed, caretAt: closed.endIndex) == nil)

        let multiline = "See [[Start\nnext line"
        #expect(WikiLinkParser.activeCompletion(in: multiline, caretAt: multiline.endIndex) == nil)
    }

    @Test("Link syntax sanitises characters that would not parse back")
    func linkSyntaxIsSafe() {
        #expect(WikiLinkParser.linkSyntax(forTitle: "Simple") == "[[Simple]]")
        #expect(WikiLinkParser.linkSyntax(forTitle: "Has ] bracket") == "[[Has  bracket]]")
        #expect(WikiLinkParser.linkSyntax(forTitle: "Has | pipe") == "[[Has - pipe]]")
    }

    @Test("A round trip through link syntax finds the same title")
    func roundTripsThroughSyntax() {
        let title = "Quarterly Planning"
        let links = WikiLinkParser.links(in: WikiLinkParser.linkSyntax(forTitle: title))
        #expect(links.first?.targetTitle == title)
    }
}

@Suite("Day keys")
struct DayKeyTests {
    @Test("Keys are zero-padded and sort chronologically")
    func keysArePaddedAndSortable() {
        #expect(DayKey.string(year: 2026, month: 7, day: 4) == "2026-07-04")
        #expect(DayKey.string(year: 999, month: 12, day: 31) == "0999-12-31")

        let keys = ["2026-12-01", "2026-01-15", "2025-06-30"].sorted()
        #expect(keys == ["2025-06-30", "2026-01-15", "2026-12-01"])
    }

    @Test("Well-formed keys read back, malformed ones do not")
    func validationIsStrict() {
        let components = DayKey.components(from: "2026-07-29")
        #expect(components?.year == 2026)
        #expect(components?.month == 7)
        #expect(components?.day == 29)

        #expect(DayKey.components(from: "2026-7-29") == nil, "Unpadded is not a key")
        #expect(DayKey.components(from: "26-07-29") == nil)
        #expect(DayKey.components(from: "2026-13-01") == nil)
        #expect(DayKey.components(from: "not a date") == nil)
        #expect(!DayKey.isValid(""))
    }

    @Test("Day keys do not shift with time zone")
    func keysAreCalendarDaysNotInstants() {
        // 23:30 on 29 July in a calendar 10 hours ahead of GMT is still 29 July there.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 10 * 3600) ?? .gmt

        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 29
        components.hour = 23
        components.minute = 30

        let date = calendar.date(from: components)
        let provider = FixedDateProvider(now: date ?? Date(), calendar: calendar)

        #expect(provider.dayKey(for: provider.now) == "2026-07-29")
    }
}
