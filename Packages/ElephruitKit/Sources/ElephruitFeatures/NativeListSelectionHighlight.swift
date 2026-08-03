import AppKit
import SwiftUI

/// Prevents AppKit from painting the native accent selection behind an expandable SwiftUI row.
///
/// A binding can reject selection state, but `NSTableView` may still draw its internal selection
/// immediately after a click. This representable lives inside the row, walks to the table that owns
/// it, and disables that presentation at the AppKit layer. The list remains selectable and exposes
/// its state to SwiftUI; the app draws its own quiet compact-row selection instead.
struct NativeListSelectionHighlightSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> NativeListSelectionHighlightSuppressorView {
        NativeListSelectionHighlightSuppressorView()
    }

    func updateNSView(_ nsView: NativeListSelectionHighlightSuppressorView, context: Context) {
        nsView.suppressSelectionHighlight()
    }
}

final class NativeListSelectionHighlightSuppressorView: NSView {
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        suppressSelectionHighlight()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        suppressSelectionHighlight()
    }

    func suppressSelectionHighlight() {
        var ancestor = superview
        while let view = ancestor {
            if let table = view as? NSTableView {
                table.selectionHighlightStyle = .none
                return
            }
            ancestor = view.superview
        }
    }
}

extension View {
    /// Use on rows that can become editors. Compact selection must be drawn with `listRowBackground`.
    func nativeListSelectionHighlightDisabled() -> some View {
        background(NativeListSelectionHighlightSuppressor())
    }
}
