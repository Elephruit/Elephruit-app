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

    @State private var composition = QuickJotComposition()
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
                text: $composition.titleText,
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

    /// Hands what was composed to ``CaptureService``.
    ///
    /// The sheet deliberately owns none of the writing. The same path has to work from an App Intent,
    /// the Services menu, and a global hotkey — none of which can construct a view — so turning a
    /// capture into an item lives outside the UI entirely.
    ///
    /// The vocabulary is fetched here and used for *both* the flush and the merge, so the two cannot
    /// disagree about where a name ends. Two lookups would be two opinions — the kind that agree for
    /// a year and then quietly do not.
    private func save() {
        guard let services, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let vocabulary = (try? services.capture.vocabulary()) ?? .empty
        composition.flush(knowing: vocabulary)

        var captured: UUID?
        let failed = !services.perform {
            captured = try services.captureDraft(composition.captured(knowing: vocabulary))?.id
        }

        // Nothing captured is not a failure — an empty field simply has nothing to save, and
        // dismissing on it would throw away whatever punctuation the user had started.
        guard !failed, let captured else { return }

        onCapture(captured)
        composition = QuickJotComposition()
        dismiss()
    }
}

#Preview("Quick Jot") {
    QuickCaptureView()
        .appServices(AppServices.inMemory())
}
