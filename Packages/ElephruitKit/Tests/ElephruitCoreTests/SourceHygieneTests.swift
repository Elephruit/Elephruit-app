import Foundation
import Testing

/// Enforces the non-negotiables from `README.md` and the milestone-1 definition of done by scanning
/// the source tree.
///
/// A test rather than a convention, because conventions erode: the first `try!` added under time
/// pressure is the one nobody notices in review. This is crude — it is a text scan, not a parser —
/// but it is honest about what it can and cannot see, and it fails loudly.
@Suite("Source hygiene")
struct SourceHygieneTests {
    /// Scanning is shared with `ProcessAccessTests` — see ``SourceScan``.
    ///
    /// Two suites reading the same tree with two copies of the walk is two chances for one of them
    /// to quietly stop finding a directory.
    private static func swiftFiles() -> [URL] { SourceScan.swiftFiles() }

    private static func codeLines(of url: URL) -> [(number: Int, text: String)] {
        SourceScan.codeLines(of: url)
    }

    @Test("The scan can find the source tree")
    func scanIsWiredUp() {
        // Guards against the whole suite silently passing because it found no files to check.
        #expect(SourceScan.sourcesDirectory != nil)
        #expect(Self.swiftFiles().count > 15, "Expected the module sources to be discoverable")
    }

    @Test("No force-unwrapped try")
    func noForceTry() {
        var offenders: [String] = []

        for file in Self.swiftFiles() {
            for line in Self.codeLines(of: file) where line.text.contains("try!") {
                offenders.append("\(file.lastPathComponent):\(line.number)")
            }
        }

        #expect(offenders.isEmpty, "`try!` turns a recoverable error into a crash: \(offenders)")
    }

    @Test("No fatalError, preconditionFailure, or assertionFailure in shipping code")
    func noFatalError() {
        var offenders: [String] = []

        for file in Self.swiftFiles() {
            for line in Self.codeLines(of: file) {
                for banned in ["fatalError(", "preconditionFailure(", "assertionFailure("]
                where line.text.contains(banned) {
                    offenders.append("\(file.lastPathComponent):\(line.number) — \(banned)")
                }
            }
        }

        #expect(offenders.isEmpty, "Recoverable conditions must not terminate the process: \(offenders)")
    }

