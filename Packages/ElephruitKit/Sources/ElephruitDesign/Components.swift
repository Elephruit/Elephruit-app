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

            // ### Why the metadata is stacked rather than strung out beside the title
            // It used to sit on the title's own line — tags, then a priority mark, then a date — and
            // between them they took a fixed 150-odd points off a column that is about 330 wide in
            // practice. The title got what was left, which is why a list of notes read "A note with
            // a title lo…", "Migration runb…", "Positionin…". The thing the row exists to identify
            // was the thing with no room.
            //
            // Widening the column was tried first and is the better fix in principle; AppKit's split
            // view does not reliably grant the middle column the width the shell asks for, and that
            // is recorded as remaining work rather than papered over here.
            //
            // What is within this view's gift is what it spends the width *on*. Only two things now
            // share the title's line: the title, and the one date — which is short, fixed, and the
            // field a person scans a list by. Everything else drops to the second line, which had
            // room to spare and now carries the tags at its trailing edge, under the date, so the
            // right-hand edge reads as one column of metadata rather than two ragged ones.
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    titleLine
                    Spacer(minLength: Theme.Spacing.small)
                    titleLineAccessories
                }

                if hasSecondLine {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                        if !secondaryParts.isEmpty {
                            secondaryLine
                        }
                        Spacer(minLength: Theme.Spacing.small)
                        if !item.tagSlugs.isEmpty {
                            TagChipRow(slugs: item.tagSlugs, limit: 2)
                                .layoutPriority(1)
                        }
                    }
                }
            }
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
        Theme.Palette.color(named: item.colorName, neutral: Theme.Colors.secondaryText)
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
                    .rowTint(Theme.Colors.favorite)
                    .accessibilityHidden(true)
            }
        }
    }

    private var titleEmphasis: Theme.Emphasis {
        if item.isCompleted { return .secondary }
        if item.hasPlaceholderTitle { return .placeholder }
        return .primary
    }

    /// The parent's title, when there is one worth showing.
    private var parentTitle: String? {
        guard showsParent, let title = item.parentTitle, !title.isEmpty else { return nil }
        return title
    }

    /// The body excerpt, when there is one.
    private var excerpt: String? {
        let text = item.excerpt
        return text.isEmpty ? nil : text
    }

    /// The secondary line is assembled from whatever is actually present.
    private var secondaryParts: [String] {
        [parentTitle, excerpt].compactMap { $0 }
    }

    /// Renders the parts that exist, with a separator only *between* two of them.
    ///
    /// The separator used to be drawn whenever there was a parent, which left a row whose parent is
    /// known and whose body is empty reading "Planning ·" — a dangling conjunction promising a
    /// second clause that never arrives. It is visible on every untitled or bodyless item in the
    /// app, so the rule is now stated once: a separator is a thing that goes between two things.
    private var secondaryLine: some View {
        HStack(spacing: Theme.Spacing.tight) {
            if let parentTitle {
                Text(parentTitle)
                    .rowForeground(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(excerpt == nil ? 1 : 0)

                if excerpt != nil {
                    Text(verbatim: "·").rowForeground(.tertiary)
                }
            }

            if let excerpt {
                Text(excerpt)
                    .rowForeground(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(Theme.Text.rowSubtitle)
        .accessibilityHidden(true)
    }

    /// Tags, priority and a due date, kept whole.
    ///
    /// `layoutPriority(1)` states the order things give way in: a title has somewhere to go when it
    /// runs out of room — the ellipsis — and a date does not. Without it SwiftUI divides the
    /// shortfall between them and compresses both, which is how "Yesterday" became three stacked
    /// syllables in a narrow column.
    /// Whether there is a second line to draw at all.
    ///
    /// A row with a bare title and no tags stays one line tall, which is what keeps a dense list
    /// dense. Nothing is reserved for something that might be there.
    private var hasSecondLine: Bool {
        !secondaryParts.isEmpty || !item.tagSlugs.isEmpty
    }

    /// What shares the title's line: the priority mark and the one date, and nothing else.
    ///
    /// `layoutPriority(1)` states the order things give way in: a title has somewhere to put the
    /// shortfall — the ellipsis — and a date does not. Without it SwiftUI divides the shortfall
    /// between them and compresses both, which is how "Yesterday" became three stacked syllables in
    /// a narrow column.
    @ViewBuilder
    private var titleLineAccessories: some View {
        HStack(spacing: Theme.Spacing.small) {
            if let symbol = item.priority.symbolName, item.isActionable {
                Image(systemName: symbol)
                    .font(Theme.Text.metadata)
                    .rowTint(Theme.Colors.overdue)
                    .accessibilityHidden(true)
            }

            if let rowDate = RowDate.resolve(for: item) {
                RowDateLabel(
                    resolved: rowDate,
                    dateProvider: dateProvider,
                    isActionable: item.isActionable
                )
            }
        }
        .layoutPriority(1)
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
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHidden(true)
    }

    private var relativeText: String {
        RelativeDay.text(for: date, using: dateProvider)
    }

    private var color: Color {
        guard isActionable else { return Theme.Colors.tertiaryText }
        return DateUrgency.color(for: date, using: dateProvider)
    }
}

/// The urgency ramp every dated element shares: overdue red, due-today amber, else quiet.
///
/// One function rather than the same three-line ladder pasted beside each label that draws a date,
/// which is how the two copies in this file had already started life. Callers apply their own
/// guards about *whether* urgency applies — a date that is merely past is not late — and this
/// answers only what urgency looks like.
public enum DateUrgency {
    public static func color(for date: Date, using dateProvider: any DateProvider) -> Color {
        if dateProvider.isOverdue(date) { return Theme.Colors.overdue }
        if dateProvider.isToday(date) { return Theme.Colors.dueToday }
        return Theme.Colors.secondaryText
    }
}

/// How a day is written in a list row.
///
/// Shared rather than duplicated, because two labels formatting the same day two ways is how a list
/// ends up saying "Yesterday" in one column and "31 Jul" in another about the same afternoon.
public enum RelativeDay {
    public static func text(for date: Date, using dateProvider: any DateProvider) -> String {
        if dateProvider.isToday(date) { return "Today" }
        if dateProvider.calendar.isDate(date, inSameDayAs: dateProvider.startOfDay(daysFromToday: 1)) {
            return "Tomorrow"
        }
        if dateProvider.calendar.isDate(date, inSameDayAs: dateProvider.startOfDay(daysFromToday: -1)) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// The one date on a list row, whatever that date turns out to mean.
///
/// See ``RowDate`` for the rule about which date is shown. This draws it: a deadline in the urgency
/// colours, anything else quietly and with the word that says what it is.
public struct RowDateLabel: View {
    private let resolved: RowDate.Resolved
    private let dateProvider: any DateProvider
    private let isActionable: Bool

    public init(
        resolved: RowDate.Resolved,
        dateProvider: any DateProvider,
        isActionable: Bool = true
    ) {
        self.resolved = resolved
        self.dateProvider = dateProvider
        self.isActionable = isActionable
    }

    public var body: some View {
        Text(text)
            .font(Theme.Text.metadata)
            .rowTint(color)
            .monospacedDigit()
            .lineLimit(1)
            // Kept whole. A date has nowhere to put an ellipsis, which is why the trailing cluster
            // carries the layout priority and the title is the thing that truncates.
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHidden(true)
    }

    private var text: String {
        let day = RelativeDay.text(for: resolved.date, using: dateProvider)
        guard let prefix = resolved.role.prefix else { return day }
        return "\(prefix) \(day)"
    }

    /// Urgency for a deadline; a quiet grey for everything else.
    ///
    /// A date that is merely *past* is not late. "Edited Yesterday" in red would be the interface
    /// inventing an obligation nobody made, and it is the mistake a single shared colour rule for
    /// every date in a row would produce.
    private var color: Color {
        guard resolved.role.showsUrgency, isActionable else { return Theme.Colors.tertiaryText }
        return DateUrgency.color(for: resolved.date, using: dateProvider)
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
            // A chip is a label, not a paragraph. Without this it is a text view like any other, and
            // a narrow list column compresses it one character at a time until "urgent" is six rows
            // of one letter — which is what a list row looked like below about 200 points.
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .font(Theme.Text.chip)
            .foregroundStyle(foreground)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.hairline)
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
        return AnyShapeStyle(isSelected ? Theme.Colors.onAccent : tint)
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
        Theme.Palette.color(named: colorName, neutral: Theme.Colors.secondaryText)
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
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tagged \(slugs.joined(separator: ", "))")
    }
}

// MARK: - Hover

extension View {
    /// Draws a quiet fill under this view while the pointer is over it.
    ///
    /// ### Why the app draws this rather than the system
    /// macOS hover-highlights toolbar buttons and menu items for free, but not the rows of a
    /// `List` — a sidebar row and a person in the middle column give no feedback at all until
    /// they are clicked. On a dense list that is the difference between "which of these am I
    /// about to open" and a guess.
    ///
    /// ### On pairing it with `.help`
    /// A highlight says *this is the thing under the pointer*; it does not say what the thing is.
    /// Every surface that takes this modifier also carries a `.help` string, so hovering first
    /// shows which row is live and then, after the system's own tooltip delay, what it holds.
    /// The delay is the system's on purpose: it is a setting the user may have changed, and a
    /// bespoke timer would ignore that and would not reach VoiceOver either.
    ///
    /// - Parameters:
    ///   - isEnabled: Pass `false` for a row that is already selected. The selection fill and the
    ///     hover fill on the same row read as neither.
    ///   - cornerRadius: Matches the surrounding selection treatment.
    ///   - extending: How far past the content the fill reaches horizontally. List rows lay their
    ///     content out inside the list's own inset, so a fill drawn flush to the text hugs it.
    public func hoverHighlight(
        isEnabled: Bool = true,
        cornerRadius: CGFloat = Theme.Radius.medium,
        extending: CGFloat = 0
    ) -> some View {
        modifier(
            HoverHighlightModifier(
                isEnabled: isEnabled,
                cornerRadius: cornerRadius,
                extending: extending
            )
        )
    }
}

private struct HoverHighlightModifier: ViewModifier {
    let isEnabled: Bool
    let cornerRadius: CGFloat
    let extending: CGFloat

    @State private var isHovering = false

    /// Keyboard focus, from the nearest focusable ancestor. The highlight answers "what would I
    /// hit if I acted here", and Tab asks that question as legitimately as the pointer does —
    /// without this, keyboard users got no fill where mouse users got one.
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.Colors.hoverFill)
                    .padding(.horizontal, -extending)
                    .opacity(isVisible ? 1 : 0)
            }
            // So the gaps between a glyph, a label, and a trailing count are part of the same
            // target. Without it the highlight flickers as the pointer crosses the spacing.
            .contentShape(.rect)
            .onHover { isHovering = $0 }
            .calmAnimation(Theme.Motion.appearance, value: isVisible)
    }

    /// Selection wins. A row cannot usefully be both the thing you are looking at and the thing
    /// you might click next.
    private var isVisible: Bool { isEnabled && (isHovering || isFocused) }
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
                .font(Theme.Text.heroGlyph)
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

            // ### Why this is a real button
            // It used to be `.borderless`, which on macOS is accent-coloured text and nothing else:
            // no border, no hover, no pressed state, and a hit target the width of the words. On a
            // screen that is otherwise empty, the one thing there is to do was drawn as a caption —
            // "Ask Again" under a padlock, "Add Time…" under a stopwatch — and it was not obvious
            // that either could be clicked at all.
            //
            // An empty state's action is its primary action by construction: there is nothing else
            // on the screen to compete with. So it is the prominent style, at the large control
            // size, and it is the default button, which makes Return do the obvious thing for
            // somebody who arrived here without a mouse.
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
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
                    .padding(.vertical, Theme.Spacing.hairline)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
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
                .font(Theme.Text.heroGlyph)
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
