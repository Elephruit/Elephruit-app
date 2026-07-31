import Foundation
import Testing

/// Nothing in this app inspects, inspects into, or reaches across to another process.
///
/// ### Why this test exists
/// A runtime message —
/// `Unable to obtain a task name port right for pid 461: (os/kern) failure (0x5)` —
/// was reported against this app, and "does the app ask for task ports?" turned out to be a
/// question nobody could answer by reading, because the answer was spread across eight modules.
///
/// It does not. pid 461 is `WindowServer`, the message comes from Apple's private `BaseBoard`
/// framework inside the window-server connection handshake, it is logged symmetrically by both
/// sides, and every GUI application on the machine produces it — Apple's own Mail, Calendar,
/// Contacts and Reminders included. Nothing in this source tree is involved in it, and this test
/// is what keeps that true rather than a paragraph in a commit message that ages.
///
/// ### What each banned symbol would mean
/// `task_for_pid` and `task_name_for_pid` are the calls that message is *about*. `proc_pidinfo`,
/// `proc_name` and `NSRunningApplication.activate` inspect or act on another process. The
/// Accessibility and window-list calls enumerate other applications' interfaces. A global `NSEvent`
/// monitor reads keystrokes destined for other apps. `NSAppleScript` and `NSAppleEventDescriptor`
/// drive them. Every one of those needs an entitlement, a TCC prompt, or both — and this app holds
/// five entitlements, none of which is any of these. See `docs/06-privacy-and-entitlements.md`.
///
/// A text scan rather than a parser, and honest about it: it would not catch a symbol assembled
/// from strings at runtime. It catches the way any of these actually gets added, which is somebody
/// typing it.
@Suite("Process access")
struct ProcessAccessTests {
    /// Calls that inspect or act on a process other than this one.
    private static let bannedSymbols = [
        "task_for_pid",
        "task_name_for_pid",
        "processor_set_tasks",
        "proc_pidinfo",
        "proc_name(",
        "proc_listpids",
        "AXUIElementCreateApplication",
        "AXIsProcessTrusted",
        "CGWindowListCopyWindowInfo",
        "addGlobalMonitorForEvents",
        "NSAppleScript",
        "NSAppleEventDescriptor",
    ]

    @Test("No call anywhere asks the kernel about another process")
    func noProcessInspection() {
        var offenders: [String] = []

        for file in SourceScan.swiftFiles() {
            for line in SourceScan.codeLines(of: file) {
                for banned in Self.bannedSymbols where line.text.contains(banned) {
                    offenders.append("\(file.lastPathComponent):\(line.number) — \(banned)")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            These need an entitlement or a TCC prompt this app does not hold, and each is a way the \
            task-port message could become genuinely ours: \(offenders)
            """
        )
    }

    @Test("Giving focus back yields activation rather than reaching into the other application")
    func focusIsYieldedNotTaken() {
        // `NSRunningApplication.activate()` brings another process forward by acting *on* it. It is
        // deprecated as of macOS 14 in favour of `NSApplication.yieldActivation(to:)`, where this
        // app gives up its own activation and names who should have it — which asks nothing of the
        // other process and so has nothing for a terminated one to refuse.
        let panel = SourceScan.swiftFiles().first { $0.lastPathComponent == "QuickJotPanel.swift" }
        #expect(panel != nil, "The Quick Jot panel is where focus is handed back")

        guard let panel else { return }
        let lines = SourceScan.codeLines(of: panel)
        let code = lines.map(\.text).joined(separator: "\n")

        // Activating *this* app is fine and necessary — a panel that is key while the app is not
        // active has no blinking caret and swallows the first keystroke. Activating any *other*
        // application is the call the sandbox is entitled to refuse and a terminated process
        // cannot answer.
        let foreignActivations = lines.filter {
            $0.text.contains(".activate()") && !$0.text.contains("NSApp")
        }
        #expect(
            foreignActivations.isEmpty,
            "Only this application may be activated directly: \(foreignActivations.map(\.number))"
        )
        #expect(
            code.contains("yieldActivation(to:"),
            "Focus should be yielded, not taken"
        )
        // A capture panel is open precisely while somebody is doing something else, and that
        // something else is free to quit before the panel closes.
        #expect(
            code.contains("isTerminated"),
            "A process that has gone away must not be handed anything"
        )
    }
}

/// Scanning the source tree, shared between the hygiene suites.
///
/// Lifted out of `SourceHygieneTests` so a second suite can use it without either owning the other.
enum SourceScan {
    /// The package's `Sources` directory, located by walking up from this file.
    ///
    /// `#filePath` rather than a bundle resource, so the scan needs no build-phase configuration
    /// and works from `swift test` and from Xcode alike.
    static var sourcesDirectory: URL? {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()

        for _ in 0..<8 {
            let candidate = directory.appending(path: "Sources", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    static func swiftFiles() -> [URL] {
        guard let sourcesDirectory,
              let enumerator = FileManager.default.enumerator(
                  at: sourcesDirectory,
                  includingPropertiesForKeys: nil
              )
        else { return [] }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
    }

    /// Lines of code, with comments and string literals removed.
    ///
    /// Without this, every doc comment naming a banned symbol — and this file's own explanation of
    /// why each is banned — would fail its own test.
    static func codeLines(of url: URL) -> [(number: Int, text: String)] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var result: [(Int, String)] = []
        var insideBlockComment = false

        for (index, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
            var line = rawLine

            if insideBlockComment {
                guard let end = line.range(of: "*/") else { continue }
                line = String(line[end.upperBound...])
                insideBlockComment = false
            }

            while let start = line.range(of: "/*") {
                if let end = line.range(of: "*/", range: start.upperBound..<line.endIndex) {
                    line.replaceSubrange(start.lowerBound..<end.upperBound, with: "")
                } else {
                    line = String(line[..<start.lowerBound])
                    insideBlockComment = true
                }
            }

            if let comment = line.range(of: "//") {
                line = String(line[..<comment.lowerBound])
            }

            line = stripStringLiterals(from: line)

            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            result.append((index + 1, line))
        }

        return result
    }

    /// Removes double-quoted literals, so a banned symbol named inside a string is not a use of it.
    private static func stripStringLiterals(from line: String) -> String {
        var output = ""
        var insideString = false
        var previous: Character?

        for character in line {
            if character == "\"", previous != "\\" {
                insideString.toggle()
                previous = character
                continue
            }
            if !insideString { output.append(character) }
            previous = character
        }

        return output
    }
}
