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

    /// A repeating SwiftUI symbol effect installs a display link and redraws continuously, even
    /// when the symbol only communicates a stable state. Two pulsing recording icons were enough
    /// to hold Elephruit at roughly 40% CPU for the entire duration of a running timer.
    @Test("Symbol effects do not animate indefinitely")
    func symbolEffectsDoNotRepeatIndefinitely() {
        var offenders: [String] = []

        for file in Self.swiftFiles() {
            for line in Self.codeLines(of: file)
            where line.text.contains("symbolEffect(") && line.text.contains(".repeating") {
                offenders.append("\(file.lastPathComponent):\(line.number)")
            }
        }

        #expect(
            offenders.isEmpty,
            "Repeating symbol effects keep the display link active and consume CPU continuously: \(offenders)"
        )
    }

    /// Interface language is a product decision, not whichever dictionary the last contributor
    /// happened to use. Scan string literals in both the package and the app target so a new label,
    /// tooltip, intent description, or accessibility phrase cannot quietly switch dialects.
    ///
    /// The small allowlist is compatibility data, never displayed copy: persisted values must keep
    /// decoding and parsers should continue accepting the spelling somebody may already have typed.
    @Test("User-facing copy uses US English")
    func userFacingCopyUsesUSEnglish() {
        let britishSpellings: Set<String> = [
            "artefact", "artefacts", "authorisation", "behaviour", "behaviours",
            "cancelled", "cancelling", "centre", "centred", "centres",
            "colour", "coloured", "colouring", "colours", "customisation", "customised",
            "dialogue", "dialogues", "favourite", "favourites", "grey", "greyed",
            "initialised", "labelled", "labelling", "localisation", "modelled", "modelling",
            "neighbour", "neighbours", "normalised", "normalising", "optimised",
            "organisation", "organisations", "organiser", "organisers", "prioritised",
            "prioritising", "recognised", "recognising", "recolour", "recoloured",
            "serialised", "summarised", "synchronised", "towards", "travelled", "travelling",
            "uncoloured", "visualisation",
        ]
        let compatibilityLiterals: Set<String> = [
            "calendar.favouriteTimeZones",
            "cancelled",
            "e.status = 'cancelled'",
            "events.is_cancelled = 1",
            "organisation",
            "search.unrecognised",
        ]
        var offenders: [String] = []

        for file in Self.shippingSwiftFiles() {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }

            for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
                for literal in Self.quotedLiterals(in: line) where !compatibilityLiterals.contains(literal) {
                    let visibleText = Self.removingInterpolations(from: literal)
                    let words = Set(visibleText.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
                    let matches = words.intersection(britishSpellings)
                    if !matches.isEmpty {
                        offenders.append(
                            "\(file.lastPathComponent):\(index + 1) — \(matches.sorted().joined(separator: ", "))"
                        )
                    }
                }
            }
        }

        #expect(
            offenders.isEmpty,
            "Displayed copy uses US English; compatibility-only stored values may be allowlisted: \(offenders)"
        )
    }

    private static func shippingSwiftFiles() -> [URL] {
        var files = swiftFiles()
        var directory = URL(filePath: #filePath).deletingLastPathComponent()

        for _ in 0..<10 {
            let appDirectory = directory.appending(path: "Elephruit", directoryHint: .isDirectory)
            let appEntry = appDirectory.appending(path: "ElephruitApp.swift")
            if FileManager.default.fileExists(atPath: appEntry.path(percentEncoded: false)),
               let enumerator = FileManager.default.enumerator(
                   at: appDirectory,
                   includingPropertiesForKeys: nil
               ) {
                files += enumerator
                    .compactMap { $0 as? URL }
                    .filter { $0.pathExtension == "swift" }
                break
            }
            directory = directory.deletingLastPathComponent()
        }
        return files
    }

    /// String literals written wholly on one source line. Interpolation is removed separately so a
    /// legacy identifier such as `cancelled` does not make otherwise-US copy fail the rule.
    private static func quotedLiterals(in line: String) -> [String] {
        var literals: [String] = []
        var current = ""
        var isInsideString = false
        var isEscaped = false

        for character in line {
            if isEscaped {
                if isInsideString { current.append(character) }
                isEscaped = false
            } else if character == "\\" {
                if isInsideString { current.append(character) }
                isEscaped = true
            } else if character == "\"" {
                if isInsideString {
                    literals.append(current)
                    current = ""
                }
                isInsideString.toggle()
            } else if isInsideString {
                current.append(character)
            }
        }
        return literals
    }

    private static func removingInterpolations(from literal: String) -> String {
        let characters = Array(literal)
        var result = ""
        var index = 0

        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count, characters[index + 1] == "(" {
                index += 2
                var depth = 1
                while index < characters.count, depth > 0 {
                    if characters[index] == "(" { depth += 1 }
                    if characters[index] == ")" { depth -= 1 }
                    index += 1
                }
            } else {
                result.append(characters[index])
                index += 1
            }
        }
        return result
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

        // SwiftUI's *named* colours, which this test did not look for and which had accumulated to
        // twenty-four uses across six files while the README recorded that "no view names a literal
        // colour" and rested a dark-mode guarantee on it.
        //
        // Most of them adapt, so most were not bugs — they were the palette being bypassed, which is
        // the same nine-decisions-instead-of-one problem `Theme.Palette` exists to prevent.
        // `Color.white` is the one that is simply wrong: it does not adapt at all, and it was being
        // used for text on a fill that is pale under Increase Contrast and at the low end of an
        // intensity scale, where white on near-white is invisible. `Theme.Colors.onAccent` is the
        // token for that question.
        //
        // Matched with a trailing delimiter so `Color.white` is caught and a hypothetical
        // `Color.whiteboardTint` is not.
        // Written out in full: `Color.white`, `Color.purple`. A literal rather than a regex built
        // from the list at runtime, so it is checked at compile time and needs no `try`.
        // The trailing check is a lookahead for identifier characters rather than `\b`. Swift
        // Regex's default `\b` is the Unicode word boundary, and Unicode word segmentation treats
        // a dot between letters as *mid-word* — "black.opacity" is one word to it, the way
        // "example.com" is. So `.shadow(color: .black.opacity(0.1))` sailed through the boundary
        // check for as long as the literal had a method chained onto it, which shadows always do.
        // The lookahead keeps what the boundary was for: `.reduce` and `CharacterSet.whitespaces`
        // still do not match, because `u` and `s` are identifier characters.
        let explicitColour =
            /\bColor\.(pink|red|blue|green|orange|yellow|purple|gray|grey|brown|teal|cyan|indigo|mint|black|white)(?![A-Za-z0-9_])/

        // And the *implicit* form, which the first version of this missed entirely. Swift infers the
        // base type in an argument or a return, so `tint: .purple` and `.shadow(color: .black…)` are
        // the same literal with `Color` left off — and the person profile was passing two of them
        // into a view that took a `Color`, right beside the ones written out in full that this test
        // did catch. Half a rule is worse than none: it made the file look audited.
        //
        // Two boundaries are doing real work here, and the version without them reported two hundred
        // offenders that were nothing of the kind:
        //
        // - **Nothing identifier-like before the dot.** That is what separates `tint: .purple` from
        //   `Theme.Palette.red.color`, which is code reaching the palette — the thing this test wants
        //   people to do.
        // - **A word boundary after the name.** Without it `.white` matches `CharacterSet.whitespaces`
        //   and `.red` matches `.reduce`, which is most of this codebase.
        // A leading group rather than a look-behind, which Swift Regex does not support.
        let implicitColour =
            /(^|[^A-Za-z0-9_])\.(pink|red|blue|green|orange|yellow|purple|gray|grey|brown|teal|cyan|indigo|mint|black|white)(?![A-Za-z0-9_])/

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

                for match in line.matches(of: explicitColour) {
                    offenders.append("\(file.lastPathComponent):\(index + 1) — \(match.0)")
                }
                for match in line.matches(of: implicitColour) {
                    offenders.append("\(file.lastPathComponent):\(index + 1) — \(match.0)")
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

    // MARK: - The metric layer
    //
    // The colour rule above held at one violation in five hundred files because it was tested; the
    // numeric layer failed at 581 across 82 files because it was not. The four tests below are its
    // equivalents. Each carries an allowlist of the files that were already off the scale when the
    // rule arrived — a debt ledger, not a permission slip: entries only come *off* as the phases
    // clean their files, and a file that is clean today may not regress tomorrow. Adding a file to
    // an allowlist is the one edit these tests exist to make embarrassing.

    /// Runs one line-level check over every source file, honouring an allowlist.
    private func metricScan(
        exempt: Set<String> = [],
        allowlisted: Set<String>,
        offense: (String) -> String?
    ) -> (offenders: [String], stale: [String]) {
        var offenders: [String] = []
        var offendersInAllowlistedFiles: Set<String> = []

        for file in Self.swiftFiles() {
            let name = file.lastPathComponent
            guard !exempt.contains(name) else { continue }
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }

            for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                guard let found = offense(line) else { continue }

                if allowlisted.contains(name) {
                    offendersInAllowlistedFiles.insert(name)
                } else {
                    offenders.append("\(name):\(index + 1) — \(found)")
                }
            }
        }

        // An allowlist entry whose file has come clean is a rule quietly weaker than it looks.
        let stale = allowlisted.subtracting(offendersInAllowlistedFiles).sorted()
        return (offenders, stale)
    }

    @Test("Shadows come from the elevation scale")
    func shadowsComeFromElevation() {
        let allowlisted: Set<String> = [
            "FloatingTimerView.swift", "KanbanBoardView.swift", "KindDetailViews.swift",
            "NoteWorkspacePanels.swift",
            "ReminderComposer.swift", "SectionIndexBar.swift",
        ]

        let (offenders, stale) = metricScan(
            exempt: ["Tokens.swift"],
            allowlisted: allowlisted
        ) { line in
            line.contains(".shadow(") ? ".shadow(" : nil
        }

        #expect(
            offenders.isEmpty,
            "A raw shadow is a depth nobody decided. Use `.elevation(_:)`: \(offenders)"
        )
        #expect(stale.isEmpty, "These files are clean — remove them from the allowlist: \(stale)")
    }

    @Test("Fonts come from the type scale")
    func fontsComeFromTheTypeScale() {
        let allowlisted: Set<String> = [
            "BugTrackerView.swift", "CalendarMenuBar.swift", "CalendarMonthView.swift",
            "CalendarOverviewViews.swift", "CalendarTimeGrid.swift", "CaptureActionRow.swift",
            "CaptureChipRow.swift", "Components.swift", "ContactOnboardingView.swift",
            "EventQuickEntry.swift", "KanbanBoardView.swift", "LinkedContactViews.swift",
            "MonthGrid.swift",
            "ProjectsSidebarSection.swift", "ReminderComposer.swift",
            "ReminderMonthPicker.swift", "SectionIndexBar.swift", "SwipeActionsRow.swift",
            "TodayComponents.swift", "TodayPeopleViews.swift", "TodayRows.swift",
            "WorkItemCompletionControl.swift", "WorkItemDetailView.swift",
            "WorkItemViews.swift",
        ]

        let (offenders, stale) = metricScan(
            exempt: ["Tokens.swift", "AppKitTokens.swift"],
            allowlisted: allowlisted
        ) { line in
            if line.contains(".font(.system(size:") { return ".font(.system(size:" }
            if line.contains("Font.system(size:") { return "Font.system(size:" }
            return nil
        }

        #expect(
            offenders.isEmpty,
            """
            A fixed point size defeats Dynamic Type, which every `Theme.Text` style honours by \
            construction. Use a token — `denseLabel` is the floor for the dense surfaces: \(offenders)
            """
        )
        #expect(stale.isEmpty, "These files are clean — remove them from the allowlist: \(stale)")
    }

    @Test("Corner radii come from the four-step scale")
    func radiiComeFromTheScale() throws {
        let allowlisted: Set<String> = [
            "CalendarAgendaView.swift", "CalendarMonthView.swift", "CalendarOverviewViews.swift",
            "CalendarSearchView.swift", "Components.swift", "EventInspectorView.swift",
            "TodayRows.swift",
        ]

        // 4, 6, 10, 16 — `Theme.Radius`. Zero is "no radius", which is a statement, not a value.
        let allowed: Set<Int> = [0, 4, 6, 10, 16]
        let literal = /cornerRadius: *(\d+)/

        let (offenders, stale) = metricScan(
            exempt: ["Tokens.swift"],
            allowlisted: allowlisted
        ) { line in
            for match in line.matches(of: literal) {
                guard let value = Int(match.1), !allowed.contains(value) else { continue }
                return "cornerRadius: \(value)"
            }
            return nil
        }

        #expect(
            offenders.isEmpty,
            "Twelve distinct radii grew against a scale of three. Use `Theme.Radius`: \(offenders)"
        )
        #expect(stale.isEmpty, "These files are clean — remove them from the allowlist: \(stale)")
    }

    @Test("Padding stays on the grid")
    func paddingStaysOnTheGrid() throws {
        let allowlisted: Set<String> = [
            "BugTrackerView.swift", "CalendarAgendaView.swift", "CalendarMonthView.swift",
            "CalendarSearchView.swift", "CalendarTimeGrid.swift", "CaptureSuggestionSource.swift",
            "Components.swift", "ContactImportReviewView.swift", "MapPlaceSearchField.swift",
            "ProjectCalendarView.swift", "ReminderComposer.swift", "TimeEntryEditing.swift",
            "TimePickers.swift", "TodayRows.swift", "WorkItemDetailView.swift",
        ]

        // The grid: eight-major, four-half-step, two as the glyph gap. `Theme.Spacing`, as numbers.
        let allowed: Set<Int> = [0, 2, 4, 8, 12, 16, 24, 32, 40]
        let literal = /\.padding\((?:\.[a-zA-Z]+, *)?(\d+)\)/

        let (offenders, stale) = metricScan(
            exempt: ["Tokens.swift"],
            allowlisted: allowlisted
        ) { line in
            for match in line.matches(of: literal) {
                guard let value = Int(match.1), !allowed.contains(value) else { continue }
                return ".padding(\(value))"
            }
            return nil
        }

        #expect(
            offenders.isEmpty,
            """
            One- and three-point paddings are not density, they are drift — thirty-three of them \
            had accumulated below the scale's own floor. Use `Theme.Spacing`: \(offenders)
            """
        )
        #expect(stale.isEmpty, "These files are clean — remove them from the allowlist: \(stale)")
    }

    @Test("Animation honours Reduce Motion by construction")
    func animationsHonourReduceMotion() {
        let allowlisted: Set<String> = [
            "BugTrackerView.swift", "EventEditorView.swift", "EventInspectorView.swift",
            "FloatingTimerView.swift", "KanbanBoardView.swift",
            "ReminderComposer.swift",
            "RootView.swift", "TodayComponents.swift",
            "TodayDayView.swift", "TodayPeopleViews.swift", "TodayRows.swift", "TodayView.swift",
            "WorkItemDetailView.swift",
        ]

        // `.calmAnimation` reads Reduce Motion itself, and an imperative `withAnimation` wrapped
        // in `respectingReduceMotion` has made the same promise by hand. The wrap legitimately
        // spans lines, so the check looks a two-line window around the call rather than at the
        // call's line alone — anything else animates for the people who asked it not to.
        var offenders: [String] = []
        var offendersInAllowlistedFiles: Set<String> = []

        for file in Self.swiftFiles() {
            let name = file.lastPathComponent
            guard name != "Tokens.swift" else { continue }
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = contents.components(separatedBy: .newlines)

            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                guard !line.contains("calmAnimation") else { continue }
                guard line.contains("withAnimation(") || line.contains(".animation(") else { continue }

                let window = lines[max(0, index - 2)...min(lines.count - 1, index + 2)]
                guard !window.contains(where: { $0.contains("respectingReduceMotion") }) else { continue }

                if allowlisted.contains(name) {
                    offendersInAllowlistedFiles.insert(name)
                } else {
                    offenders.append("\(name):\(index + 1)")
                }
            }
        }

        let stale = allowlisted.subtracting(offendersInAllowlistedFiles).sorted()

        #expect(
            offenders.isEmpty,
            """
            Nine of twelve ad-hoc animations bypassed Reduce Motion, against an explicit promise \
            in Tokens.swift. Use `.calmAnimation`, or wrap in `Theme.Motion.respectingReduceMotion`: \
            \(offenders)
            """
        )
        #expect(stale.isEmpty, "These files are clean — remove them from the allowlist: \(stale)")
    }
}
