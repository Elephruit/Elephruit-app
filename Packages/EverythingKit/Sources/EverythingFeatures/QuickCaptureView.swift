import EverythingCore
import EverythingDesign
import EverythingModel
import EverythingPersistence
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
            Label("Quick Capture", systemImage: "square.and.pencil")
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

            if let due = parsed.dueDate {
                Label(due.summary, systemImage: "calendar")
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
        if let due = parsed.dueDate { parts.append("due \(due.summary)") }
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

    private func save() {
        guard let services, !draft.isEmpty, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let parsed = draft

        var itemDraft = ItemDraft(
            kind: parsed.kind,
            title: parsed.title,
            body: parsed.body,
            tagSlugs: parsed.tagSlugs,
            source: .quickCapture,
            url: parsed.url
        )

        // An unresolvable project hint is not an error: the item lands in the Inbox, which is
        // exactly where an unfiled capture belongs.
        if let hint = parsed.projectHint, let project = resolvedProject(named: hint) {
            itemDraft.parentID = project.id
        }

        if let expression = parsed.dueDate, parsed.kind.supportedFields.contains(.dueDate) {
            itemDraft.dueAt = expression.resolve(using: services.dateProvider)
        }

        let didSave = services.perform {
            let created = try services.items.create(itemDraft)

            // People named with `@` become links, and are created if they do not exist yet, so the
            // graph reflects what was written without a second step.
            try linkPeople(named: parsed.personHints, from: created, services: services)

            services.noteChange(to: created)
            onCapture(created.id)
        }

        if didSave {
            text = ""
            dismiss()
        }
    }

    private func linkPeople(named names: [String], from item: Item, services: AppServices) throws(AppError) {
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let person = try resolveOrCreatePerson(named: trimmed, services: services)
            services.context.insert(
                ItemLink(kind: .mentions, source: item, target: person, createdAt: services.dateProvider.now)
            )
        }
    }

    private func resolveOrCreatePerson(named name: String, services: AppServices) throws(AppError) -> Item {
        var query = ItemQuery()
        query.kinds = [.person]

        let existing = try services.items.items(matching: query)
        let folded = TextNormalizer.foldedForMatching(name)

        if let match = existing.first(where: { TextNormalizer.foldedForMatching($0.title) == folded }) {
            return match
        }

        return try services.items.create(
            ItemDraft(kind: .person, title: name, source: ItemSource(kind: .quickCapture, identifier: "mention"))
        )
    }

    private func resolvedProject(named hint: String) -> Item? {
        guard let services else { return nil }

        var query = ItemQuery()
        query.kinds = [.project, .area, .goal]

        let candidates = (try? services.items.items(matching: query)) ?? []
        let folded = TextNormalizer.foldedForMatching(hint)

        // Exact match first, then a prefix, so `>Q3` finds "Q3 Launch" without guessing wildly.
        return candidates.first { TextNormalizer.foldedForMatching($0.title) == folded }
            ?? candidates.first { TextNormalizer.foldedForMatching($0.title).hasPrefix(folded) }
    }
}

#Preview("Quick Capture") {
    QuickCaptureView()
        .appServices(AppServices.inMemory())
}
