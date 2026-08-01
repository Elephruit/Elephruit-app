import AppKit
import Foundation
import Testing

/// Every SF Symbol this app names actually exists.
///
/// ### Why this is worth a test
/// A symbol name that does not resolve does not throw, does not crash, and does not draw anything.
/// It leaves a hole where an icon should be, and the only sign is one line in the console — `No
/// symbol named 'bubble.left.and.questionmark.bubble.right' found in system symbol set` — among
/// hundreds of lines of unrelated system chatter. Two of them had been shipping: a warning glyph
/// beside a refused global shortcut, and the icon for a conversation topic on a person's profile.
/// Neither was noticed by any amount of looking at the app, because a missing icon looks like an
/// icon somebody chose not to draw.
///
/// The check is the real one: it asks AppKit to make the image, on the machine running the tests.
/// That does mean the test is only as current as its host — a symbol added in a later macOS would
/// fail here on an older one — which is the correct failure, because that is exactly what would
/// happen to a user on that older system.
@Suite("Symbol names")
struct SymbolNameTests {
    /// Lines of code with comments removed and **string literals kept**.
    ///
    /// ``SourceScan/codeLines(of:)`` strips string literals, which is right for every other hygiene
    /// test — they hunt for banned *symbols in code*, and a doc comment naming one should not fail
    /// its own test. Here the string literal is the entire subject, so that helper returns nothing
    /// at all. That is worth spelling out because it failed silently: the scan found zero names, the
    /// "every symbol resolves" check passed over an empty list, and only the count guard caught it.
    ///
    /// Comments are cut at a `//` that is not inside a string, so a URL in a line does not truncate
    /// the rest of it.
    static func codeLinesKeepingStrings(of url: URL) -> [(number: Int, text: String)] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var result: [(Int, String)] = []
        for (index, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
            var insideString = false
            var previous: Character?
            var cut: String.Index?

            var position = rawLine.startIndex
            while position < rawLine.endIndex {
                let character = rawLine[position]
                if character == "\"", previous != "\\" { insideString.toggle() }
                if !insideString, character == "/", previous == "/" {
                    cut = rawLine.index(before: position)
                    break
                }
                previous = character
                position = rawLine.index(after: position)
            }

            let line = cut.map { String(rawLine[..<$0]) } ?? rawLine
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            result.append((index + 1, line))
        }
        return result
    }

    /// Where a symbol name can be written in this codebase.
    ///
    /// Two shapes, because the two live bugs were one of each and a check that only knew the first
    /// would have found only one of them:
    ///
    /// 1. Passed directly — `Image(systemName:)`, `Label(_:systemImage:)`, `symbolName:`.
    /// 2. Returned from a property whose name says it is a symbol, which is how most of this app
    ///    does it: `var symbolName: String { switch self { case .foo: "star" … } }`. Those string
    ///    literals sit on `case` lines and carry nothing that marks them as symbols except the
    ///    declaration they are inside.
    static func namedSymbols() -> [(file: String, line: Int, name: String)] {
        var found: [(String, Int, String)] = []

        let callSite = /(?:systemName|systemImage|symbolName):\s*"([a-z][a-zA-Z0-9._]*)"/
        let declaresSymbols = /(?:var|func)\s+\w*[sS]ymbol\w*\s*(?::|->)/
        let literal = /"([a-z][a-zA-Z0-9._]*)"/

        for url in SourceScan.swiftFiles() {
            var insideSymbolDeclaration = false
            var declarationIndent = 0

            for line in Self.codeLinesKeepingStrings(of: url) {
                let text = line.text
                let indent = text.prefix { $0 == " " }.count

                for match in text.matches(of: callSite) {
                    found.append((url.lastPathComponent, line.number, String(match.1)))
                }

                // A declaration whose *name* contains "symbol" opens a region in which a bare string
                // literal is a symbol name. It closes at the first line indented no further than the
                // declaration itself, which is the closing brace.
                if insideSymbolDeclaration {
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty, indent <= declarationIndent {
                        insideSymbolDeclaration = false
                    } else {
                        for match in text.matches(of: literal) {
                            found.append((url.lastPathComponent, line.number, String(match.1)))
                        }
                    }
                }

                if text.contains(declaresSymbols) {
                    insideSymbolDeclaration = true
                    declarationIndent = indent
                }
            }
        }

        return found.map { (file: $0.0, line: $0.1, name: $0.2) }
    }

    @Test("The scan finds the symbol names it is meant to check")
    func scanIsWiredUp() {
        // Without this the suite passes loudly while checking nothing, which is the failure mode of
        // every test that scans a source tree it cannot find.
        let all = Self.namedSymbols()
        #expect(all.count > 100, "found \(all.count)")
    }

    @Test("Every named symbol resolves")
    @MainActor
    func everySymbolExists() {
        // A symbol declaration also carries strings that are not symbols — an accessibility
        // identifier, a stored raw value that happens to sit in the same switch. Anything that does
        // not resolve *and* does not look like a symbol name would be noise; anything that does not
        // resolve and does look like one is the bug. The distinction that works in practice is
        // whether AppKit knows it, so the allowance is stated explicitly instead of guessed at.
        let knownNotSymbols: Set<String> = [
            "public.data", "public.json", "com.elephruit.archive", "com.elephruit.task-drag",
        ]

        var missing: [String] = []
        var seen: Set<String> = []

        for entry in Self.namedSymbols() {
            guard !knownNotSymbols.contains(entry.name) else { continue }
            // Only names shaped like a symbol. A raw value such as `partner` or an identifier such
            // as `sidebar.home` shares a switch with real symbols and is not one.
            guard entry.name.contains(".") || NSImage(systemSymbolName: entry.name, accessibilityDescription: nil) != nil
            else { continue }
            guard seen.insert(entry.name).inserted else { continue }

            if NSImage(systemSymbolName: entry.name, accessibilityDescription: nil) == nil {
                missing.append("\(entry.file):\(entry.line) — \(entry.name)")
            }
        }

        #expect(
            missing.isEmpty,
            """
            A symbol name that does not resolve draws nothing at all and raises nothing. \
            Check the spelling against SF Symbols: \(missing)
            """
        )
    }
}
