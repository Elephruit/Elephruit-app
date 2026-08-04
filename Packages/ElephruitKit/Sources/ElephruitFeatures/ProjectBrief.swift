import ElephruitCore
import Foundation

/// The project brief, understood as Markdown blocks rather than shown as Markdown source.
///
/// The brief is stored as portable plain text — the same containment as every other body in the
/// app — but *reading* it should never require parsing punctuation by eye. This turns the stored
/// string into a small list of typed blocks the Home page can set properly: headings as headings,
/// lists as lists, quotes as quotes, and `[[Wiki Links]]` as links wearing their names.
///
/// Deliberately a value-level model with no view code, so every rule here — what becomes a block,
/// which heading is suppressed, how a wiki link resolves or degrades — is a plain assertion in
/// `ProjectBriefTests` rather than a screenshot.
enum ProjectBrief {
    /// One block of the rendered brief, in document order.
    struct Block: Identifiable, Equatable {
        enum Kind: Equatable {
            case heading(level: Int)
            case paragraph
            /// `indent` counts nesting below the outermost list, starting at zero.
            case bulleted(indent: Int)
            case ordered(indent: Int, ordinal: Int)
            case quote
        }

        let id: Int
        let kind: Kind
        let text: AttributedString
    }

    /// The scheme rendered wiki links carry; the view resolves it back to an item identifier.
    static let wikiScheme = "elephruit-wiki"

    /// Replaces `[[Wiki Links]]` with Markdown links the renderer can set as names.
    ///
    /// `resolve` answers with the URL for a title the library knows, or `nil` for one it does
    /// not. A resolved link becomes `[Name](url)`; an unresolved one degrades to its bare name —
    /// readable, unpunctuated, and honestly not a link, because a link to nowhere is a promise
    /// the click cannot keep.
    static func resolvingWikiLinks(
        in source: String,
        resolve: (WikiLink) -> URL?
    ) -> String {
        let links = WikiLinkParser.links(in: source)
        guard !links.isEmpty else { return source }

        var result = ""
        var cursor = source.startIndex
        for link in links {
            result += source[cursor..<link.range.lowerBound]
            if let url = resolve(link) {
                result += "[\(link.label)](\(url.absoluteString))"
            } else {
                result += link.label
            }
            cursor = link.range.upperBound
        }
        result += source[cursor...]
        return result
    }

    /// A stable URL for a wiki link the library resolved to an item.
    static func wikiURL(for itemID: UUID) -> URL? {
        URL(string: "\(wikiScheme)://item/\(itemID.uuidString)")
    }

    /// The item a rendered wiki link points back to, if `url` is one of ours.
    static func itemID(from url: URL) -> UUID? {
        guard url.scheme == wikiScheme, url.host() == "item" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    /// Parses Markdown into blocks.
    ///
    /// Built on Foundation's own Markdown parsing — the presentation intents carry the block
    /// structure, the inline intents (emphasis, strong text, links, code) stay in the attributed
    /// text for `Text` to set. A string that fails to parse degrades to one paragraph of itself:
    /// the reading mode must never show less than the stored text.
    static func blocks(from markdown: String) -> [Block] {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard let attributed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: false,
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else {
            return [Block(id: 0, kind: .paragraph, text: AttributedString(trimmed))]
        }

        var blocks: [Block] = []
        var currentIdentity: Int?

        for run in attributed.runs {
            let components = run.presentationIntent?.components ?? []
            let identity = components.first?.identity ?? -1
            var piece = AttributedString(attributed[run.range])
            piece.presentationIntent = nil

            if identity == currentIdentity, !blocks.isEmpty {
                var last = blocks.removeLast()
                last = Block(id: last.id, kind: last.kind, text: last.text + piece)
                blocks.append(last)
            } else {
                currentIdentity = identity
                blocks.append(Block(id: identity, kind: kind(of: components), text: piece))
            }
        }

        // Foundation separates paragraphs; stray whitespace-only blocks earn no pixels.
        return blocks.filter {
            !NSAttributedString($0.text).string
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Blocks as the Brief section shows them: with a redundant leading `# Brief` suppressed,
    /// because the interface already says "Brief" once, immediately above.
    static func displayBlocks(from markdown: String) -> [Block] {
        let all = blocks(from: markdown)
        guard let first = all.first,
              case .heading = first.kind,
              NSAttributedString(first.text).string
                  .trimmingCharacters(in: .whitespacesAndNewlines)
                  .lowercased() == "brief"
        else { return all }
        return Array(all.dropFirst())
    }

    /// Block kind from a run's presentation components, which arrive innermost first.
    private static func kind(of components: [PresentationIntent.IntentType]) -> Block.Kind {
        var ordinal: Int?
        var sawListItem = false
        var listKinds: [Bool] = []  // true = ordered, in nesting order outward
        var headingLevel: Int?
        var isQuote = false

        for component in components {
            switch component.kind {
            case .header(let level):
                headingLevel = level
            case .listItem(let itemOrdinal):
                sawListItem = true
                if ordinal == nil { ordinal = itemOrdinal }
            case .orderedList:
                listKinds.append(true)
            case .unorderedList:
                listKinds.append(false)
            case .blockQuote:
                isQuote = true
            default:
                break
            }
        }

        if let headingLevel {
            return .heading(level: headingLevel)
        }
        if sawListItem, let firstList = listKinds.first {
            let indent = max(0, listKinds.count - 1)
            return firstList
                ? .ordered(indent: indent, ordinal: ordinal ?? 1)
                : .bulleted(indent: indent)
        }
        if isQuote {
            return .quote
        }
        return .paragraph
    }
}
