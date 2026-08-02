import ElephruitCore
import Foundation
import Testing

/// The two hands-on insertion routes: Markdown while typing, and the `/` menu's matching.
@Suite("Note insertion")
struct NoteInsertionTests {
    // MARK: Markdown shortcuts

    @Test("Each spelling maps to its kind and consumes exactly its own syntax")
    func markdownSpellings() {
        let cases: [(typed: String, kind: NoteParagraphKind, ticked: Bool)] = [
            ("# ", .heading1, false),
            ("## ", .heading2, false),
            ("### ", .heading3, false),
            ("> ", .quote, false),
            ("- ", .bulleted, false),
            ("* ", .bulleted, false),
            ("- [ ] ", .checklist, false),
            ("- [x] ", .checklist, true),
            ("1. ", .numbered, false),
            ("42. ", .numbered, false),
            ("```", .code, false),
        ]

        for candidate in cases {
            let match = NoteMarkdownShortcut.match(candidate.typed)
            #expect(
                match?.shortcut == .paragraph(kind: candidate.kind, ticked: candidate.ticked),
                "\(candidate.typed)"
            )
            #expect(match?.consumedLength == candidate.typed.count, "\(candidate.typed)")
        }
    }

    @Test("Three dashes become a divider")
    func dividerShortcut() {
        #expect(NoteMarkdownShortcut.match("---")?.shortcut == .divider)
    }

    @Test("What is not a shortcut is left alone")
    func nonShortcutsAreProse() {
        // The function is only ever asked about paragraph-leading text, so these are the strings
        // that could reach it and must not convert.
        #expect(NoteMarkdownShortcut.match("#nospace") == nil)
        #expect(NoteMarkdownShortcut.match("#### ") == nil, "there is no heading 4")
        #expect(NoteMarkdownShortcut.match("1.5 ") == nil, "a decimal is not a list")
        #expect(NoteMarkdownShortcut.match(". ") == nil, "a number needs digits")
        #expect(NoteMarkdownShortcut.match("-- ") == nil)
        #expect(NoteMarkdownShortcut.match("word ") == nil)
    }

    // MARK: The / menu's matching — pure, so it needs no window

    @Test("An empty query offers everything")
    func emptyQueryOffersEverything() {
        #expect(NoteInsertionCommand.matching("") == NoteInsertionCommand.allCases)
        #expect(NoteInsertionCommand.matching("   ") == NoteInsertionCommand.allCases)
    }

    @Test("Searching for what a piece does finds it: tick finds the checklist")
    func matchesOnTheHint() {
        #expect(NoteInsertionCommand.matching("tick").contains(.paragraph(.checklist)))
        #expect(NoteInsertionCommand.matching("boxes").contains(.paragraph(.checklist)))
    }

    @Test("Searching for code finds the code block")
    func codeFindsTheCodeBlock() {
        let matches = NoteInsertionCommand.matching("code")
        #expect(matches.contains(.paragraph(.code)))
    }

    @Test("Collapse finds nothing, now that toggles are gone")
    func collapseFindsNothing() {
        #expect(NoteInsertionCommand.matching("collapse").isEmpty)
    }

    @Test("Matching is on word prefixes, not interior substrings")
    func matchingIsWordPrefix() {
        // "age" sits inside both "Page" and "Image"; neither should answer for it.
        #expect(!NoteInsertionCommand.matching("age").contains(.page))
        #expect(!NoteInsertionCommand.matching("age").contains(.image))
        #expect(NoteInsertionCommand.matching("pag").contains(.page))
    }

    @Test("Case does not matter")
    func matchingIsCaseInsensitive() {
        #expect(NoteInsertionCommand.matching("HEAD").contains(.paragraph(.heading1)))
        #expect(NoteInsertionCommand.matching("Table").contains(.table))
    }

    @Test("Every command belongs to a group, so the menu never invents an ungrouped row")
    func everyCommandIsGrouped() {
        for command in NoteInsertionCommand.allCases {
            #expect(NoteInsertionGroup.allCases.contains(command.group), "\(command.displayName)")
        }
    }
}