    @Test("No unchecked Sendable or unsafe isolation escapes")
    func noConcurrencyEscapes() {
        var offenders: [String] = []

        for file in Self.swiftFiles() {
            for line in Self.codeLines(of: file) {
                for banned in ["@unchecked Sendable", "nonisolated(unsafe)", "@preconcurrency"]
                where line.text.contains(banned) {
                    offenders.append("\(file.lastPathComponent):\(line.number) — \(banned)")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            "These are how data races get shipped; models must not cross isolation boundaries: \(offenders)"
        )
    }

    @Test("No singletons")
    func noSharedSingletons() {
        var offenders: [String] = []

        for file in Self.swiftFiles() {
            for line in Self.codeLines(of: file) where line.text.contains("static let shared")
                || line.text.contains("static var shared") {
                offenders.append("\(file.lastPathComponent):\(line.number)")
            }
        }

        #expect(offenders.isEmpty, "Dependencies are injected from one composition root: \(offenders)")
    }

    /// Force unwraps, excluding the one documented and reviewed exception.
    ///
    /// The scan is textual and so is necessarily approximate — it cannot distinguish `x!` from `!=`
    /// perfectly — so it looks for the specific shapes that matter and accepts that a determined
    /// author could evade it. Its job is to catch the accidental one, not to be a proof.
    @Test("No force unwraps outside a #Predicate")
    func noForceUnwraps() {
        var offenders: [String] = []

        for file in Self.swiftFiles() {
            let lines = Self.codeLines(of: file)

            for (index, line) in lines.enumerated() {
                guard containsForceUnwrap(line.text) else { continue }

                // `#Predicate` bodies are exempt: SwiftData offers no translatable alternative for
                // comparing an optional stored column, and `&&` short-circuits so the unwrap is
                // unreachable when the value is nil. Documented on `ItemPredicateBuilder`.
                let window = lines[max(0, index - 12)..<index].map(\.text).joined(separator: " ")
                if window.contains("#Predicate") { continue }

                offenders.append("\(file.lastPathComponent):\(line.number) — \(line.text)")
            }
        }

        #expect(offenders.isEmpty, "Use optional binding rather than a force unwrap: \(offenders)")
    }

    /// Looks for `identifier!` followed by a member access, a call, a subscript, or end of expression,
    /// while ignoring `!=`, prefix `!`, and `try!`/`as!` which have their own tests.
    private func containsForceUnwrap(_ line: String) -> Bool {
        let characters = Array(line)

        for index in characters.indices where characters[index] == "!" {
            // `!=` is a comparison.
            if index + 1 < characters.count, characters[index + 1] == "=" { continue }

            // A prefix `!` is negation; it is preceded by whitespace or an opening bracket.
            guard index > 0 else { continue }
            let previous = characters[index - 1]
            guard previous.isLetter || previous.isNumber || previous == ")" || previous == "]" || previous == "_"
            else { continue }

            // `try!` and `as!` are covered by their own checks.
            let precedingWord = String(characters[max(0, index - 3)..<index])
            if precedingWord.hasSuffix("try") || precedingWord.hasSuffix("as") { continue }

            // A declaration such as `var x: Int!` is an implicitly-unwrapped optional, which is a
            // different smell and does not appear in this codebase; treat it as an offender too.
            return true
        }

        return false
    }

    @Test("No TODO or FIXME standing in for production behaviour")
    func noPlaceholderMarkers() {
        var offenders: [String] = []

        for file in Self.swiftFiles() {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }

            for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
                let upper = line.uppercased()
                // `Phase 2:` and similar forward references are allowed — they name a scheduled piece
                // of work in the roadmap rather than an unfinished code path.
                for marker in ["TODO", "FIXME", "HACK", "XXX:"] where upper.contains(marker) {
                    offenders.append("\(file.lastPathComponent):\(index + 1) — \(marker)")
                }
            }
        }

        #expect(offenders.isEmpty, "Unfinished work belongs in the roadmap, not in a comment: \(offenders)")
    }

    /// Appearance correctness, enforced rather than eyeballed.
    ///
    /// ### Why this is a source check and not a screenshot
    /// A hard-coded colour is wrong in at least one of four conditions — light, dark, Increase
    /// Contrast, and a non-default accent — and it is wrong *silently*: the screen that was reviewed
    /// looked fine. `Theme.Colors` is built entirely from AppKit's semantic colours precisely so that
    /// all four are handled by the system, and this is what keeps a later edit from reaching around
    /// it.
    ///
    /// It is not a substitute for looking at the app. It is the part of "works in dark mode" that can
    /// be guaranteed to still be true next month.
    @Test("No view names a colour the system cannot adapt")
    func coloursComeFromTheDesignSystem() {
        var offenders: [String] = []

        // Literal constructors. `Color(nsColor:)` is absent from this list on purpose — that is how
        // `Theme.Colors` itself is built, and it resolves per appearance.
        let literals = [
            "Color(red:",
            "Color(.sRGB",
            "Color(.displayP3",
            "Color(hue:",
            "NSColor(red:",
            "NSColor(calibratedRed:",
            "NSColor(deviceRed:",
        ]

        for file in Self.swiftFiles() {
            // The tokens file is where the palette is *defined*; everywhere else consumes it.
            guard file.lastPathComponent != "Tokens.swift" else { continue }
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }

            for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }

