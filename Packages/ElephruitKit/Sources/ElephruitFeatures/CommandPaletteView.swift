import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// One thing the palette can do.
public struct PaletteCommand: Identifiable, Sendable {
    public enum Category: String, Sendable, CaseIterable {
        case navigate
        case create
        case transfer
        case view

        var displayName: String {
            switch self {
            case .navigate: "Go To"
            case .create: "Create"
            case .transfer: "Import & Export"
            case .view: "View"
            }
        }
    }

    public let id: String
    public let title: String
    public let category: Category
    public let symbolName: String

    /// The glyphs shown on the right of the row.
    ///
    /// Always derived from ``ShortcutRegistry`` rather than written out here. These used to be
    /// hard-coded arrays like `["⌘","⇧","N"]` — a second description of a binding the menu already
    /// owned, with nothing keeping the two equal. A palette that shows the wrong shortcut is worse
    /// than one that shows none.
    public let shortcut: [String]

    public let action: @MainActor () -> Void

    public init(
        id: String,
        title: String,
        category: Category,
        symbolName: String,
        shortcut: [String] = [],
        action: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.symbolName = symbolName
        self.shortcut = shortcut
        self.action = action
    }

    /// The same, with the glyphs looked up rather than stated.
    public init(
        id: String,
        title: String,
        category: Category,
        symbolName: String,
        command: ShortcutCommand,
        in registry: ShortcutRegistry,
        action: @escaping @MainActor () -> Void
    ) {
        self.init(
            id: id,
            title: title,
            category: category,
            symbolName: symbolName,
            shortcut: registry.binding(for: command)?.glyphs ?? [],
            action: action
        )
    }
}

