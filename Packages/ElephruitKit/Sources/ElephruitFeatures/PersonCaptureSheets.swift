import ElephruitCore
import ElephruitDesign
import SwiftUI

enum PersonNoteCategory: String, CaseIterable, Sendable, Hashable {
    case general
    case personal
    case work
    case idea

    var displayName: String { rawValue.capitalized }

    var symbolName: String {
        switch self {
        case .general: "note.text"
        case .personal: "heart.fill"
        case .work: "briefcase.fill"
        case .idea: "lightbulb.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .blue
        case .personal: Theme.Colors.personalDetail
        case .work: Theme.Colors.workDetail
        case .idea: .orange
        }
    }

    /// General needs no tag; the other choices become useful everywhere search and filters read tags.
    var tagSlug: String? { self == .general ? nil : rawValue }
}

struct PersonNoteDraft: Sendable, Equatable {
    var category: PersonNoteCategory = .general
    var title = ""
    var body = ""

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func resolvedTitle(personName: String) -> String {
        let explicit = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }

        let firstLine = body.split(whereSeparator: \.isNewline).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !firstLine.isEmpty { return String(firstLine.prefix(80)) }
        return "Note about \(personName)"
    }

    var cleanedBody: String { body.trimmingCharacters(in: .whitespacesAndNewlines) }
    var tagSlugs: [String] { category.tagSlug.map { [$0] } ?? [] }
}

struct PersonNoteSheet: View {
    let personName: String
    let onSave: (PersonNoteDraft) -> Void
    let onCancel: () -> Void

    @State private var draft = PersonNoteDraft()
    @FocusState private var focusedField: Field?

    private enum Field { case title, body }

    var body: some View {
        VStack(spacing: 0) {
            captureHeader
            Divider()

            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                categorySelector

                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text("Title")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)

                    TextField("", text: $draft.title)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .font(.system(.title3, weight: .medium))
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, Theme.Spacing.medium)
                        .frame(height: 42)
                        .background(fieldBackground)
                        .focused($focusedField, equals: .title)
                        .accessibilityLabel("Note title")
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text("Note")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)

                    TextEditor(text: $draft.body)
                        .font(Theme.Text.editorBody)
                        .scrollContentBackground(.hidden)
                        .padding(Theme.Spacing.small)
                        .frame(minHeight: 190)
                        .background(fieldBackground)
                        .overlay(alignment: .topLeading) {
                            if draft.body.isEmpty {
                                Text("What do you want to remember?")
                                    .font(Theme.Text.editorBody)
                                    .foregroundStyle(Theme.Colors.placeholderText)
                                    .padding(.horizontal, Theme.Spacing.large)
                                    .padding(.vertical, Theme.Spacing.medium)
                                    .allowsHitTesting(false)
                            }
                        }
                        .focused($focusedField, equals: .body)
                        .accessibilityLabel("Note")
                }
            }
            .padding(Theme.Spacing.section)

            Divider()
            actionBar
        }
        .frame(width: 620)
        .background(Theme.Colors.windowBackground)
        .onAppear { focusedField = .title }
    }

    private var captureHeader: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(draft.category.tint)
                .frame(width: 44, height: 44)
                .background(draft.category.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text("Add a note")
                    .font(Theme.Text.title)
                Text("About \(personName)")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.vertical, Theme.Spacing.large)
    }

    private var categorySelector: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Type")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)

            HStack(spacing: Theme.Spacing.small) {
                ForEach(PersonNoteCategory.allCases, id: \.self) { category in
                    Button {
                        withAnimation(Theme.Motion.appearance) { draft.category = category }
                    } label: {
                        Label(category.displayName, systemImage: category.symbolName)
                            .font(Theme.Text.chip)
                            .padding(.horizontal, Theme.Spacing.medium)
                            .frame(height: 30)
                            .foregroundStyle(draft.category == category ? category.tint : Theme.Colors.secondaryText)
                            .background(
                                Capsule().fill(
                                    draft.category == category ? category.tint.opacity(0.14) : Theme.Colors.subtleFill
                                )
                            )
                            .overlay {
                                Capsule().strokeBorder(
                                    draft.category == category ? category.tint.opacity(0.45) : Color.clear
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(draft.category == category ? .isSelected : [])
                }
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Label("Saved to \(personName)'s history", systemImage: "person.crop.circle.badge.checkmark")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)

            Spacer()

            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)

            Button("Save Note") { onSave(draft) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(draft.isEmpty)
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.vertical, Theme.Spacing.medium)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            .fill(Theme.Colors.contentBackground)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(Theme.Colors.separator)
            }
    }
}

struct PersonInteractionDraft: Sendable, Equatable {
    var kind: PersonInteractionKind = .inPerson
    var summary = ""
    var discussion = ""
    var followUps = ""
    var commitments = ""
    var occurredAt = Date()

