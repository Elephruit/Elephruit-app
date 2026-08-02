import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

// MARK: - The / menu

/// The insertion menu, opened by typing `/` in a prose segment.
///
/// Rows are identified by the command they represent and scrolled to by that same identity —
/// never by position. The first build identified rows by index and the menu rendered the wrong
/// block for the right match; see "Traps already paid for" in the spec.
struct NoteSlashMenuView: View {
    let matches: [NoteInsertionCommand]
    let highlighted: NoteInsertionCommand?
    let onHighlight: (NoteInsertionCommand) -> Void
    let onChoose: (NoteInsertionCommand) -> Void

    var body: some View {
        Group {
            if matches.isEmpty {
                Text("Nothing matches")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .padding(Theme.Spacing.large)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        NoteSlashMenuList(
                            matches: matches,
                            highlighted: highlighted,
                            onHighlight: onHighlight,
                            onChoose: onChoose
                        )
                        .padding(.vertical, Theme.Spacing.tight)
                    }
                    .onChange(of: highlighted) { _, newValue in
                        if let newValue {
                            proxy.scrollTo(newValue)
                        }
                    }
                }
            }
        }
        .frame(width: 280)
        .frame(maxHeight: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large)
                .strokeBorder(Theme.Colors.separator, lineWidth: 1)
        )
        .shadow(color: Theme.Colors.shadow.opacity(0.18), radius: 12, y: 4)
    }

}