/// The command palette — `⌘K`.
///
/// Two things in one surface: the app's commands, and every item by title. That combination is what
/// makes it worth reaching for instead of the menu bar — "go to the Q3 Launch note" and "export my
/// library" are the same gesture.
public struct CommandPaletteView: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    private let navigation: NavigationModel
    private let commands: [PaletteCommand]

    @State private var queryText = ""
    @State private var itemMatches: [(id: UUID, title: String)] = []
    @State private var highlightedIndex = 0
    @FocusState private var isFieldFocused: Bool

    public init(navigation: NavigationModel, commands: [PaletteCommand]) {
        self.navigation = navigation
        self.commands = commands
    }

    public var body: some View {
        VStack(spacing: 0) {
            field
            Divider()
            resultList
        }
        .frame(width: 560, height: 420)
        .background(.regularMaterial)
        // Declarative rather than an onAppear write alone: `defaultFocus` is what tells the
        // focus system where a fresh presentation starts, and it survives the representation
        // timing the appearance write used to race against.
        .defaultFocus($isFieldFocused, true)
        .onAppear {
            isFieldFocused = true
            refreshItemMatches()
        }
        .accessibilityIdentifier(AccessibilityID.CommandPalette.root)
    }

    private var field: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "command")
                .foregroundStyle(Theme.Colors.secondaryText)
                .accessibilityHidden(true)

            TextField("Type a command or an item name", text: $queryText)
                .textFieldStyle(.plain)
                .font(.system(.title3))
                .focused($isFieldFocused)
                .onSubmit { runHighlighted() }
                .onChange(of: queryText) { _, _ in
                    highlightedIndex = 0
                    refreshItemMatches()
                }
                .onKeyPress(.upArrow) { moveHighlight(by: -1); return .handled }
                .onKeyPress(.downArrow) { moveHighlight(by: 1); return .handled }
                .accessibilityIdentifier(AccessibilityID.CommandPalette.field)
                .accessibilityLabel("Command or item name")
        }
        .padding(Theme.Spacing.large)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            List {
                if !matchingCommands.isEmpty {
                    ForEach(PaletteCommand.Category.allCases, id: \.self) { category in
                        let inCategory = matchingCommands.filter { $0.category == category }
                        if !inCategory.isEmpty {
                            Section {
                                ForEach(inCategory) { command in
                                    commandRow(command)
                                        .id(rowIdentifier(for: command))
                                }
                            } header: {
                                SectionHeader(category.displayName)
                            }
                        }
                    }
                }

                if !itemMatches.isEmpty {
                    Section {
                        ForEach(itemMatches, id: \.id) { match in
                            itemRow(match)
                                .id(rowIdentifier(forItemID: match.id))
                        }
                    } header: {
                        SectionHeader("Items", count: itemMatches.count)
                    }
                }

                if matchingCommands.isEmpty, itemMatches.isEmpty {
                    Text("Nothing matches")
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(Theme.Spacing.large)
                }
            }
            .listStyle(.inset)
            .accessibilityIdentifier(AccessibilityID.CommandPalette.results)
            .onChange(of: highlightedIndex) { _, newValue in
                proxy.scrollTo(identifier(atFlatIndex: newValue), anchor: .center)
            }
        }
    }

    private func commandRow(_ command: PaletteCommand) -> some View {
        let index = flatIndex(ofCommand: command)

        return Button {
            run(command)
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: command.symbolName)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(width: Theme.Size.rowGlyph)
                Text(command.title)
                Spacer()
                if !command.shortcut.isEmpty {
                    KeyHint(keys: command.shortcut)
                }
            }
            .padding(.vertical, Theme.Spacing.hairline)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(highlightBackground(isHighlighted: index == highlightedIndex))
        .accessibilityIdentifier(AccessibilityID.CommandPalette.result(index: index))
    }

    private func itemRow(_ match: (id: UUID, title: String)) -> some View {
        let index = flatIndex(ofItemID: match.id)

        return Button {
            openItem(id: match.id)
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: symbolName(forItemID: match.id))
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(width: Theme.Size.rowGlyph)
                Text(match.title)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.vertical, Theme.Spacing.hairline)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(highlightBackground(isHighlighted: index == highlightedIndex))
        .accessibilityIdentifier(AccessibilityID.CommandPalette.result(index: index))
    }

    @ViewBuilder
    private func highlightBackground(isHighlighted: Bool) -> some View {
        if isHighlighted {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Theme.Colors.selectionFill)
        } else {
            Color.clear
        }
    }

    // MARK: - Matching

    /// Subsequence matching, so "nn" finds "New Note".
    ///
    /// Deliberately not a scored fuzzy match in v1: a simple, predictable rule is easier to build a
    /// habit around than a clever one that occasionally surprises.
    private var matchingCommands: [PaletteCommand] {
        let query = TextNormalizer.foldedForMatching(queryText)
        guard !query.isEmpty else { return commands }

        return commands.filter { command in
            let title = TextNormalizer.foldedForMatching(command.title)
            return title.contains(query) || Self.isSubsequence(query, of: title)
        }
    }

    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = Substring(needle)
        for character in haystack where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }

    private func refreshItemMatches() {
        guard let services, queryText.count >= 2 else {
            itemMatches = []
            return
        }

        let text = queryText
        Task {
            let matches = await services.search.titleSuggestions(prefix: text, limit: 8)
            guard queryText == text else { return }
            itemMatches = matches
        }
    }

    private func symbolName(forItemID id: UUID) -> String {
        guard let services, let item = try? services.items.item(id: id) else { return "doc" }
        return item.effectiveSymbolName
    }

    // MARK: - Keyboard navigation

    private var flatCount: Int {
        matchingCommands.count + itemMatches.count
    }

    private func moveHighlight(by delta: Int) {
        guard flatCount > 0 else { return }
        highlightedIndex = (highlightedIndex + delta + flatCount) % flatCount
    }

    private func flatIndex(ofCommand command: PaletteCommand) -> Int {
        orderedCommands.firstIndex(where: { $0.id == command.id }) ?? 0
    }

    /// Commands in the order they are rendered, which is by category rather than by match order —
    /// so keyboard navigation matches what the eye sees.
    private var orderedCommands: [PaletteCommand] {
        PaletteCommand.Category.allCases.flatMap { category in
            matchingCommands.filter { $0.category == category }
        }
    }

    private func flatIndex(ofItemID id: UUID) -> Int {
        matchingCommands.count + (itemMatches.firstIndex { $0.id == id } ?? 0)
    }

    private func rowIdentifier(for command: PaletteCommand) -> String { "command-\(command.id)" }
    private func rowIdentifier(forItemID id: UUID) -> String { "item-\(id.uuidString)" }

    private func identifier(atFlatIndex index: Int) -> String {
        if index < orderedCommands.count {
            return rowIdentifier(for: orderedCommands[index])
        }
        let itemIndex = index - orderedCommands.count
        guard itemIndex < itemMatches.count else { return "" }
        return rowIdentifier(forItemID: itemMatches[itemIndex].id)
    }

    private func runHighlighted() {
        if highlightedIndex < orderedCommands.count {
            run(orderedCommands[highlightedIndex])
            return
        }
        let itemIndex = highlightedIndex - orderedCommands.count
        guard itemIndex < itemMatches.count else { return }
        openItem(id: itemMatches[itemIndex].id)
    }

    private func run(_ command: PaletteCommand) {
        dismiss()
        command.action()
    }

    private func openItem(id: UUID) {
        guard let services, let item = try? services.items.item(id: id) else { return }
        // Through the router, not `.kind(...)`: a reminder or a bug opened by kind lands in a
        // list whose module has no detail pane — selected, and shown nowhere.
        navigation.open(item)
        dismiss()
    }
}

#Preview("Command palette") {
    CommandPaletteView(
        navigation: NavigationModel(),
        commands: [
            PaletteCommand(id: "today", title: "Go to Today", category: .navigate, symbolName: "sun.max", shortcut: ["⌘", "0"]) {},
            PaletteCommand(id: "new-note", title: "New Note", category: .create, symbolName: "note.text", shortcut: ["⌘", "N"]) {},
            PaletteCommand(id: "export", title: "Export Library…", category: .transfer, symbolName: "square.and.arrow.up") {},
        ]
    )
    .appServices(AppServices.inMemory())
}