    var cleanedSummary: String { summary.trimmingCharacters(in: .whitespacesAndNewlines) }
    var cleanedDiscussion: String { discussion.trimmingCharacters(in: .whitespacesAndNewlines) }
    var followUpItems: [String] { Self.items(in: followUps) }
    var commitmentItems: [String] { Self.items(in: commitments) }
    var isValid: Bool { !cleanedSummary.isEmpty }

    private static func items(in text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

struct LogInteractionSheet: View {
    let personName: String
    let onSave: (PersonInteractionDraft) -> Void
    let onCancel: () -> Void

    @Environment(\.services) private var services
    @State private var draft = PersonInteractionDraft()
    @FocusState private var focusedField: Field?

    private enum Field { case summary, discussion, followUps, commitments }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                    kindSelector
                    summaryAndDate
                    discussionField

                    HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                        actionList(
                            title: "Follow-ups",
                            detail: "Open tasks",
                            symbol: "checkmark.circle.fill",
                            tint: .blue,
                            text: $draft.followUps,
                            field: .followUps,
                            prompt: "One task per line"
                        )
                        actionList(
                            title: "Commitments",
                            detail: "Promises you made",
                            symbol: "hand.raised.fill",
                            tint: .orange,
                            text: $draft.commitments,
                            field: .commitments,
                            prompt: "One promise per line"
                        )
                    }
                }
                .padding(Theme.Spacing.section)
            }

            Divider()
            footer
        }
        .frame(width: 700)
        .frame(minHeight: 620)
        .background(Theme.Colors.windowBackground)
        .onAppear {
            draft.occurredAt = services?.dateProvider.now ?? Date()
            focusedField = .summary
        }
        .accessibilityIdentifier(AccessibilityID.People.interactionSheet)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: draft.kind.symbolName)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.purple)
                .frame(width: 44, height: 44)
                .background(Color.purple.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text("Log an interaction")
                    .font(Theme.Text.title)
                Text("With \(personName)")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.vertical, Theme.Spacing.large)
    }

    private var kindSelector: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("How did you connect?")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)

            HStack(spacing: Theme.Spacing.small) {
                ForEach(PersonInteractionKind.allCases, id: \.self) { kind in
                    Button {
                        withAnimation(Theme.Motion.appearance) { draft.kind = kind }
                    } label: {
                        Label(kind.displayName, systemImage: kind.symbolName)
                            .font(Theme.Text.chip)
                            .padding(.horizontal, Theme.Spacing.small)
                            .frame(height: 30)
                            .foregroundStyle(draft.kind == kind ? Color.purple : Theme.Colors.secondaryText)
                            .background(
                                Capsule().fill(
                                    draft.kind == kind ? Color.purple.opacity(0.14) : Theme.Colors.subtleFill
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(draft.kind == kind ? .isSelected : [])
                }
            }
        }
    }

    private var summaryAndDate: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text("What was it about?")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)

                TextField("", text: $draft.summary)
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.system(.title3, weight: .medium))
                    .padding(.horizontal, Theme.Spacing.medium)
                    .frame(height: 42)
                    .background(captureFieldBackground)
                    .focused($focusedField, equals: .summary)
                    .accessibilityLabel("Interaction summary")
            }

            DatePicker("When", selection: $draft.occurredAt)
                .datePickerStyle(.compact)
                .frame(width: 200)
        }
    }

    private var discussionField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text("What did you discuss?")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)

            captureTextEditor(
                text: $draft.discussion,
                field: .discussion,
                prompt: "Key points, context, decisions, or anything worth remembering…",
                minHeight: 130
            )
        }
    }

    private func actionList(
        title: String,
        detail: String,
        symbol: String,
        tint: Color,
        text: Binding<String>,
        field: Field,
        prompt: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(.callout, weight: .semibold))
                    Text(detail)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }

            captureTextEditor(text: text, field: field, prompt: prompt, minHeight: 90)
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.large))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.large)
                .strokeBorder(tint.opacity(0.18))
        }
    }

    private func captureTextEditor(
        text: Binding<String>,
        field: Field,
        prompt: String,
        minHeight: CGFloat
    ) -> some View {
        TextEditor(text: text)
            .font(Theme.Text.editorBody)
            .scrollContentBackground(.hidden)
            .padding(Theme.Spacing.small)
            .frame(minHeight: minHeight)
            .background(captureFieldBackground)
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(prompt)
                        .font(Theme.Text.editorBody)
                        .foregroundStyle(Theme.Colors.placeholderText)
                        .padding(.horizontal, Theme.Spacing.large)
                        .padding(.vertical, Theme.Spacing.medium)
                        .allowsHitTesting(false)
                }
            }
            .focused($focusedField, equals: field)
    }

    private var footer: some View {
        HStack {
            Text("Follow-ups become tasks; commitments appear as promises.")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)

            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Log Interaction") { onSave(draft) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.isValid)
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.vertical, Theme.Spacing.medium)
    }

    private var captureFieldBackground: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            .fill(Theme.Colors.contentBackground)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(Theme.Colors.separator)
            }
    }
}
