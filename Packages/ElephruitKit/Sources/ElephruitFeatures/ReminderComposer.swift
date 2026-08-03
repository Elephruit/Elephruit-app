import AppKit
import ElephruitCore
import ElephruitDesign
import SwiftUI

/// A complete reminder, composed in place without touching the store until it is ready.
///
/// The title, notes and metadata filters are AppKit text views because this card promises an exact
/// Tab path. SwiftUI's key-view order cannot express that path once stops live in popovers, and an
/// `NSTextView` would otherwise insert a tab into Notes instead of moving on.
struct ReminderComposer: View {
    @Environment(\.services) private var services

    @Binding var draft: ReminderComposerDraft
    var onQuickCommit: () -> Void
    var onCommitAndClose: () -> Void
    var onCancel: () -> Void

    @State private var whenQuery = ""
    @State private var deadlineQuery = ""
    @State private var tagQuery = ""
    @State private var peopleQuery = ""
    @State private var projectQuery = ""
    @State private var availableTags: [String] = []
    @State private var availablePeople: [String] = []
    @State private var availableProjects: [String] = []
    @State private var popupField: ReminderComposerField?
    @State private var titleCaret = 0
    @State private var notesCaret = 0
    @State private var inlineSuggestionSelection = 0
    @State private var metadataSuggestionSelection = 0
    @State private var metadataSuggestionWasNavigated = false
    @State private var dateNavigation = ReminderDateNavigationState()
    @StateObject private var focusRouter = ReminderComposerFocusRouter()

