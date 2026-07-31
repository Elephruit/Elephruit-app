import ElephruitCore
import SwiftUI

// MARK: - Item row

/// One item in a list.
///
/// Takes a ``ContentItem`` rather than a concrete model type, so the design system does not
/// depend on the persistence layer and previews can supply plain values.
///
/// The row shows only what is *true and relevant*: a due date appears when there is one, a
/// project when the item has a parent, tags when there are tags. Nothing is reserved space for
/// something that might be there, because that is what makes a dense list feel cluttered.
public struct ItemRow<Item: ContentItem>: View {
    private let item: Item
    private let dateProvider: any DateProvider
    private let showsKindGlyph: Bool
    private let showsParent: Bool
    private let onToggleStatus: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        item: Item,
        dateProvider: any DateProvider,
        showsKindGlyph: Bool = true,
        showsParent: Bool = true,
        onToggleStatus: (() -> Void)? = nil
    ) {
        self.item = item
        self.dateProvider = dateProvider
        self.showsKindGlyph = showsKindGlyph
        self.showsParent = showsParent
        self.onToggleStatus = onToggleStatus
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            leadingGlyph

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                titleLine

                if !secondaryParts.isEmpty {
                    secondaryLine
                }
            }

            Spacer(minLength: Theme.Spacing.small)

            trailingAccessories
        }
        .padding(.vertical, Theme.Spacing.tight)
        .frame(minHeight: Theme.Size.rowHeight)
        .contentShape(.rect)
        // One composed label, so VoiceOver announces the row as a sentence rather than reading
        // out five disconnected fragments.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityDescription(using: dateProvider))
        .accessibilityIdentifier(AccessibilityID.ItemList.row(id: item.id.uuidString))
        .accessibilityAddTraits(item.isCompleted ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        if item.kind.supportsStatus, let onToggleStatus {
            Button(action: onToggleStatus) {
                Image(systemName: item.status.symbolName)
                    .rowTint(item.isCompleted ? Theme.Colors.completed : Theme.Colors.secondaryText)
                    .frame(width: Theme.Size.rowGlyph)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isCompleted ? "Mark incomplete" : "Mark complete")
            .accessibilityIdentifier(AccessibilityID.ItemList.statusToggle(id: item.id.uuidString))
            .calmAnimation(Theme.Motion.standard, value: item.status)
        } else if showsKindGlyph {
            Image(systemName: item.effectiveSymbolName)
                .rowTint(glyphColor)
                .frame(width: Theme.Size.rowGlyph)
                .accessibilityHidden(true)
        }
    }

    private var glyphColor: Color {
        if let colorName = item.colorName {
            return Theme.Palette.color(named: colorName)
        }
        return Theme.Colors.secondaryText
    }

    private var titleLine: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Text(item.displayTitle)
                .font(item.isPinned ? Theme.Text.rowTitleEmphasised : Theme.Text.rowTitle)
                .rowForeground(titleEmphasis)
                .strikethrough(item.isCompleted, color: Theme.Colors.tertiaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            if item.isFavorite {
                Image(systemName: "star.fill")
                    .font(Theme.Text.metadata)
                    .rowTint(Theme.Colors.dueToday)
                    .accessibilityHidden(true)
            }
        }
    }

    private var titleEmphasis: Theme.Emphasis {
        if item.isCompleted { return .secondary }
        if item.hasPlaceholderTitle { return .placeholder }
        return .primary
    }

    /// The secondary line is assembled from whatever is actually present.
    private var secondaryParts: [String] {
        var parts: [String] = []
        if showsParent, let parentTitle = item.parentTitle, !parentTitle.isEmpty {
            parts.append(parentTitle)
        }
        let excerpt = item.excerpt
        if !excerpt.isEmpty {
            parts.append(excerpt)
        }
        return parts
    }

    private var secondaryLine: some View {
        HStack(spacing: Theme.Spacing.tight) {
            if showsParent, let parentTitle = item.parentTitle, !parentTitle.isEmpty {
                Text(parentTitle)
                    .rowForeground(.tertiary)
                Text("·").rowForeground(.tertiary)
            }

            Text(item.excerpt)
                .rowForeground(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(Theme.Text.rowSubtitle)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trailingAccessories: some View {
        HStack(spacing: Theme.Spacing.small) {
            if !item.tagSlugs.isEmpty {
                TagChipRow(slugs: item.tagSlugs, limit: 2)
            }

            if let symbol = item.priority.symbolName, item.isActionable {
                Image(systemName: symbol)
                    .font(Theme.Text.metadata)
                    .rowTint(Theme.Colors.overdue)
                    .accessibilityHidden(true)
            }

            if let dueAt = item.dueAt {
                DueDateLabel(date: dueAt, dateProvider: dateProvider, isActionable: item.isActionable)
            }
        }
    }
}

// MARK: - Due date

/// A due date, coloured by urgency.
///
/// Urgency is only shown for work that is still actionable — a completed task's late due date
/// is history, not a problem, and colouring it red would be nagging about something already
/// dealt with.
public struct DueDateLabel: View {
    private let date: Date
    private let dateProvider: any DateProvider
    private let isActionable: Bool

    public init(date: Date, dateProvider: any DateProvider, isActionable: Bool = true) {
        self.date = date
        self.dateProvider = dateProvider
        self.isActionable = isActionable
    }

    public var body: some View {
        Text(relativeText)
            .font(Theme.Text.metadata)
            .rowTint(color)
            .monospacedDigit()
            .accessibilityHidden(true)
    }

    private var relativeText: String {
        if dateProvider.isToday(date) { return "Today" }
        if dateProvider.calendar.isDate(date, inSameDayAs: dateProvider.startOfDay(daysFromToday: 1)) {
            return "Tomorrow"
        }
        if dateProvider.calendar.isDate(date, inSameDayAs: dateProvider.startOfDay(daysFromToday: -1)) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private var color: Color {
        guard isActionable else { return Theme.Colors.tertiaryText }
        if dateProvider.isOverdue(date) { return Theme.Colors.overdue }
        if dateProvider.isToday(date) { return Theme.Colors.dueToday }
        return Theme.Colors.secondaryText
    }
}

// MARK: - Tag chips

/// A single tag.
public struct TagChip: View {
    /// `.increased` inside a selected, focused list row. See ``Theme/Emphasis``.
    @Environment(\.backgroundProminence) private var prominence

    private let slug: String
    private let colorName: String?
    private let isSelected: Bool

    public init(slug: String, colorName: String? = nil, isSelected: Bool = false) {
        self.slug = slug
        self.colorName = colorName
        self.isSelected = isSelected
    }

    public var body: some View {
        Text(displayName)
            .font(Theme.Text.chip)
            .foregroundStyle(foreground)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(background)
            )
            .accessibilityLabel("Tag \(displayName)")
    }

    /// On a selected row the tag's own colour is dropped for the selected-content colour: a tinted
    /// pill on top of the accent fill is a colour clash *and* unreadable, and which tag it is matters
    /// more than which colour the user gave it.
    private var foreground: AnyShapeStyle {
        if prominence == .increased { return AnyShapeStyle(.primary) }
        return AnyShapeStyle(isSelected ? Color.white : tint)
    }

    private var background: AnyShapeStyle {
        if prominence == .increased { return AnyShapeStyle(.quaternary) }
        return AnyShapeStyle(isSelected ? tint : tint.opacity(0.14))
    }

    /// Hierarchical tags show only their leaf in a chip; the full path is available in the
    /// sidebar and the inspector, where there is room for it.
    private var displayName: String {
        TextNormalizer.slugComponents(slug).last ?? slug
    }

    private var tint: Color {
        colorName == nil ? Theme.Colors.secondaryText : Theme.Palette.color(named: colorName)
    }
}

/// A row of tag chips, overflowing into a count.
///
/// Truncating with "+2" rather than wrapping keeps a list row exactly one line tall, which is
/// what makes a long list scannable.
public struct TagChipRow: View {
    private let slugs: [String]
    private let limit: Int

    public init(slugs: [String], limit: Int = 3) {
        self.slugs = slugs
        self.limit = limit
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            ForEach(slugs.prefix(limit), id: \.self) { slug in
                TagChip(slug: slug)
            }

            if slugs.count > limit {
                Text("+\(slugs.count - limit)")
                    .font(Theme.Text.chip)
                    .rowForeground(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tagged \(slugs.joined(separator: ", "))")
    }
}

// MARK: - Empty state

/// What a view shows when it has nothing to show.
///
/// Empty states are a feature here, not an afterthought: an empty Inbox is the *goal*, and it
/// should read as an accomplishment rather than as a broken screen. Each one gets a headline
/// that says what the emptiness means, and at most one action.
public struct EmptyStateView: View {
    public enum Tone {
        /// Nothing here yet, and that is fine.
        case neutral
        /// Nothing here, and that is good — an empty Inbox.
        case accomplished
        /// Nothing matched, which may be a surprise.
        case noResults
    }

    private let symbolName: String
    private let headline: String
    private let message: String?
    private let tone: Tone
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        symbolName: String,
        headline: String,
        message: String? = nil,
        tone: Tone = .neutral,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.symbolName = symbolName
        self.headline = headline
        self.message = message
        self.tone = tone
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: symbolName)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(symbolColor)
                .accessibilityHidden(true)

            VStack(spacing: Theme.Spacing.tight) {
                Text(headline)
                    .font(.system(.headline, design: .default, weight: .medium))
                    .foregroundStyle(Theme.Colors.primaryText)

                if let message {
                    Text(message)
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderless)
                    .padding(.top, Theme.Spacing.tight)
            }
        }
        .padding(Theme.Spacing.generous)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(AccessibilityID.ItemList.emptyState)
    }

    private var symbolColor: Color {
        switch tone {
        case .neutral, .noResults: Theme.Colors.tertiaryText
        case .accomplished: Theme.Colors.completed
        }
    }
}

// MARK: - Section header

/// A small uppercase label above a group.
public struct SectionHeader: View {
    private let title: String
    private let count: Int?

    public init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Text(title.uppercased())
                .font(Theme.Text.sectionHeader)
                .foregroundStyle(Theme.Colors.secondaryText)
                .kerning(0.4)

            if let count, count > 0 {
                Text("\(count)")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .monospacedDigit()
            }

            Spacer()
        }
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(count == nil ? title : "\(title), \(count ?? 0) items")
    }
}

