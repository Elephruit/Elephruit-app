import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// Quick Jot as a sheet — journey J1, for when Elephruit is already what you are looking at.
///
/// The whole design goal is *under four seconds, no mouse, no decision about where it goes*. So:
/// the field is focused on appearance, `⌘↩` saves, `Escape` cancels, and there is exactly one
/// unavoidable decision — what to type.
///
/// Everything between the title and the buttons is ``CaptureComposer``, shared with the floating
/// panel, so the two doors cannot drift apart. What is left here is only what a sheet does
/// differently from a window: it dismisses, and it hands the new item's identifier back to whoever
/// presented it so the app can select what was just captured.
public struct QuickCaptureView: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var isSaving = false

    /// Called with the new item's identifier, so the caller can select what was just captured.
    private let onCapture: (UUID) -> Void

    public init(onCapture: @escaping (UUID) -> Void = { _ in }) {
        self.onCapture = onCapture
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            CaptureComposerHeader()

            CaptureComposer(
                text: $text,
                isSaving: isSaving,
                onSave: { save() },
                onCancel: { dismiss() }
            )
        }
        .padding(Theme.Spacing.large)
        .frame(width: 560)
        .background(.regularMaterial)
        .accessibilityIdentifier(AccessibilityID.QuickCapture.root)
    }

    // MARK: - Saving

    /// Hands the draft to ``CaptureService``.
    ///
    /// The panel deliberately owns none of this. The same call has to work from an App Intent, the
    /// Services menu, and a global hotkey — none of which can construct a view — so the path from
    /// typed text to stored item lives outside the UI entirely.
    private func save() {
        let draft = CaptureParser.parse(text)
        guard let services, !draft.isEmpty, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let didSave = services.perform {
            let created = try services.capture.capture(draft)
            services.noteChange(to: created)
            onCapture(created.id)
        }

        if didSave {
            text = ""
            dismiss()
        }
    }
}

#Preview("Quick Jot") {
    QuickCaptureView()
        .appServices(AppServices.inMemory())
}