/// The menu's rows, apart from the scroll view that usually holds them — separately, so the
/// gallery can rasterise them (`ImageRenderer` renders a `ScrollView` as an empty box).
struct NoteSlashMenuList: View {
    let matches: [NoteInsertionCommand]
    let highlighted: NoteInsertionCommand?
    let onHighlight: (NoteInsertionCommand) -> Void
    let onChoose: (NoteInsertionCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(NoteInsertionGroup.allCases, id: \.self) { group in
                let commands = matches.filter { $0.group == group }
                if !commands.isEmpty {
                    Text(group.rawValue)
                        .font(Theme.Text.sectionHeader)
                        .tracking(Theme.Text.Tracking.caps)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .padding(.horizontal, Theme.Spacing.medium)
                        .padding(.top, Theme.Spacing.small)
                        .padding(.bottom, Theme.Spacing.hairline)

                    ForEach(commands, id: \.self) { command in
                        row(for: command)
                    }
                }
            }
        }
    }

    private func row(for command: NoteInsertionCommand) -> some View {
        let isHighlighted = command == highlighted

        return Button {
            onChoose(command)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Image(systemName: command.symbolName)
                    .frame(width: Theme.Size.rowGlyph)
                    .foregroundStyle(isHighlighted ? Theme.Colors.onAccent : Theme.Colors.secondaryText)

                VStack(alignment: .leading, spacing: 0) {
                    Text(command.displayName)
                        .font(Theme.Text.rowTitle)
                        .foregroundStyle(isHighlighted ? Theme.Colors.onAccent : Theme.Colors.primaryText)
                    Text(command.hint)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(isHighlighted ? Theme.Colors.onAccent.opacity(0.8) : Theme.Colors.tertiaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.tight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .fill(isHighlighted ? Theme.Colors.selection : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Spacing.tight)
        .onHover { hovering in
            if hovering { onHighlight(command) }
        }
    }
}

// MARK: - The outline

/// The table of contents, generated from the document's headings.
struct NoteOutlineRail: View {
    let model: NoteEditorModel

    var body: some View {
        let entries = model.outline

        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Contents")
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.top, Theme.Spacing.medium)

            if entries.isEmpty {
                Text("Headings you add will appear here.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .padding(Theme.Spacing.medium)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    NoteOutlineList(model: model)
                        .padding(.horizontal, Theme.Spacing.small)
                        .padding(.vertical, Theme.Spacing.small)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(width: 200, alignment: .leading)
        .accessibilityIdentifier(AccessibilityID.Notes.outline)
        .accessibilityLabel(String(localized: "Table of contents"))
    }

}

/// The outline's rows, apart from their scroll view, for the same gallery reason as
/// ``NoteSlashMenuList``.
struct NoteOutlineList: View {
    let model: NoteEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
            ForEach(model.outline) { entry in
                row(for: entry)
            }
        }
    }

    private func row(for entry: NoteOutlineEntry) -> some View {
        let isActive = model.activeOutlineEntryID == entry.id

        return Button {
            model.reveal(entry)
        } label: {
            Text(entry.title)
                .font(entry.level == 1 ? Theme.Text.rowTitleEmphasised : Theme.Text.rowSubtitle)
                .foregroundStyle(isActive ? Theme.Colors.primaryText : Theme.Colors.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, CGFloat(entry.level - 1) * Theme.Spacing.medium)
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.vertical, Theme.Spacing.tight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .fill(isActive ? Theme.Colors.selectionFill : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.title)
    }
}

// MARK: - The format panel

/// Everything a selection can become, in one panel: paragraph kinds, inline marks, indentation,
/// a callout's tone, a code block's language, and links.
///
/// Commands land on ``NoteEditorModel/commandTarget`` — the text view that last held the caret —
/// whose selection survives the panel taking key focus.
struct NoteFormatPanel: View {
    let model: NoteEditorModel

    @State private var linkAddress = ""
    @State private var codeLanguage = ""

    private var selection: NoteSelectionState { model.selection }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            kindSection
            marksSection

            if selection.canIndent {
                indentSection
            }
            if selection.kinds.contains(.callout) {
                toneSection
            }
            if selection.kinds.contains(.code) {
                languageSection
            }

            linkSection
        }
        .padding(Theme.Spacing.large)
        .frame(width: 300)
        .accessibilityIdentifier(AccessibilityID.Notes.inspector)
    }

    // MARK: Kinds

    private var kindSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            SectionHeader("Paragraph")

            let columns = [GridItem(.adaptive(minimum: 84), spacing: Theme.Spacing.tight)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.tight) {
                ForEach(NoteParagraphKind.allCases, id: \.self) { kind in
                    kindButton(kind)
                }
            }
        }
    }

    private func kindButton(_ kind: NoteParagraphKind) -> some View {
        let isCurrent = selection.kinds == [kind]

        return Button {
            model.commandTarget?.applyParagraphKind(kind)
        } label: {
            HStack(spacing: Theme.Spacing.tight) {
                Image(systemName: kind.symbolName)
                    .font(.caption)
                Text(shortName(for: kind))
                    .font(Theme.Text.chip)
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .fill(isCurrent ? Theme.Colors.selectionFill : Theme.Colors.subtleFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .strokeBorder(isCurrent ? Theme.Colors.selection : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(kind.hint)
    }

    private func shortName(for kind: NoteParagraphKind) -> String {
        switch kind {
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .bulleted: "Bullets"
        case .numbered: "Numbers"
        default: kind.displayName
        }
    }

    // MARK: Marks

    private var marksSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            SectionHeader("Style")

            HStack(spacing: Theme.Spacing.tight) {
                markButton(.bold, symbol: "bold", label: "Bold", shortcut: "⌘B")
                markButton(.italic, symbol: "italic", label: "Italic", shortcut: "⌘I")
                markButton(.underline, symbol: "underline", label: "Underline", shortcut: "⌘U")
                markButton(.strikethrough, symbol: "strikethrough", label: "Strikethrough", shortcut: "⇧⌘X")
                markButton(.code, symbol: "chevron.left.forwardslash.chevron.right", label: "Inline code", shortcut: "⌘E")
            }
        }
    }

    private func markButton(
        _ mark: NoteInlineMarks,
        symbol: String,
        label: String,
        shortcut: String
    ) -> some View {
        let isOn = selection.marks.contains(mark)

        return Button {
            model.commandTarget?.toggleMark(mark)
        } label: {
            Image(systemName: symbol)
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .fill(isOn ? Theme.Colors.selectionFill : Theme.Colors.subtleFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .strokeBorder(isOn ? Theme.Colors.selection : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(label) — \(shortcut)")
        .accessibilityLabel(label)
    }

    // MARK: Indent

    private var indentSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            SectionHeader("Indent")

            HStack(spacing: Theme.Spacing.tight) {
                Button {
                    model.commandTarget?.applyIndent(by: -1)
                } label: {
                    Image(systemName: "decrease.indent")
                        .frame(width: 30, height: 26)
                        .background(Theme.Colors.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Step out — ⇧⇥")
                .accessibilityLabel(String(localized: "Decrease indent"))

                Button {
                    model.commandTarget?.applyIndent(by: 1)
                } label: {
                    Image(systemName: "increase.indent")
                        .frame(width: 30, height: 26)
                        .background(Theme.Colors.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Nest — ⇥")
                .accessibilityLabel(String(localized: "Increase indent"))
            }
        }
    }

    // MARK: Callout tone

    private var toneSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            SectionHeader("Tone")

            HStack(spacing: Theme.Spacing.small) {
                ForEach(NoteCalloutTone.allCases, id: \.self) { tone in
                    let isCurrent = selection.calloutTone == tone
                    Button {
                        model.commandTarget?.applyCalloutTone(tone)
                    } label: {
                        Circle()
                            .fill(Theme.Palette.color(named: tone.paletteName, neutral: Theme.Colors.subtleFill))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle().strokeBorder(
                                    isCurrent ? Theme.Colors.primaryText.opacity(0.6) : Color.clear,
                                    lineWidth: 2
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(tone.displayName)
                    .accessibilityLabel(tone.displayName)
                }
            }
        }
    }

    // MARK: Code language

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            SectionHeader("Language")

            TextField("swift, python…", text: $codeLanguage)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit {
                    model.commandTarget?.applyCodeLanguage(codeLanguage)
                }
                .onAppear { codeLanguage = selection.codeLanguage ?? "" }
        }
    }

    // MARK: Link

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            SectionHeader("Link")

            HStack(spacing: Theme.Spacing.tight) {
                TextField("https://…", text: $linkAddress)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { applyLink() }

                Button("Set") { applyLink() }
                    .controlSize(.small)
                    .disabled(!selection.hasSelection || linkAddress.isEmpty)

                Button("Clear") {
                    model.commandTarget?.applyLink(nil)
                    linkAddress = ""
                }
                .controlSize(.small)
                .disabled(!selection.hasSelection)
            }

            if !selection.hasSelection {
                Text("Select some text to link it.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
    }

    private func applyLink() {
        guard selection.hasSelection, !linkAddress.isEmpty else { return }
        var address = linkAddress
        if !address.contains("://") {
            address = "https://" + address
        }
        model.commandTarget?.applyLink(.url(address))
    }
}

// MARK: - The info panel

/// The document's facts and its actions, from the toolbar's ⓘ.
struct NoteInfoPanel: View {
    @Environment(\.services) private var services

    let item: Item
    let model: NoteEditorModel
    let onDelete: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                SectionHeader("Properties")
                fact("Created", item.createdAt.formatted(date: .abbreviated, time: .shortened))
                fact("Updated", item.updatedAt.formatted(.relative(presentation: .named)))
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                SectionHeader("Statistics")
                fact("Words", "\(wordCount)")
                fact("Characters", "\(characterCount)")
                fact("Reading time", readingTime)
            }

            Divider()

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Button {
                    copyAsMarkdown()
                } label: {
                    Label("Copy as Markdown", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)

                Button {
                    toggleFavorite()
                } label: {
                    Label(
                        item.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: item.isFavorite ? "star.fill" : "star"
                    )
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                        .foregroundStyle(Theme.Colors.destructive)
                }
                .buttonStyle(.borderless)
                .confirmationDialog(
                    "Move “\(item.displayTitle)” to the Trash?",
                    isPresented: $confirmingDelete
                ) {
                    Button("Move to Trash", role: .destructive) { onDelete() }
                } message: {
                    Text("You can put it back from the Trash.")
                }
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 280)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.primaryText)
        }
    }

    private var wordCount: Int {
        model.document.plainText
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
    }

    private var characterCount: Int {
        model.document.plainText.filter { !$0.isNewline }.count
    }

    private var readingTime: String {
        // Two hundred words a minute — unhurried reading speed; a floor of one so a short note
        // does not claim to take no time at all.
        let minutes = max(1, Int((Double(wordCount) / 200).rounded(.up)))
        return String(localized: "\(minutes) min")
    }

    private func copyAsMarkdown() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.document.projectedBody, forType: .string)
    }

    private func toggleFavorite() {
        guard let services else { return }
        services.perform {
            try services.items.update(item) { $0.isFavorite.toggle() }
        }
        services.noteChange(to: item)
    }
}

// MARK: - The reference picker

/// A small searcher for the `/link to item` command: type, pick, done.
struct NoteReferencePickerSheet: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    let excludedItemID: UUID
    let onPick: (UUID) -> Void

    @State private var query = ""
    @State private var suggestions: [(id: UUID, title: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Link to an item")
                .font(Theme.Text.title)
                .tracking(Theme.Text.Tracking.title)

            TextField("Search by title…", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if let first = suggestions.first {
                        choose(first.id)
                    }
                }

            if suggestions.isEmpty {
                Text(query.isEmpty ? "Type to search your items." : "Nothing matches.")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                        ForEach(suggestions, id: \.id) { suggestion in
                            Button {
                                choose(suggestion.id)
                            } label: {
                                Text(suggestion.title)
                                    .font(Theme.Text.rowTitle)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, Theme.Spacing.small)
                                    .padding(.vertical, Theme.Spacing.tight)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 240)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.Spacing.section)
        .frame(width: 380)
        .task(id: query) {
            guard let services else { return }
            let results = await services.search.titleSuggestions(prefix: query, limit: 12)
            suggestions = results.filter { $0.id != excludedItemID }
        }
    }

    private func choose(_ id: UUID) {
        onPick(id)
        dismiss()
    }
}