                for literal in literals where line.contains(literal) {
                    offenders.append("\(file.lastPathComponent):\(index + 1) — \(literal)")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            A literal colour is wrong in light mode, dark mode, Increase Contrast, or under a \
            non-default accent — and wrong invisibly. Use a `Theme.Colors` token: \(offenders)
            """
        )
    }

    /// Decoration that accumulates, caught before it ships.
    ///
    /// ### What actually goes wrong
    /// The failure mode is not one ugly view. It is a second material under a surface that already
    /// had one, or a shadow added to a row that is drawn inside a card that also casts one — each
    /// edit reasonable on its own, the result a window of stacked haze that nobody chose. It
    /// compounds silently, because every intermediate state still renders.
    ///
    /// The rule is one layer of each kind per surface: at most one shadow, at most one material or
    /// glass backing, and no shadow large enough to read as a glow. A floating card wants exactly
    /// one of each — see the link-suggestion popover in `KindDetailViews`, which is the shape this
    /// permits.
    ///
    /// ### What this cannot see
    /// A text scan, like the rest of this suite. It reads a modifier chain as a run of consecutive
    /// lines beginning with a dot, so decoration split across a multi-line `overlay` reads as two
    /// chains rather than one, and nesting spread across two *views* — a card inside a card — is
    /// invisible to it entirely. It catches the accumulation written in one place, which is how
    /// this arrives in practice.
    @Test("No view stacks shadows, materials, or glass on one surface")
    func decorationDoesNotAccumulate() {
        var offenders: [String] = []

        // Every backing that composites what is behind it. A surface wants at most one.
        let backings = [
            ".glassEffect(",
            ".regularMaterial", ".thinMaterial", ".ultraThinMaterial",
            ".thickMaterial", ".ultraThickMaterial",
        ]

        for file in Self.swiftFiles() {
            for chain in Self.modifierChains(of: file) {
                let shadows = chain.filter { $0.text.contains(".shadow(") }
                if shadows.count > 1 {
                    offenders.append(
                        "\(file.lastPathComponent):\(shadows[0].number) — \(shadows.count) shadows on one surface"
                    )
                }

                let backed = chain.filter { line in backings.contains { line.text.contains($0) } }
                if backed.count > 1 {
                    offenders.append(
                        "\(file.lastPathComponent):\(backed[0].number) — \(backed.count) materials on one surface"
                    )
                }

                for line in shadows where Self.shadowRadius(in: line.text).map({ $0 > 24 }) == true {
                    offenders.append("\(file.lastPathComponent):\(line.number) — shadow reads as a glow")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            Depth is one shadow and one material, not several. Stacked layers compound into haze \
            that no single edit chose and none of them looks wrong alone: \(offenders)
            """
        )
    }

    /// A run of consecutive lines that begin with a dot — one view's modifiers, near enough.
    ///
    /// Lines that are only closing brackets continue the run, so a chain survives a multi-line
    /// modifier's tail. Anything else ends it.
    private static func modifierChains(of url: URL) -> [[(number: Int, text: String)]] {
        var chains: [[(number: Int, text: String)]] = []
        var current: [(number: Int, text: String)] = []
        var previousNumber = -1

        func isCloser(_ text: String) -> Bool {
            !text.isEmpty && text.allSatisfy { ")}],".contains($0) }
        }

        for line in codeLines(of: url) {
            let continues = line.number == previousNumber + 1
            let belongs = line.text.hasPrefix(".") || (continues && isCloser(line.text))

            if belongs, continues || line.text.hasPrefix(".") {
                if !continues { chains.append(current); current = [] }
                current.append(line)
            } else {
                if !current.isEmpty { chains.append(current) }
                current = []
            }
            previousNumber = line.number
        }

        if !current.isEmpty { chains.append(current) }
        return chains.filter { !$0.isEmpty }
    }

    /// The literal radius in `.shadow(radius: 8, y: 2)`, when one is written there.
    private static func shadowRadius(in text: String) -> Double? {
        guard let marker = text.range(of: "radius:") else { return nil }
        let rest = text[marker.upperBound...]
        let digits = rest.drop { $0 == " " }.prefix { $0.isNumber || $0 == "." }
        return Double(digits)
    }

    @Test("Log statements do not interpolate values without a privacy annotation")
    func logsAnnotatePrivacy() {
        var offenders: [String] = []

        for file in Self.swiftFiles() {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }

            for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                guard trimmed.contains("Diagnostics."),
                      trimmed.contains("\\("),
                      !trimmed.contains("privacy:")
                else { continue }

                offenders.append("\(file.lastPathComponent):\(index + 1)")
            }
        }

        #expect(
            offenders.isEmpty,
            "Interpolated log values need an explicit privacy annotation so user content cannot leak: \(offenders)"
        )
    }
}
