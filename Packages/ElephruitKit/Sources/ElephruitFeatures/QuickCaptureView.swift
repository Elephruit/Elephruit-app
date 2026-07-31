import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// Quick Capture — journey J1.
///
/// The whole design goal is *under four seconds, no mouse, no decision about where it goes*. So:
/// the field is focused on appearance, `⌘↩` saves, `Escape` cancels, and there is exactly one
/// unavoidable decision — what to type.
///
/// The interpretation line below the field is the important part. It shows what the grammar
/// understood *before* committing, so the sigils are learnable by using them rather than by reading
/// documentation, and a mistyped `!tomorow` is visible rather than silently becoming part of a title.
public struct QuickCaptureView: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var isSaving = false
    @FocusState private var isFieldFocused: Bool

    /// Called with the new item's identifier, so the caller can select what was just captured.
    private let onCapture: (UUID) -> Void

    public init(onCapture: @escaping (UUID) -> Void = { _ in }) {
        self.onCapture = onCapture
    }

    private var draft: CaptureDraft {
        CaptureParser.parse(text)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            header

            TextEditor(text: $text)
                .font(Theme.Text.editorBody)
                .scrollContentBackground(.hidden)
                .padding(Theme.Spacing.small)
                .frame(minHeight: 84, maxHeight: 160)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .fill(Theme.Colors.contentBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .strokeBorder(isFieldFocused ? Theme.Colors.selection : Theme.Colors.separator)
                )
                .focused($isFieldFocused)
                .accessibilityIdentifier(AccessibilityID.QuickCapture.textField)
                .accessibilityLabel("What would you like to capture?")

            interpretation

            Divider()

            footer
        }
        .padding(Theme.Spacing.large)
        .frame(width: 520)
        .background(.regularMaterial)
        .onAppear { isFieldFocused = true }
        .accessibilityIdentifier(AccessibilityID.QuickCapture.root)
    }

    private var header: some View {
        HStack {
            Label("Quick Jot", systemImage: "square.and.pencil")
                .font(.system(.headline, design: .default, weight: .medium))
            Spacer()
            KeyHint("⌘", "↩")
        }
    }

    /// What the parser made of the text. Empty state shows the grammar instead.
    @ViewBuilder
    private var interpretation: some View {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(spacing: Theme.Spacing.medium) {
                ForEach(CaptureParser.grammarHints, id: \.sigil) { hint in
                    HStack(spacing: Theme.Spacing.hairline) {
                        Text(hint.sigil)
                            .font(.system(.caption, design: .monospaced, weight: .semibold))
                            .foregroundStyle(Theme.Colors.selection)
                        Text(hint.meaning)
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }
            }
            .accessibilityIdentifier(AccessibilityID.QuickCapture.interpretation)
            .accessibilityLabel("Type hash for a tag, greater-than for a project, at for a person, exclamation mark for a due date")
        } else {
            interpretationSummary
        }
    }

    private var interpretationSummary: some View {
        let parsed = draft

        return HStack(spacing: Theme.Spacing.small) {
            Label(parsed.kind.displayName, systemImage: parsed.kind.symbolName)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)

            if !parsed.tagSlugs.isEmpty {
                TagChipRow(slugs: parsed.tagSlugs, limit: 3)
            }

            if let project = parsed.projectHint {
                Label(project, systemImage: "square.stack.3d.up")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(resolvedProject(named: project) == nil ? Theme.Colors.unresolvedLink : Theme.Colors.secondaryText)
                    .help(resolvedProject(named: project) == nil ? "No project with this name — the capture will go to the Inbox" : project)
            }

            if let due = parsed.dueInterpretation {
                Label(due.summary, systemImage: "calendar")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            // Deliberately a different glyph from the deadline. The two dates mean opposite things
            // and a shared icon would be the interface conflating what the grammar separates.
            if let follow = parsed.followDate {
                Label(follow.summary, systemImage: "arrow.trianglehead.counterclockwise")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            if let priority = parsed.priority, priority != .normal {
                Label(priority.displayName, systemImage: "flag")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            if parsed.url != nil {
                Image(systemName: "link")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            Spacer()
        }
        .lineLimit(1)
        .accessibilityIdentifier(AccessibilityID.QuickCapture.interpretation)
        .accessibilityLabel(interpretationDescription(parsed))
    }

    private func interpretationDescription(_ parsed: CaptureDraft) -> String {
        var parts = ["Will create a \(parsed.kind.displayName.lowercased())"]
        if !parsed.tagSlugs.isEmpty { parts.append("tagged \(parsed.tagSlugs.joined(separator: ", "))") }
        if let project = parsed.projectHint { parts.append("in \(project)") }
        if let due = parsed.dueInterpretation { parts.append("due \(due.summary)") }
        if let follow = parsed.followDate { parts.append("coming back \(follow.summary)") }
        if let priority = parsed.priority, priority != .normal {
            parts.append("\(priority.displayName.lowercased()) priority")
        }
        return parts.joined(separator: ", ")
    }

    private var footer: some View {
        HStack {
            Text("Saved to Inbox unless a project is named.")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)

            Spacer()

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(AccessibilityID.QuickCapture.cancelButton)

            Button("Save") { save() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(draft.isEmpty || isSaving)
                .accessibilityIdentifier(AccessibilityID.QuickCapture.saveButton)
        }
    }

    // MARK: - Saving

    /// Hands the draft to ``CaptureService``.
    ///
    /// The panel deliberately owns none of this. The same call has to work from an App Intent, the
    /// Services menu, and eventually a global hotkey — none of which can construct a view — so the
    /// path from typed text to stored item lives outside the UI entirely.
    private func save() {
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

    /// Only for the live interpretation line — resolution for the *save* happens in the service.
    private func resolvedProject(named hint: String) -> Item? {
        guard let services else { return nil }
        return try? services.capture.resolveContainer(named: hint)
    }
}

#Preview("Quick Jot") {
    QuickCaptureView()
        .appServices(AppServices.inMemory())
}