// MARK: - Keyboard hint

/// A rendered keyboard shortcut, for the command palette and help rows.
public struct KeyHint: View {
    private let keys: [String]

    public init(_ keys: String...) {
        self.keys = keys
    }

    public init(keys: [String]) {
        self.keys = keys
    }

    public var body: some View {
        HStack(spacing: 1) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(Theme.Text.keyHint)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(minWidth: 14)
                    .padding(.horizontal, Theme.Spacing.tight)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Theme.Colors.subtleFill)
                    )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Shortcut \(keys.joined(separator: " "))")
    }
}

// MARK: - Inspector

/// A labelled row in the inspector.
///
/// Adapts rather than clips. Above ``InspectorLayout/stackingBreakpoint`` the label sits in a fixed
/// column so every value starts at the same x position, which is what lets the eye scan an inspector
/// rather than read it. Below it, the label moves above the control and the control takes the full
/// width — because a taller row is better than a squeezed control, and far better than a clipped one.
public struct InspectorRow<Content: View>: View {
    @Environment(\.inspectorLayoutStyle) private var style

    private let label: String
    private let content: Content

    public init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    public var body: some View {
        Group {
            switch style {
            case .inline:
                HStack(alignment: .firstTextBaseline, spacing: InspectorLayout.labelGap) {
                    labelText
                        .frame(width: InspectorLayout.labelColumnWidth, alignment: .trailing)

                    content
                        .font(Theme.Text.rowSubtitle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

            case .stacked:
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    labelText

                    content
                        .font(Theme.Text.rowSubtitle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var labelText: some View {
        Text(style == .stacked ? label.uppercased() : label)
            .font(style == .stacked ? Theme.Text.sectionHeader : Theme.Text.metadata)
            .kerning(style == .stacked ? 0.4 : 0)
            .foregroundStyle(Theme.Colors.secondaryText)
            .lineLimit(1)
    }
}

/// A titled group of inspector rows.
public struct InspectorSection<Content: View>: View {
    private let title: String
    private let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionHeader(title)
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                content
            }
        }
    }
}

// MARK: - Failure state

/// The full-window state shown when the app cannot proceed — a store that will not open, a
/// migration that failed.
///
/// It always offers the error's own recovery options, so it is never a dead end. `AppError`
/// defines those options, rather than each call site inventing them.
public struct FailureStateView: View {
    private let error: AppError
    private let onRecover: (RecoveryOption) -> Void

    public init(error: AppError, onRecover: @escaping (RecoveryOption) -> Void) {
        self.error = error
        self.onRecover = onRecover
    }

    public var body: some View {
        VStack(spacing: Theme.Spacing.large) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.Colors.dueToday)
                .accessibilityHidden(true)

            VStack(spacing: Theme.Spacing.small) {
                Text(error.errorDescription ?? "Something went wrong.")
                    .font(.system(.title3, design: .default, weight: .medium))
                    .multilineTextAlignment(.center)

                if let reason = error.failureReason {
                    Text(reason)
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 460)
            .accessibilityIdentifier(AccessibilityID.Failure.message)

            HStack(spacing: Theme.Spacing.small) {
                ForEach(Array(error.recovery.enumerated()), id: \.element) { index, option in
                    Button(option.title) { onRecover(option) }
                        .keyboardShortcut(index == 0 ? .defaultAction : nil)
                        .buttonStyle(index == 0 ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
                        .accessibilityIdentifier(AccessibilityID.Failure.recoveryButton(option))
                }
            }
        }
        .padding(Theme.Spacing.generous)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.windowBackground)
        .accessibilityIdentifier(AccessibilityID.Failure.root)
    }
}

/// Type-erases a button style so the primary and secondary cases can be chosen at runtime.
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let makeBody: (Configuration) -> AnyView

    init<Style: PrimitiveButtonStyle>(_ style: Style) {
        makeBody = { configuration in
            AnyView(Button(configuration).buttonStyle(style))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        makeBody(configuration)
    }
}
