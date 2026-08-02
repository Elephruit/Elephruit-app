import AppKit
@testable import ElephruitFeatures
import SwiftUI
import Testing

@Suite("Bug report text editor")
@MainActor
struct BugReportTextEditorTests {
    private struct FocusHarness: View {
        @State private var focusedEditor = 0

        var body: some View {
            VStack {
                editor(index: 0, prompt: "Notes")
                editor(index: 1, prompt: "Steps")
            }
        }

        private func editor(index: Int, prompt: String) -> some View {
            BugReportTextEditor(
                text: .constant(""),
                placeholder: prompt,
                isFocused: focusedEditor == index,
                onFocusChange: { isFocused in
                    if isFocused { focusedEditor = index }
                },
                onTraverse: { backwards in
                    let destination = index + (backwards ? -1 : 1)
                    guard (0...1).contains(destination) else { return false }
                    focusedEditor = destination
                    return true
                }
            )
            .frame(width: 300, height: 80)
        }
    }

    @Test("Tab and Shift-Tab leave the editor instead of inserting characters")
    func tabTraversesTheForm() {
        var text = "unchanged"
        var traversals: [Bool] = []
        let editor = BugReportTextEditor(
            text: Binding(get: { text }, set: { text = $0 }),
            placeholder: "Prompt",
            isFocused: false,
            onFocusChange: { _ in },
            onTraverse: { backwards in
                traversals.append(backwards)
                return true
            }
        )
        let coordinator = editor.makeCoordinator()
        let textView = BugReportEditorTextView()
        textView.coordinator = coordinator

        textView.insertTab(nil)
        textView.insertBacktab(nil)
        #expect(traversals == [false, true])
        #expect(text == "unchanged")
    }

    @Test("A boundary Tab is left for the surrounding window")
    func boundaryTabFallsThrough() {
        let editor = BugReportTextEditor(
            text: .constant(""),
            placeholder: "Prompt",
            isFocused: false,
            onFocusChange: { _ in },
            onTraverse: { _ in false }
        )
        let coordinator = editor.makeCoordinator()
        let textView = BugReportEditorTextView()
        textView.coordinator = coordinator

        textView.insertTab(nil)
        #expect(textView.string == "\t")
    }

    @Test("Tab makes the next editor the window's first responder")
    func tabMovesFirstResponder() async {
        let host = NSHostingView(rootView: FocusHarness())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()

        let editors = descendants(of: host, matching: BugReportEditorTextView.self)
            .sorted { $0.frameInWindow.maxY > $1.frameInWindow.maxY }
        #expect(editors.count == 2)
        guard editors.count == 2 else { return }

        window.makeFirstResponder(editors[0])
        editors[0].insertTab(nil)
        await Task.yield()
        await Task.yield()

        #expect(window.firstResponder === editors[1])
        window.close()
    }

    private func descendants<T: NSView>(of root: NSView, matching type: T.Type) -> [T] {
        root.subviews.flatMap { child -> [T] in
            let match = child as? T
            return (match.map { [$0] } ?? []) + descendants(of: child, matching: type)
        }
    }
}

private extension NSView {
    var frameInWindow: NSRect { convert(bounds, to: nil) }
}