    private var activeField: ReminderComposerField { focusRouter.activeField }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                titleLine
                notes
                if !inlineSuggestions.isEmpty {
                    inlineSuggestionList
                }
                checklist
                metadataSummary
            }
            .padding(Theme.Spacing.medium)
            .animation(.snappy(duration: 0.18), value: activeField == .checklist)

            Divider()
            actionRow
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Theme.Colors.contentBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .stroke(Theme.Colors.separator, lineWidth: 1)
        }
        .shadow(color: Theme.Colors.shadow.opacity(0.14), radius: 8, y: 2)
        .background {
            ReminderComposerKeyboardMonitor(router: focusRouter)
            .frame(width: 0, height: 0)
        }
        .onAppear {
            focusRouter.onTab = { reverse in
                move(from: focusRouter.activeField, reverse: reverse)
            }
            focusRouter.onTextInput = { characters in
                guard focusRouter.activeField == .checklist, !draft.hasChecklistContent else {
                    return false
                }
                draft.pendingStep.append(contentsOf: characters)
                return true
            }
            refreshLibraryFacts()
            Task { @MainActor in
                await Task.yield()
                activate(.title)
            }
        }
        .task(id: services?.changeToken) {
            refreshLibraryFacts()
        }
        .onChange(of: inlineCompletion) { _, _ in inlineSuggestionSelection = 0 }
        .onChange(of: whenQuery) { _, _ in dateNavigation.reset() }
        .onChange(of: deadlineQuery) { _, _ in dateNavigation.reset() }
        .onChange(of: tagQuery) { _, _ in resetMetadataSuggestion() }
        .onChange(of: peopleQuery) { _, _ in resetMetadataSuggestion() }
        .onChange(of: projectQuery) { _, _ in resetMetadataSuggestion() }
        .onDisappear {
            focusRouter.onTab = nil
            focusRouter.onTextInput = nil
        }
        .accessibilityIdentifier("tasks.reminderComposer")
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Image(systemName: "circle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Colors.tertiaryText)

            ReminderPlainTextEditor(
                text: $draft.title,
                placeholder: "New Reminder",
                role: .title,
                onTab: moveFromTitle,
                onReturn: quickCommit,
                onCommandReturn: commitAndClose,
                onEscape: onCancel,
                field: .title,
                focusRouter: focusRouter,
                onMove: moveInlineSuggestion,
                onAcceptSuggestion: acceptInlineSuggestion,
                onSelectionChange: { titleCaret = $0 },
                onFocus: { activate(.title) }
            )
            .frame(height: 26)
            .accessibilityIdentifier("tasks.reminderComposer.title")
        }
    }

    private var notes: some View {
        ReminderPlainTextEditor(
            text: $draft.notes,
            placeholder: "Notes",
            role: .notes,
            onTab: { reverse in move(from: .notes, reverse: reverse) },
            onReturn: {},
            onCommandReturn: commitAndClose,
            onEscape: onCancel,
            field: .notes,
            focusRouter: focusRouter,
            onMove: moveInlineSuggestion,
            onAcceptSuggestion: acceptInlineSuggestion,
            onSelectionChange: { notesCaret = $0 },
            onFocus: { activate(.notes) }
        )
        .frame(minHeight: 42, maxHeight: 88)
        .padding(.leading, 21)
        .accessibilityIdentifier("tasks.reminderComposer.notes")
    }

    private var inlineCompletion: CaptureCompletion? {
        let completion: CaptureCompletion?
        switch activeField {
        case .title:
            completion = CaptureCompletion.active(in: draft.title, caretAt: titleCaret)
        case .notes:
            completion = CaptureCompletion.active(in: draft.notes, caretAt: notesCaret)
        case .when, .tags, .people, .checklist, .deadline, .project:
            completion = nil
        }

        guard let completion else { return nil }
        return switch completion.trigger {
        case .tag, .person, .project: completion
        case .bang, .dueDate, .followDate: nil
        }
    }

    private var inlineSuggestions: [String] {
        guard let inlineCompletion else { return [] }
        switch inlineCompletion.trigger {
        case .tag:
            let matches = matchingNames(inlineCompletion.query, in: availableTags)
            if !matches.isEmpty { return matches }
            let slug = TextNormalizer.slug(inlineCompletion.query)
            return slug.isEmpty ? [] : [slug]
        case .person:
            return matchingNames(inlineCompletion.query, in: availablePeople)
        case .project:
            return matchingNames(inlineCompletion.query, in: availableProjects)
        case .bang, .dueDate, .followDate:
            return []
        }
    }

    private var inlineSuggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(inlineSuggestions.enumerated()), id: \.offset) { index, value in
                HStack(spacing: Theme.Spacing.small) {
                    Text(inlineCompletion?.trigger.prefix ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.CaptureToken.accent)
                    Text(value)
                        .font(Theme.Text.metadata)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, Theme.Spacing.small)
                .background(
                    index == inlineSuggestionSelection ? Theme.Colors.selectionFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    inlineSuggestionSelection = index
                    _ = acceptInlineSuggestion()
                }
                .onHover { hovering in
                    if hovering { inlineSuggestionSelection = index }
                }
            }
        }
        .padding(.leading, 21)
        .accessibilityLabel(
            "\(inlineSuggestions.count) suggestions. Use the arrow keys, then Tab or Return to accept."
        )
    }

    @ViewBuilder
    private var metadataSummary: some View {
        if !draft.tagSlugs.isEmpty
            || !draft.personNames.isEmpty
            || draft.startAt != nil
            || draft.dueAt != nil
            || draft.isSomeday {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                if !draft.tagSlugs.isEmpty {
                    FlowLayout(spacing: Theme.Spacing.tight, lineSpacing: Theme.Spacing.tight) {
                        ForEach(draft.tagSlugs, id: \.self) { slug in
                            CaptureChip(
                                symbolName: "number",
                                label: TextNormalizer.slugComponents(slug).last ?? slug,
                                removalDescription: "Remove the tag \(slug)"
                            ) {
                                draft.tagSlugs.removeAll { $0 == slug }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("tasks.reminderComposer.tagSummary")
                }

                if !draft.personNames.isEmpty {
                    FlowLayout(spacing: Theme.Spacing.tight, lineSpacing: Theme.Spacing.tight) {
                        ForEach(draft.personNames, id: \.self) { name in
                            CaptureChip(
                                symbolName: "person",
                                label: name,
                                removalDescription: "Remove \(name) from this reminder"
                            ) {
                                draft.personNames.removeAll { $0 == name }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("tasks.reminderComposer.peopleSummary")
                }

                if draft.startAt != nil || draft.dueAt != nil || draft.isSomeday {
                    FlowLayout(spacing: Theme.Spacing.tight, lineSpacing: Theme.Spacing.tight) {
                        if let start = draft.startAt {
                            CaptureChip(
                                symbolName: "calendar",
                                label: "When: \(summaryDate(start))",
                                removalDescription: "Clear when this reminder starts"
                            ) {
                                draft.startAt = nil
                                draft.isSomeday = false
                            }
                        } else if draft.isSomeday {
                            CaptureChip(
                                symbolName: "archivebox",
                                label: "Someday",
                                removalDescription: "Clear Someday"
                            ) {
                                draft.isSomeday = false
                            }
                        }

                        if let deadline = draft.dueAt {
                            CaptureChip(
                                symbolName: "flag",
                                label: "Deadline: \(summaryDate(deadline))",
                                removalDescription: "Clear this reminder's deadline"
                            ) {
                                draft.dueAt = nil
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("tasks.reminderComposer.dateSummary")
                }
            }
            .padding(.leading, 21)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    @ViewBuilder
    private var checklist: some View {
        if draft.hasChecklistContent || activeField == .checklist {
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                ForEach(draft.checklist) { step in
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: step.isCompleted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(Theme.Colors.secondaryText)
                        Text(step.title)
                            .font(Theme.Text.rowSubtitle)
                        Spacer(minLength: 0)
                        Button {
                            draft.checklist.removeAll { $0.id == step.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        .help("Remove checklist item")
                    }
                    .frame(minHeight: Theme.Size.rowHeight)
                }

                if activeField == .checklist {
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: "circle")
                            .foregroundStyle(Theme.CaptureToken.accent)

                        ReminderPlainTextEditor(
                            text: $draft.pendingStep,
                            placeholder: "Add a checklist item",
                            role: .body,
                            onTab: { reverse in
                                if !reverse { commitChecklistRow() }
                                move(from: .checklist, reverse: reverse)
                            },
                            onReturn: {
                                commitChecklistRow()
                                activate(.checklist)
                            },
                            onCommandReturn: commitAndClose,
                            onEscape: onCancel,
                            field: .checklist,
                            focusRouter: focusRouter,
                            onDeleteBackwardWhenEmpty: removeLastChecklistItem,
                            onFocus: { activate(.checklist) }
                        )
                        .frame(height: 24)
                        .accessibilityIdentifier("tasks.reminderComposer.checklistField")
                    }
                    .padding(.horizontal, Theme.Spacing.small)
                    .frame(minHeight: Theme.Size.rowHeight)
                    .background(
                        Theme.Colors.selectionFill,
                        in: RoundedRectangle(
                            cornerRadius: Theme.Radius.small,
                            style: .continuous
                        )
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.leading, 21)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private var actionRow: some View {
        HStack(spacing: Theme.Spacing.medium) {
            projectControl
            Spacer(minLength: 0)
            whenControl
            tagsControl
            peopleControl
            checklistControl
            deadlineControl
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .background(Theme.Colors.subtleFill)
    }

    private var whenControl: some View {
        HStack(spacing: 0) {
            if activeField == .when {
                metadataQueryEditor(
                    text: $whenQuery,
                    placeholder: "When",
                    symbol: "calendar",
                    field: .when,
                    onTab: { reverse in
                        commitWhenQuery()
                        move(from: .when, reverse: reverse)
                    },
                    onReturn: {
                        commitWhenQuery()
                        activate(.tags)
                    },
                    escapeTo: .project
                )
            } else {
                actionButton(
                    title: draft.isSomeday ? "Someday" : draft.startAt.map(shortDate) ?? "When",
                    symbol: "calendar",
                    isActive: draft.startAt != nil || draft.isSomeday
                ) {
                    activate(.when)
                }
            }
        }
        .background {
            ReminderNativePopover(isPresented: popupField == .when) {
                reminderDatePopover(
                    field: .when,
                    selected: draft.startAt,
                    allowsSomeday: true,
                    onPick: { date in
                        draft.startAt = date
                        draft.isSomeday = false
                        activate(.tags)
                    }
                )
            }
        }
    }

    private var tagsControl: some View {
        HStack(spacing: 0) {
            if activeField == .tags {
                metadataQueryEditor(
                    text: $tagQuery,
                    placeholder: "Tags",
                    symbol: "tag",
                    field: .tags,
                    onTab: { reverse in
                        move(from: .tags, reverse: reverse)
                    },
                    onReturn: toggleFirstMatchingTag,
                    escapeTo: .when
                )
            } else {
                actionButton(
                    title: draft.tagSlugs.isEmpty ? "Tags" : draft.tagSlugs.joined(separator: ", "),
                    symbol: "tag",
                    isActive: !draft.tagSlugs.isEmpty
                ) {
                    activate(.tags)
                }
            }
        }
        .background {
            ReminderNativePopover(isPresented: popupField == .tags) {
                reminderTagPopover
            }
        }
    }

    private var peopleControl: some View {
        HStack(spacing: 0) {
            if activeField == .people {
                metadataQueryEditor(
                    text: $peopleQuery,
                    placeholder: "Who?",
                    symbol: "person",
                    field: .people,
                    onTab: { reverse in move(from: .people, reverse: reverse) },
                    onReturn: toggleFirstMatchingPerson,
                    escapeTo: .tags
                )
            } else {
                actionButton(
                    title: draft.personNames.isEmpty
                        ? "People"
                        : draft.personNames.joined(separator: ", "),
                    symbol: "person",
                    isActive: !draft.personNames.isEmpty
                ) {
                    activate(.people)
                }
            }
        }
        .background {
            ReminderNativePopover(isPresented: popupField == .people) {
                reminderPeoplePopover
            }
        }
    }

    private var projectControl: some View {
        HStack(spacing: 0) {
            if activeField == .project {
                metadataQueryEditor(
                    text: $projectQuery,
                    placeholder: "Which project?",
                    symbol: "square.stack.3d.up",
                    field: .project,
                    width: 160,
                    onTab: { reverse in move(from: .project, reverse: reverse) },
                    onReturn: chooseFirstMatchingProject,
                    escapeTo: .notes
                )
            } else {
                Button { activate(.project) } label: {
                    Label(
                        draft.projectTitle ?? "Project",
                        systemImage: draft.projectTitle == nil
                            ? "square.stack.3d.up"
                            : "square.stack.3d.up.fill"
                    )
                    .font(Theme.Text.metadata)
                    .foregroundStyle(
                        draft.projectTitle == nil
                            ? Theme.Colors.secondaryText
                            : Theme.CaptureToken.accent
                    )
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(draft.projectTitle.map { "Project: \($0)" } ?? "Associate with a project")
            }
        }
        .background {
            ReminderNativePopover(isPresented: popupField == .project) {
                reminderProjectPopover
            }
        }
    }

    private var checklistControl: some View {
        actionButton(
            title: draft.checklist.isEmpty ? "Checklist" : "\(draft.checklist.count) items",
            symbol: "checklist",
            isActive: !draft.checklist.isEmpty,
            isFocused: activeField == .checklist && !draft.hasChecklistContent
        ) {
            activate(.checklist)
        }
    }

    private var deadlineControl: some View {
        HStack(spacing: 0) {
            if activeField == .deadline {
                metadataQueryEditor(
                    text: $deadlineQuery,
                    placeholder: "Deadline",
                    symbol: "flag",
                    field: .deadline,
                    onTab: { reverse in
                        commitDeadlineQuery()
                        move(from: .deadline, reverse: reverse)
                    },
                    onReturn: {
                        commitDeadlineQuery()
                        activate(.title)
                    },
                    escapeTo: .checklist
                )
            } else {
                actionButton(
                    title: draft.dueAt.map(shortDate) ?? "Deadline",
                    symbol: "flag",
                    isActive: draft.dueAt != nil
                ) {
                    activate(.deadline)
                }
            }
        }
        .background {
            ReminderNativePopover(isPresented: popupField == .deadline) {
                reminderDatePopover(
                    field: .deadline,
                    selected: draft.dueAt,
                    allowsSomeday: false,
                    onPick: { date in
                        draft.dueAt = date
                        activate(.title)
                    }
                )
            }
        }
    }

    private func metadataQueryEditor(
        text: Binding<String>,
        placeholder: String,
        symbol: String,
        field: ReminderComposerField,
        width: CGFloat = 132,
        onTab: @escaping (Bool) -> Void,
        onReturn: @escaping () -> Void,
        escapeTo: ReminderComposerField
    ) -> some View {
        HStack(spacing: Theme.Spacing.tight) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Theme.CaptureToken.accent)

            ReminderPlainTextEditor(
                text: text,
                placeholder: placeholder,
                role: .body,
                onTab: onTab,
                onReturn: onReturn,
                onCommandReturn: commitAndClose,
                onEscape: { popupField = nil; activate(escapeTo) },
                field: field,
                focusRouter: focusRouter,
                onMove: { moveMetadataSuggestion($0, for: field) },
                onHorizontalMove: { moveDateHorizontally($0, for: field) },
                onAcceptSuggestion: { acceptMetadataSuggestion(for: field) },
                onFocus: { activate(field) }
            )
        }
        .frame(width: width, height: 24)
        .padding(.horizontal, Theme.Spacing.small)
        .background(Theme.Colors.selectionFill, in: Capsule())
    }

    private func actionButton(
        title: String,
        symbol: String,
        isActive: Bool,
        isFocused: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: activeSymbol(symbol, isActive: isActive))
                .font(.system(size: 13))
                .foregroundStyle(
                    isActive || isFocused ? Theme.CaptureToken.accent : Theme.Colors.tertiaryText
                )
                .padding(.horizontal, isFocused ? Theme.Spacing.small : 0)
                .frame(width: isFocused ? 36 : 22, height: 24)
                .background(isFocused ? Theme.Colors.selectionFill : .clear, in: Capsule())
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func activeSymbol(_ symbol: String, isActive: Bool) -> String {
        guard isActive else { return symbol }
        return switch symbol {
        case "checklist": "checklist.checked"
        case "calendar": "calendar.badge.checkmark"
        default: symbol + ".fill"
        }
    }

    private var reminderTagPopover: some View {
        VStack(alignment: .leading, spacing: 1) {
            if matchingTags.isEmpty {
                Button {
                    addTag(tagQuery)
                } label: {
                    Label("Create \(TextNormalizer.slug(tagQuery))", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(TextNormalizer.slug(tagQuery).isEmpty)
            } else {
                ForEach(Array(matchingTags.enumerated()), id: \.offset) { index, slug in
                    Button {
                        metadataSuggestionSelection = index
                        toggleTag(slug)
                    } label: {
                        Label(slug, systemImage: draft.tagSlugs.contains(slug) ? "checkmark" : "tag")
                            .padding(.vertical, 3)
                            .padding(.horizontal, Theme.Spacing.tight)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        index == metadataSuggestionSelection
                            ? Theme.Colors.selectionFill
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    )
                    .onHover { hovering in
                        if hovering { metadataSuggestionSelection = index }
                    }
                }
            }
        }
        .padding(Theme.Spacing.small)
        .frame(width: 220)
    }

    private var reminderPeoplePopover: some View {
        VStack(alignment: .leading, spacing: 1) {
            if matchingPeople.isEmpty {
                Text(availablePeople.isEmpty ? "Nobody here yet" : "Nothing by that name")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .padding(Theme.Spacing.small)
            } else {
                ForEach(Array(matchingPeople.enumerated()), id: \.offset) { index, name in
                    Button {
                        metadataSuggestionSelection = index
                        togglePerson(name)
                    } label: {
                        Label(
                            name,
                            systemImage: draft.personNames.contains(name) ? "checkmark" : "person"
                        )
                        .padding(.vertical, 3)
                        .padding(.horizontal, Theme.Spacing.tight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        index == metadataSuggestionSelection
                            ? Theme.Colors.selectionFill
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    )
                    .onHover { hovering in
                        if hovering { metadataSuggestionSelection = index }
                    }
                }
            }
        }
        .padding(Theme.Spacing.small)
        .frame(width: 240)
    }

    private var reminderProjectPopover: some View {
        VStack(alignment: .leading, spacing: 1) {
            if draft.projectTitle != nil {
                Button {
                    draft.projectTitle = nil
                    projectQuery = ""
                    activate(.when)
                } label: {
                    Label("No Project", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Divider()
            }

            if matchingProjects.isEmpty {
                Text(availableProjects.isEmpty ? "No projects yet" : "Nothing by that name")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .padding(Theme.Spacing.small)
            } else {
                ForEach(Array(matchingProjects.enumerated()), id: \.offset) { index, title in
                    Button {
                        metadataSuggestionSelection = index
                        chooseProject(title)
                    } label: {
                        Label(
                            title,
                            systemImage: draft.projectTitle == title
                                ? "checkmark"
                                : "square.stack.3d.up"
                        )
                        .padding(.vertical, 3)
                        .padding(.horizontal, Theme.Spacing.tight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        index == metadataSuggestionSelection
                            ? Theme.Colors.selectionFill
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    )
                    .onHover { hovering in
                        if hovering { metadataSuggestionSelection = index }
                    }
                }
            }
        }
        .padding(Theme.Spacing.small)
        .frame(width: 240)
    }

    private func reminderDatePopover(
        field: ReminderComposerField,
        selected: Date?,
        allowsSomeday: Bool,
        onPick: @escaping (Date?) -> Void
    ) -> some View {
        let clock = services?.dateProvider ?? SystemDateProvider()
        let query = dateQuery(for: field).trimmingCharacters(in: .whitespacesAndNewlines)
        let suggestions = ReminderDateSearch.suggestions(for: query, using: clock)

        return Group {
            if query.isEmpty {
                dateCalendarPopover(
                    field: field,
                    selected: selected,
                    allowsSomeday: allowsSomeday,
                    clock: clock,
                    onPick: onPick
                )
            } else {
                dateSearchPopover(field: field, suggestions: suggestions, onPick: onPick)
            }
        }
    }

    @ViewBuilder
    private func dateSearchPopover(
        field: ReminderComposerField,
        suggestions: [ReminderDateSuggestion],
        onPick: @escaping (Date?) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if suggestions.isEmpty {
                Text("No matching date")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .padding(Theme.Spacing.small)
            } else {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    dateSearchRow(
                        suggestion,
                        index: index,
                        field: field,
                        onPick: onPick
                    )
                }
            }
        }
        .padding(Theme.Spacing.small)
        .frame(width: 290)
    }

    private func dateSearchRow(
        _ suggestion: ReminderDateSuggestion,
        index: Int,
        field: ReminderComposerField,
        onPick: @escaping (Date?) -> Void
    ) -> some View {
        Button {
            dateNavigation.target = .search(index)
            pickDate(suggestion.date, for: field, onPick: onPick)
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "calendar")
                    .foregroundStyle(Theme.CaptureToken.accent)
                Text(suggestion.title)
                    .foregroundStyle(Theme.Colors.primaryText)
                Spacer(minLength: Theme.Spacing.medium)
                Text(suggestion.detail)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
            .font(Theme.Text.rowTitle)
            .padding(.vertical, 5)
            .padding(.horizontal, Theme.Spacing.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            index == (dateNavigation.searchIndex ?? 0)
                ? Theme.Colors.selectionFill
                : Color.clear,
            in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
        )
        .onHover { hovering in
            if hovering { dateNavigation.target = .search(index) }
        }
    }

    private func dateCalendarPopover(
        field: ReminderComposerField,
        selected: Date?,
        allowsSomeday: Bool,
        clock: any DateProvider,
        onPick: @escaping (Date?) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            dateQuickChoice(
                title: "Today",
                symbol: "star",
                index: 0,
                date: clock.startOfToday,
                field: field,
                onPick: onPick
            )
            dateQuickChoice(
                title: "Tomorrow",
                symbol: "sunrise",
                index: 1,
                date: clock.startOfDay(daysFromToday: 1),
                field: field,
                onPick: onPick
            )

            Divider()

            TaskMonthPicker(
                calendar: clock.calendar,
                today: clock.now,
                selected: dateNavigation.day ?? selected,
                onPick: { date in
                    dateNavigation.target = .day(date)
                    pickDate(date, for: field, onPick: onPick)
                }
            )

            if allowsSomeday {
                Divider()
                Button("Someday", systemImage: "archivebox") {
                    whenQuery = ""
                    dateNavigation.reset()
                    draft.startAt = nil
                    draft.isSomeday = true
                    activate(.tags)
                }
                .buttonStyle(.plain)
            }

            if selected != nil || (allowsSomeday && draft.isSomeday) {
                Divider()
                Button("Clear", systemImage: "xmark.circle") {
                    pickDate(nil, for: field, onPick: onPick)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(width: 250)
    }

    private func dateQuickChoice(
        title: String,
        symbol: String,
        index: Int,
        date: Date,
        field: ReminderComposerField,
        onPick: @escaping (Date?) -> Void
    ) -> some View {
        Button {
            dateNavigation.target = .quick(index)
            pickDate(date, for: field, onPick: onPick)
        } label: {
            Label(title, systemImage: symbol)
                .padding(.vertical, 4)
                .padding(.horizontal, Theme.Spacing.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            dateNavigation.quickIndex == index ? Theme.Colors.selectionFill : Color.clear,
            in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
        )
        .onHover { hovering in
            if hovering { dateNavigation.target = .quick(index) }
        }
    }

    private func pickDate(
        _ date: Date?,
        for field: ReminderComposerField,
        onPick: (Date?) -> Void
    ) {
        switch field {
        case .when:
            whenQuery = ""
        case .deadline:
            deadlineQuery = ""
        case .title, .notes, .tags, .people, .checklist, .project:
            break
        }
        dateNavigation.reset()
        onPick(date)
    }

    private var matchingTags: [String] {
        let query = tagQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(availableTags.prefix(12)) }
        return Array(availableTags.lazy.filter { $0.localizedCaseInsensitiveContains(query) }.prefix(12))
    }

    private var matchingPeople: [String] {
        matchingNames(peopleQuery, in: availablePeople)
    }

    private var matchingProjects: [String] {
        matchingNames(projectQuery, in: availableProjects)
    }

    private func matchingNames(_ query: String, in names: [String]) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(names.prefix(12)) }

        let prefixed = names.filter { name in
            name.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive, .anchored]
            ) != nil
        }
        let contained = names.filter {
            $0.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive, .anchored]
            ) == nil
                && $0.localizedCaseInsensitiveContains(query)
        }
        return Array((prefixed + contained).prefix(12))
    }

    @discardableResult
    private func moveInlineSuggestion(_ direction: Int) -> Bool {
        guard !inlineSuggestions.isEmpty else { return false }
        inlineSuggestionSelection = max(
            0,
            min(inlineSuggestions.count - 1, inlineSuggestionSelection + direction)
        )
        return true
    }

    @discardableResult
    private func acceptInlineSuggestion() -> Bool {
        guard let inlineCompletion,
              inlineSuggestions.indices.contains(inlineSuggestionSelection)
        else { return false }

        let value = inlineSuggestions[inlineSuggestionSelection]
        let field = activeField
        let text: String
        let caret: Int
        switch field {
        case .title:
            text = draft.title
            caret = titleCaret
        case .notes:
            text = draft.notes
            caret = notesCaret
        case .when, .tags, .people, .checklist, .deadline, .project:
            return false
        }

        var characters = Array(text)
        guard inlineCompletion.start >= 0,
              inlineCompletion.start <= caret,
              caret <= characters.count
        else { return false }

        var removalStart = inlineCompletion.start
        var removalEnd = caret
        if removalEnd < characters.count,
           characters[removalEnd].isWhitespace,
           !characters[removalEnd].isNewline {
            removalEnd += 1
        } else if removalStart > 0,
                  characters[removalStart - 1].isWhitespace,
                  !characters[removalStart - 1].isNewline {
            removalStart -= 1
        }
        characters.removeSubrange(removalStart..<removalEnd)
        let updated = String(characters)

        switch inlineCompletion.trigger {
        case .tag:
            addTag(value)
        case .person:
            addPerson(value)
        case .project:
            draft.projectTitle = value
        case .bang, .dueDate, .followDate:
            return false
        }

        switch field {
        case .title:
            draft.title = updated
            titleCaret = removalStart
        case .notes:
            draft.notes = updated
            notesCaret = removalStart
        case .when, .tags, .people, .checklist, .deadline, .project:
            break
        }
        focusRouter.replaceText(updated, caret: removalStart, for: field)
        inlineSuggestionSelection = 0
        return true
    }

    @discardableResult
    private func moveMetadataSuggestion(
        _ direction: Int,
        for field: ReminderComposerField
    ) -> Bool {
        if field == .when || field == .deadline {
            return moveDateVertically(direction, for: field)
        }
        let suggestions = metadataSuggestions(for: field)
        guard !suggestions.isEmpty else { return false }
        metadataSuggestionSelection = max(
            0,
            min(suggestions.count - 1, metadataSuggestionSelection + direction)
        )
        metadataSuggestionWasNavigated = true
        return true
    }

    @discardableResult
    private func acceptMetadataSuggestion(for field: ReminderComposerField) -> Bool {
        if field == .when || field == .deadline {
            return acceptDateSelection(for: field)
        }
        let suggestions = metadataSuggestions(for: field)
        guard metadataSuggestionWasNavigated || !metadataQuery(for: field).isEmpty,
              suggestions.indices.contains(metadataSuggestionSelection)
        else { return false }
        let suggestion = suggestions[metadataSuggestionSelection]

        switch field {
        case .tags:
            toggleTag(suggestion)
            tagQuery = ""
        case .people:
            togglePerson(suggestion)
            peopleQuery = ""
        case .project:
            chooseProject(suggestion)
        case .title, .notes, .when, .checklist, .deadline:
            return false
        }
        return true
    }

    private func metadataSuggestions(for field: ReminderComposerField) -> [String] {
        switch field {
        case .tags: matchingTags
        case .people: matchingPeople
        case .project: matchingProjects
        case .title, .notes, .when, .checklist, .deadline: []
        }
    }

    private func metadataQuery(for field: ReminderComposerField) -> String {
        switch field {
        case .when: whenQuery
        case .tags: tagQuery
        case .people: peopleQuery
        case .deadline: deadlineQuery
        case .project: projectQuery
        case .title, .notes, .checklist: ""
        }
    }

    private func dateQuery(for field: ReminderComposerField) -> String {
        switch field {
        case .when: whenQuery
        case .deadline: deadlineQuery
        case .title, .notes, .tags, .people, .checklist, .project: ""
        }
    }

    private func selectedDate(for field: ReminderComposerField) -> Date? {
        switch field {
        case .when: draft.startAt
        case .deadline: draft.dueAt
        case .title, .notes, .tags, .people, .checklist, .project: nil
        }
    }

    @discardableResult
    private func moveDateVertically(
        _ direction: Int,
        for field: ReminderComposerField
    ) -> Bool {
        guard field == .when || field == .deadline else { return false }
        let clock = services?.dateProvider ?? SystemDateProvider()
        let query = dateQuery(for: field).trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let suggestions = ReminderDateSearch.suggestions(for: query, using: clock)
            return dateNavigation.moveSearch(direction, count: suggestions.count)
        }
        return dateNavigation.moveVertical(
            direction,
            selected: selectedDate(for: field),
            today: clock.startOfToday,
            calendar: clock.calendar
        )
    }

    @discardableResult
    private func moveDateHorizontally(
        _ direction: Int,
        for field: ReminderComposerField
    ) -> Bool {
        guard field == .when || field == .deadline,
              dateQuery(for: field).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        let clock = services?.dateProvider ?? SystemDateProvider()
        return dateNavigation.moveHorizontal(
            direction,
            selected: selectedDate(for: field),
            today: clock.startOfToday,
            calendar: clock.calendar
        )
    }

    @discardableResult
    private func acceptDateSelection(for field: ReminderComposerField) -> Bool {
        guard field == .when || field == .deadline else { return false }
        let clock = services?.dateProvider ?? SystemDateProvider()
        let query = dateQuery(for: field).trimmingCharacters(in: .whitespacesAndNewlines)
        let date: Date?

        if !query.isEmpty {
            let suggestions = ReminderDateSearch.suggestions(for: query, using: clock)
            let index = dateNavigation.searchIndex ?? 0
            guard suggestions.indices.contains(index) else { return false }
            date = suggestions[index].date
        } else {
            switch dateNavigation.target {
            case .quick(0):
                date = clock.startOfToday
            case .quick(1):
                date = clock.startOfDay(daysFromToday: 1)
            case .day(let selected):
                date = selected
            case .none, .quick, .search:
                return false
            }
        }

        guard let date else { return false }
        switch field {
        case .when:
            draft.startAt = date
            draft.isSomeday = false
            whenQuery = ""
            dateNavigation.reset()
            activate(.tags)
        case .deadline:
            draft.dueAt = date
            deadlineQuery = ""
            dateNavigation.reset()
            activate(.title)
        case .title, .notes, .tags, .people, .checklist, .project:
            return false
        }
        return true
    }

    private func resetMetadataSuggestion() {
        metadataSuggestionSelection = 0
        metadataSuggestionWasNavigated = false
    }

    private func moveFromTitle(reverse: Bool) {
        move(from: .title, reverse: reverse)
    }

    private func move(from field: ReminderComposerField, reverse: Bool) {
        let next = field.advanced(reverse: reverse)
        activate(next)
    }

    /// Moves through the product's focus path and switches the anchored metadata popover.
    private func activate(_ field: ReminderComposerField) {
        if activeField == field {
            focusRouter.focus(field)
            popupField = fieldHasPopup(field) ? field : nil
            return
        }
        collapseTransientEditor(activeField)
        resetMetadataSuggestion()
        dateNavigation.reset()
        popupField = fieldHasPopup(field) ? field : nil
        focusRouter.activate(field)
    }

    /// Query text belongs to an open picker, not to the reminder itself. Leaving a picker without
    /// choosing anything must therefore restore its icon/value instead of preserving a stranded
    /// placeholder editor. Checklist text is different: it is user content, so it is committed as
    /// the input row animates closed.
    private func collapseTransientEditor(_ field: ReminderComposerField) {
        switch field {
        case .when:
            whenQuery = ""
        case .tags:
            tagQuery = ""
        case .people:
            peopleQuery = ""
        case .checklist:
            commitChecklistRow()
        case .deadline:
            deadlineQuery = ""
        case .project:
            projectQuery = ""
        case .title, .notes:
            break
        }
    }

    /// Commits both sides of the AppKit/SwiftUI checklist editor transaction. The draft clears its
    /// pending value when it appends a row, but the live first-responder text view does not accept
    /// that external update while it is still editing. Clear it explicitly so the next row starts
    /// empty even when Return keeps focus in the same field.
    private func commitChecklistRow() {
        draft.commitPendingStep()
        focusRouter.replaceText("", caret: 0, for: .checklist)
    }

    private func fieldHasPopup(_ field: ReminderComposerField) -> Bool {
        field == .when
            || field == .tags
            || field == .people
            || field == .deadline
            || field == .project
    }

    private func commitWhenQuery() {
        guard let suggestion = services.flatMap({ TaskDateSuggestion.resolving(whenQuery, using: $0.dateProvider) })
        else { return }
        draft.startAt = suggestion.date
        draft.isSomeday = false
        whenQuery = ""
    }

    private func commitDeadlineQuery() {
        guard let suggestion = services.flatMap({ TaskDateSuggestion.resolving(deadlineQuery, using: $0.dateProvider) })
        else { return }
        draft.dueAt = suggestion.date
        deadlineQuery = ""
    }

    private func toggleFirstMatchingTag() {
        if let first = matchingTags.first {
            toggleTag(first)
        } else {
            addTag(tagQuery)
        }
        tagQuery = ""
    }

    private func addTag(_ name: String) {
        let slug = TextNormalizer.slug(name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !slug.isEmpty else { return }
        if !availableTags.contains(slug) { availableTags.append(slug); availableTags.sort() }
        if !draft.tagSlugs.contains(slug) { draft.tagSlugs.append(slug); draft.tagSlugs.sort() }
    }

    private func toggleTag(_ slug: String) {
        if draft.tagSlugs.contains(slug) {
            draft.tagSlugs.removeAll { $0 == slug }
        } else {
            draft.tagSlugs.append(slug)
            draft.tagSlugs.sort()
        }
    }

    private func toggleFirstMatchingPerson() {
        guard let first = matchingPeople.first else { return }
        togglePerson(first)
        peopleQuery = ""
    }

    private func togglePerson(_ name: String) {
        if draft.personNames.contains(name) {
            draft.personNames.removeAll { $0 == name }
        } else {
            draft.personNames.append(name)
            draft.personNames.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    private func addPerson(_ name: String) {
        let folded = TextNormalizer.foldedForMatching(name)
        guard !folded.isEmpty,
              !draft.personNames.contains(where: {
                  TextNormalizer.foldedForMatching($0) == folded
              })
        else { return }
        draft.personNames.append(name)
        draft.personNames.sort { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func chooseFirstMatchingProject() {
        guard let first = matchingProjects.first else { return }
        chooseProject(first)
    }

    private func chooseProject(_ title: String) {
        draft.projectTitle = title
        projectQuery = ""
        activate(.when)
    }

    private func refreshLibraryFacts() {
        availableTags = (try? services?.tags.allTags().map(\.slug).sorted()) ?? []
        let vocabulary = (try? services?.capture.vocabulary()) ?? .empty
        availablePeople = vocabulary.people.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        availableProjects = vocabulary.projects.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var shortcutVocabulary: CaptureVocabulary {
        CaptureVocabulary(projects: availableProjects, people: availablePeople)
    }

    private func settleInlineShortcuts() {
        let title = ReminderShortcutParser.extract(from: draft.title, knowing: shortcutVocabulary)
        let notes = ReminderShortcutParser.extract(from: draft.notes, knowing: shortcutVocabulary)

        draft.title = title.text
        draft.notes = notes.text
        for slug in title.tagSlugs + notes.tagSlugs { addTag(slug) }
        for name in title.personNames + notes.personNames { addPerson(name) }
        draft.projectTitle = notes.projectTitle ?? title.projectTitle ?? draft.projectTitle

        titleCaret = draft.title.count
        notesCaret = draft.notes.count
        focusRouter.replaceText(draft.title, caret: titleCaret, for: .title)
        focusRouter.replaceText(draft.notes, caret: notesCaret, for: .notes)
    }

    private func quickCommit() {
        settleInlineShortcuts()
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            activate(.notes)
            return
        }
        onQuickCommit()
        Task { @MainActor in
            await Task.yield()
            activate(.title)
        }
    }

    private func commitAndClose() {
        settleInlineShortcuts()
        onCommitAndClose()
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func summaryDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private func removeLastChecklistItem() -> Bool {
        guard draft.pendingStep.isEmpty else { return false }
        if !draft.checklist.isEmpty { draft.checklist.removeLast() }
        return true
    }
}

// MARK: - Deterministic popover presentation

/// Presents reminder pickers from a persistent AppKit anchor.
///
/// SwiftUI's `popover(isPresented:)` writes dismissal back through its binding. During fast focus
/// traversal that dismissal can arrive after the next field has already become active, which makes
/// a newly requested picker disappear. Reminder focus is authoritative, so this presenter only
/// reads the desired visibility. It never lets a native dismissal mutate composer state.
struct ReminderNativePopover<Content: View>: NSViewRepresentable {
    let isPresented: Bool
    let preferredEdge: NSRectEdge
    let content: Content

    init(
        isPresented: Bool,
        preferredEdge: NSRectEdge = .minY,
        @ViewBuilder content: () -> Content
    ) {
        self.isPresented = isPresented
        self.preferredEdge = preferredEdge
        self.content = content()
    }

    func makeCoordinator() -> ReminderNativePopoverCoordinator {
        ReminderNativePopoverCoordinator()
    }

    func makeNSView(context: Context) -> ReminderPopoverAnchorView {
        let anchor = ReminderPopoverAnchorView()
        context.coordinator.attach(to: anchor)
        return anchor
    }

    func updateNSView(_ anchor: ReminderPopoverAnchorView, context: Context) {
        context.coordinator.update(
            anchor: anchor,
            content: AnyView(content),
            isPresented: isPresented,
            preferredEdge: preferredEdge
        )
    }

    static func dismantleNSView(
        _ anchor: ReminderPopoverAnchorView,
        coordinator: ReminderNativePopoverCoordinator
    ) {
        coordinator.detach(from: anchor)
    }
}

final class ReminderPopoverAnchorView: NSView {
    var onWindowChange: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}

@MainActor
final class ReminderNativePopoverCoordinator: NSObject, NSPopoverDelegate {
    private weak var anchor: ReminderPopoverAnchorView?
    private let popover = NSPopover()
    private let hosting = NSHostingController(rootView: AnyView(EmptyView()))
    private var desiredPresented = false
    private var preferredEdge: NSRectEdge = .minY
    private var reopenScheduled = false

    override init() {
        super.init()
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
    }

    var isPopoverShown: Bool { popover.isShown }

    func attach(to anchor: ReminderPopoverAnchorView) {
        self.anchor = anchor
        anchor.onWindowChange = { [weak self] in self?.synchronize() }
        synchronize()
    }

    func update(
        anchor: ReminderPopoverAnchorView,
        content: AnyView,
        isPresented: Bool,
        preferredEdge: NSRectEdge
    ) {
        if self.anchor !== anchor { attach(to: anchor) }
        hosting.rootView = content
        desiredPresented = isPresented
        self.preferredEdge = preferredEdge
        synchronize()
    }

    func detach(from anchor: ReminderPopoverAnchorView) {
        guard self.anchor === anchor else { return }
        desiredPresented = false
        anchor.onWindowChange = nil
        popover.close()
        self.anchor = nil
    }

    func popoverDidClose(_ notification: Notification) {
        // AppKit may close a popover because its parent window is changing. If the field is still
        // active, restore it on the very next main-loop turn; focus remains the single owner.
        guard desiredPresented, !reopenScheduled else { return }
        reopenScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.reopenScheduled = false
            self.synchronize()
        }
    }

    private func synchronize() {
        guard desiredPresented else {
            if popover.isShown { popover.close() }
            return
        }
        guard !popover.isShown,
              let anchor,
              anchor.window != nil,
              !anchor.bounds.isEmpty
        else { return }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: preferredEdge)
    }
}

// MARK: - The keyboard editor

struct ReminderPlainTextEditor: NSViewRepresentable {
    enum Role { case title, notes, body }

    @Binding var text: String
    let placeholder: String
    let role: Role
    let onTab: (Bool) -> Void
    let onReturn: () -> Void
    let onCommandReturn: () -> Void
    let onEscape: () -> Void
    let field: ReminderComposerField
    let focusRouter: ReminderComposerFocusRouter
    var onMove: (Int) -> Bool = { _ in false }
    var onHorizontalMove: (Int) -> Bool = { _ in false }
    var onAcceptSuggestion: () -> Bool = { false }
    var onSelectionChange: (Int) -> Void = { _ in }
    var onDeleteBackwardWhenEmpty: () -> Bool = { false }
    var onFocus: () -> Void = {}

    static func verticalInset(for role: Role) -> CGFloat {
        switch role {
        case .title: 2
        case .notes: 0
        // Compact editors are 24 points tall and the system subheadline line height is 14.
        // Five points above and below centers its glyphs instead of leaving them visibly high.
        case .body: 5
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ReminderEditorScrollView {
        let scroll = ReminderEditorScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = role == .notes
        scroll.autohidesScrollers = true

        let editor = ReminderEditorTextView()
        editor.delegate = context.coordinator
        editor.coordinator = context.coordinator
        editor.focusField = field
        editor.focusRouter = focusRouter
        editor.string = text
        editor.placeholder = placeholder
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.isFieldEditor = role != .notes
        editor.isVerticallyResizable = role == .notes
        editor.isHorizontallyResizable = false
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.autoresizingMask = [.width]
        editor.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(
            width: 0,
            height: Self.verticalInset(for: role)
        )
        editor.font = switch role {
        case .title: .preferredFont(forTextStyle: .title3)
        case .notes, .body: .preferredFont(forTextStyle: .subheadline)
        }
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        scroll.documentView = editor
        focusRouter.register(editor, for: field)
        return scroll
    }

    func updateNSView(_ scroll: ReminderEditorScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ReminderEditorTextView else { return }
        focusRouter.register(editor, for: field)
        editor.placeholder = placeholder
        context.coordinator.reconciliationGeneration += 1
        let generation = context.coordinator.reconciliationGeneration
        guard editor.string != text else { return }

        // A keystroke can queue several SwiftUI updates. Reconcile external resets only after that
        // queue settles; applying an older snapshot immediately would erase the just-flushed text
        // as focus moves to the next field.
        DispatchQueue.main.async { [weak editor, weak coordinator = context.coordinator] in
            guard let editor,
                  let coordinator,
                  coordinator.reconciliationGeneration == generation,
                  !editor.hasMarkedText(),
                  editor.window?.firstResponder !== editor
            else { return }
            let latestText = coordinator.parent.text
            guard editor.string != latestText else { return }
            editor.string = latestText
            coordinator.lastEditorText = latestText
            editor.setSelectedRange(NSRange(location: (latestText as NSString).length, length: 0))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ReminderPlainTextEditor
        var lastEditorText: String
        var reconciliationGeneration = 0

        init(_ parent: ReminderPlainTextEditor) {
            self.parent = parent
            self.lastEditorText = parent.text
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
            flushText(editor)
        }

        func flushText(_ editor: NSTextView) {
            lastEditorText = editor.string
            parent.text = editor.string
            parent.onSelectionChange(
                CaptureHighlight.characterOffset(
                    ofUTF16: editor.selectedRange().location,
                    in: editor.string
                )
            )
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocus()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.onSelectionChange(
                CaptureHighlight.characterOffset(
                    ofUTF16: editor.selectedRange().location,
                    in: editor.string
                )
            )
        }

        /// AppKit interprets Tab and Return as text commands before a field editor necessarily
        /// receives a raw key event. Handling the commands here makes the path work for hardware
        /// keyboards, accessibility-generated events, and the system key-view loop alike.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                return parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onMove(1)
            case #selector(NSResponder.moveLeft(_:)):
                return parent.onHorizontalMove(-1)
            case #selector(NSResponder.moveRight(_:)):
                return parent.onHorizontalMove(1)
            case #selector(NSResponder.insertTab(_:)):
                if parent.onAcceptSuggestion() { return true }
                parent.onTab(false)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                parent.onTab(true)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                if NSApplication.shared.currentEvent?.modifierFlags.contains(.command) == true {
                    parent.onCommandReturn()
                    return true
                }
                if parent.onAcceptSuggestion() { return true }
                switch parent.role {
                case .notes:
                    return false
                case .title, .body:
                    parent.onReturn()
                    return true
                }
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }
}

final class ReminderEditorScrollView: NSScrollView {}

final class ReminderEditorTextView: NSTextView {
    weak var coordinator: ReminderPlainTextEditor.Coordinator?
    weak var focusRouter: ReminderComposerFocusRouter?
    var focusField: ReminderComposerField = .title
    var placeholder = "" { didSet { needsDisplay = true } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        focusRouter?.register(self, for: focusField)
    }

    override func mouseDown(with event: NSEvent) {
        // An NSTextView can remain in an editing session while another composer field temporarily
        // owns first responder. In that case AppKit does not send `textDidBeginEditing` again when
        // the user clicks back into it, so route the click explicitly before normal caret handling.
        MainActor.assumeIsolated { coordinator?.parent.onFocus() }
        super.mouseDown(with: event)
    }

    /// The text system may dispatch these actions directly, without a raw key event or delegate
    /// command. Overriding the responder actions closes that final route around the focus machine.
    override func insertTab(_ sender: Any?) {
        MainActor.assumeIsolated {
            guard let parent = coordinator?.parent else { return }
            if !parent.onAcceptSuggestion() { parent.onTab(false) }
        }
    }

    override func insertBacktab(_ sender: Any?) {
        MainActor.assumeIsolated { coordinator?.parent.onTab(true) }
    }

    override func deleteBackward(_ sender: Any?) {
        if string.isEmpty,
           MainActor.assumeIsolated({ coordinator?.parent.onDeleteBackwardWhenEmpty() == true }) {
            return
        }
        super.deleteBackward(sender)
    }

    override func keyDown(with event: NSEvent) {
        guard let parent = coordinator?.parent else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 123: // Left Arrow
            if !MainActor.assumeIsolated({ parent.onHorizontalMove(-1) }) {
                super.keyDown(with: event)
            }
        case 124: // Right Arrow
            if !MainActor.assumeIsolated({ parent.onHorizontalMove(1) }) {
                super.keyDown(with: event)
            }
        case 126: // Up Arrow
            if !MainActor.assumeIsolated({ parent.onMove(-1) }) {
                super.keyDown(with: event)
            }
        case 125: // Down Arrow
            if !MainActor.assumeIsolated({ parent.onMove(1) }) {
                super.keyDown(with: event)
            }
        case 48: // Tab
            MainActor.assumeIsolated {
                let reverse = event.modifierFlags.contains(.shift)
                if reverse || !parent.onAcceptSuggestion() { parent.onTab(reverse) }
            }
        case 36, 76: // Return and keypad Enter
            if event.modifierFlags.contains(.command) {
                MainActor.assumeIsolated { parent.onCommandReturn() }
            } else if MainActor.assumeIsolated({ parent.onAcceptSuggestion() }) {
                return
            } else if parent.role == .notes {
                super.keyDown(with: event)
            } else {
                MainActor.assumeIsolated { parent.onReturn() }
            }
        case 53: // Escape
            MainActor.assumeIsolated { parent.onEscape() }
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let padding = textContainer?.lineFragmentPadding ?? 0
        NSAttributedString(
            string: placeholder,
            attributes: [
                .font: font ?? NSFont.preferredFont(forTextStyle: .subheadline),
                .foregroundColor: NSColor.placeholderTextColor,
            ]
        ).draw(at: NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y))
    }
}

// MARK: - Authoritative focus routing

/// Owns the composer responder chain for its entire lifetime.
///
/// SwiftUI state describes the visuals, but it never decides which editor is first responder.
/// That decision stays here, beside the concrete AppKit text views, so a Tab cannot race a view
/// update or be redirected by a popover window.
@MainActor
final class ReminderComposerFocusRouter: ObservableObject {
    @Published private(set) var activeField: ReminderComposerField = .title
    var onTab: ((Bool) -> Void)?
    var onTextInput: ((String) -> Bool)?

    private var editors: [ReminderComposerField: WeakReminderEditor] = [:]
    private var focusGeneration = 0

    func register(_ editor: NSTextView, for field: ReminderComposerField) {
        editors[field] = WeakReminderEditor(editor)
        if activeField == field { focus(field) }
    }

    func activate(_ field: ReminderComposerField) {
        flushActiveEditor()
        activeField = field
        focus(field)
    }

    func focus(_ field: ReminderComposerField) {
        focusGeneration += 1
        let generation = focusGeneration
        _ = focusNow(field)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.focusGeneration == generation,
                  self.activeField == field
            else { return }
            _ = self.focusNow(field)
        }
    }

    @discardableResult
    private func focusNow(_ field: ReminderComposerField) -> Bool {
        guard activeField == field,
              let editor = editors[field]?.value,
              let window = editor.window
        else { return false }
        if window.firstResponder !== editor, !window.makeFirstResponder(editor) { return false }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        return true
    }

    func handleTab(reverse: Bool) {
        flushActiveEditor()
        onTab?(reverse)
    }

    func handleTextInput(_ characters: String) -> Bool {
        onTextInput?(characters) == true
    }

    func replaceText(_ text: String, caret: Int, for field: ReminderComposerField) {
        guard let editor = editors[field]?.value as? ReminderEditorTextView else { return }
        editor.string = text
        editor.coordinator?.lastEditorText = text
        editor.setSelectedRange(
            NSRange(
                location: CaptureHighlight.utf16Offset(ofCharacter: caret, in: text),
                length: 0
            )
        )
        editor.needsDisplay = true
    }

    private func flushActiveEditor() {
        guard let editor = editors[activeField]?.value as? ReminderEditorTextView,
              !editor.hasMarkedText()
        else { return }
        editor.coordinator?.flushText(editor)
    }
}

private final class WeakReminderEditor {
    weak var value: NSTextView?

    init(_ value: NSTextView) {
        self.value = value
    }
}

// MARK: - Window-level keyboard routing

/// Captures Tab before AppKit decides whether it means text insertion, field-editor traversal, or
/// an accessibility key-view action. It exists only while one composer exists and only consumes
/// events belonging to that composer's window.
struct ReminderComposerKeyboardMonitor: NSViewRepresentable {
    let router: ReminderComposerFocusRouter

    func makeCoordinator() -> Coordinator { Coordinator(router: router) }

    func makeNSView(context: Context) -> ReminderComposerKeyboardMonitorView {
        let view = ReminderComposerKeyboardMonitorView()
        context.coordinator.install(for: view)
        return view
    }

    func updateNSView(_ view: ReminderComposerKeyboardMonitorView, context: Context) {}

    static func dismantleNSView(
        _ view: ReminderComposerKeyboardMonitorView,
        coordinator: Coordinator
    ) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        weak var router: ReminderComposerFocusRouter?
        private var monitor: Any?

        init(router: ReminderComposerFocusRouter) {
            self.router = router
        }

        func install(for view: ReminderComposerKeyboardMonitorView) {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
                guard let self,
                      let view,
                      let composerWindow = view.window,
                      NSApp.isActive,
                      event.window === composerWindow || NSApp.mainWindow === composerWindow
                else { return event }

                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if event.keyCode == 48,
                   !modifiers.contains(.command),
                   !modifiers.contains(.control),
                   !modifiers.contains(.option) {
                    self.router?.handleTab(reverse: modifiers.contains(.shift))
                    return nil
                }

                guard !modifiers.contains(.command),
                      !modifiers.contains(.control),
                      !modifiers.contains(.option),
                      let characters = event.characters,
                      !characters.isEmpty,
                      characters.unicodeScalars.allSatisfy({
                          !CharacterSet.controlCharacters.contains($0)
                      }),
                      self.router?.handleTextInput(characters) == true
                else { return event }
                return nil
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

    }
}

final class ReminderComposerKeyboardMonitorView: NSView {}
