import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The quick-entry surface: one field, and a live account of what it understood.
///
/// ### Two pieces of state, and never one
/// ``rawText`` is what the user typed. The interpretation is a **separate value**, recomputed on
/// every keystroke and drawn beside the field. The field is never rewritten.
///
/// That is not a stylistic preference. A field that edits itself as you type destroys marked text
/// mid-composition, breaks undo, loses the insertion point, drops what dictation is still assembling,
/// and mangles a paste. There is no way to have a self-rewriting field *and* a field that behaves
/// like a text field, and the second is worth more.
///
/// So the tokens are shown *underneath*: "Starts tomorrow", "Reminder at 10:00", "→ Acme". They can
/// be dismissed individually, which edits the interpretation and still leaves the text alone.
struct TaskQuickEntryView: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    /// Exactly what was typed. Never normalised, never rewritten.
    @State private var rawText = ""

    /// What the parser made of it. Derived, never stored back into the field.
    @State private var draft = TaskEntryDraft()
    @State private var plan = TaskEntryPlan()

    /// Tokens the user has waved away. Their text stays; their meaning stops being applied.
    @State private var dismissedTokens: Set<String> = []

    @FocusState private var isFieldFocused: Bool

    /// Called with the created task, so the caller can select it.
    var onCreated: (Item) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            field
            interpretation
            Divider()
            footer
        }
        .padding(Theme.Spacing.large)
        .frame(width: 520)
        // One glass surface, not nested ones. The panel floats; everything inside it sits on the
        // panel, which is the whole distinction between a material and a decoration.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
        .onAppear { isFieldFocused = true }
        .onChange(of: rawText) { _, newValue in reparse(newValue) }
        .accessibilityIdentifier("tasks.quickEntry")
    }

    // MARK: - The field

    private var field: some View {
        TextField("What needs doing?", text: $rawText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(.title3))
            .lineLimit(1...4)
            .focused($isFieldFocused)
            .onSubmit { commit() }
            .onExitCommand { dismiss() }
            .accessibilityIdentifier("tasks.quickEntry.field")
            .accessibilityHint("Type a task. Dates, tags, people, and repeats are understood as you type.")
    }

    // MARK: - What it understood

    @ViewBuilder
    private var interpretation: some View {
        if rawText.isEmpty {
            hints
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                if !plan.title.isEmpty {
                    Text(plan.title)
                        .font(Theme.Text.rowTitle)
                        .foregroundStyle(Theme.Colors.primaryText)
                        .lineLimit(2)
                }

                if !activeTokens.isEmpty {
                    tokenRow
                }

                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.circle")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.warning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Every claim, as a chip that can be dismissed.
    private var tokenRow: some View {
        FlowLayout(spacing: Theme.Spacing.tight) {
            ForEach(activeTokens) { token in
                Button {
                    dismissedTokens.insert(token.id)
                    reparse(rawText)
                } label: {
                    HStack(spacing: Theme.Spacing.hairline) {
                        Image(systemName: token.kind.symbolName)
                            .font(.system(size: 9))
                        Text(tokenLabel(token))
                            .font(Theme.Text.chip)
                        Image(systemName: "xmark")
                            .font(.system(size: 7))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.vertical, Theme.Spacing.tight)
                    .background(Theme.Colors.subtleFill, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("\(token.kind.displayName): \(token.display). Click to ignore it — your text is untouched.")
                .accessibilityLabel("\(token.kind.displayName) \(token.display). Ignore.")
            }
        }
    }

    private func tokenLabel(_ token: TaskEntryToken) -> String {
        token.display.isEmpty ? token.kind.displayName : token.display
    }

    /// Tokens still in force: understood, and not waved away.
    private var activeTokens: [TaskEntryToken] {
        draft.tokens.filter { $0.kind != .unsupported && !dismissedTokens.contains($0.id) }
    }

    private var warnings: [String] {
        draft.unsupportedTokens.compactMap(\.explanation) + plan.warnings
    }

    private var hints: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            ForEach(TaskEntryParser.grammarHints.prefix(5), id: \.example) { hint in
                HStack(spacing: Theme.Spacing.small) {
                    Text(hint.example)
                        .font(Theme.Text.chip)
                        .padding(.horizontal, Theme.Spacing.small)
                        .padding(.vertical, 1)
                        .background(Theme.Colors.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
                    Text(hint.meaning)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Text(destinationSummary)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)

            Spacer()

            Button("Open Details") { commit(openingDetails: true) }
                .buttonStyle(.borderless)
                .disabled(plan.isEmpty)

            Button("Add") { commit() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(plan.isEmpty)
                .accessibilityIdentifier("tasks.quickEntry.add")
        }
    }

    private var destinationSummary: String {
        if let title = plan.destinationTitle { return "→ \(title)" }
        if let first = plan.destinationToCreate.first { return "→ \(first) (new)" }
        return "→ Inbox"
    }

    // MARK: - Behaviour

    /// Reparses and re-resolves. Pure with respect to the field: `rawText` is read, never written.
    private func reparse(_ text: String) {
        draft = TaskEntryParser.parse(text)
        applyDismissals(to: &draft)
        plan = services?.taskEntry.plan(draft) ?? TaskEntryPlan(title: draft.title, notes: draft.notes)
    }

    /// Removes the meaning of a dismissed token while leaving its text where it is.
    ///
    /// The title is deliberately **not** rebuilt to include the words back: the user asked for the
    /// claim to be ignored, not for the sentence to change shape underneath them.
    private func applyDismissals(to draft: inout TaskEntryDraft) {
        for token in draft.tokens where dismissedTokens.contains(token.id) {
            switch token.kind {
            case .startDate: draft.startDate = nil
            case .deadline: draft.deadline = nil
            case .reminder: draft.reminder = nil
            case .repeatRule: draft.recurrence = nil
            case .destination: draft.destinationPath = []
            case .tag: draft.tagSlugs.removeAll { $0 == token.display.dropFirst() }
            case .person: draft.personHints.removeAll { $0 == token.display }
            case .waiting: draft.waitingForHint = nil
            case .someday: draft.isSomeday = false
            case .flag: draft.isFlagged = false
            case .priority: draft.priority = nil
            case .unsupported: break
            }
        }
    }

    private func commit(openingDetails: Bool = false) {
        guard let services, !plan.isEmpty else { return }

        services.perform {
            let task = try services.taskEntry.commit(plan)
            services.noteChange(to: task)
            onCreated(task)
        }

        if openingDetails {
            dismiss()
        } else {
            // Cleared rather than dismissed, so a run of captures is a run of Returns. The panel
            // stays where it is and the field keeps focus.
            rawText = ""
            draft = TaskEntryDraft()
            plan = TaskEntryPlan()
            dismissedTokens = []
            isFieldFocused = true
        }
    }
}

/// Lays chips out in rows, wrapping when they run out of width.
///
/// A `Layout` rather than nested stacks because the number of tokens is unknown and changes on every
/// keystroke: an `HStack` would push the last one off the edge, and a `ViewThatFits` would need every
/// arrangement enumerated in advance.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rows = 1
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        var total: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                total += rowHeight + spacing
                rows += 1
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        _ = rows
        return CGSize(width: width == .infinity ? x : width, height: total + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
