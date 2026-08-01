import SwiftUI

/// The design system's vocabulary.
///
/// Every spacing value, corner radius, and colour in the app comes from here. Not because
/// tokens are fashionable, but because "high information density without feeling crowded"
/// is achievable only if the *same* rhythm is used everywhere, and that is impossible when
/// each view invents its own numbers.
public enum Theme {}

// MARK: - Spacing

extension Theme {
    /// A four-point scale.
    ///
    /// Four, not eight, because this app is dense: an eight-point grid forces either wasted
    /// space in list rows or off-grid exceptions, and exceptions defeat the purpose.
    public enum Spacing {
        /// 2 pt — between a glyph and its label.
        public static let hairline: CGFloat = 2
        /// 4 pt — within a tightly-coupled pair.
        public static let tight: CGFloat = 4
        /// 8 pt — the default gap between related elements.
        public static let small: CGFloat = 8
        /// 12 pt — between elements in a row.
        public static let medium: CGFloat = 12
        /// 16 pt — standard content inset.
        public static let large: CGFloat = 16
        /// 24 pt — between sections.
        public static let section: CGFloat = 24
        /// 40 pt — around empty states, which need room to feel calm rather than broken.
        public static let generous: CGFloat = 40
    }

    public enum Radius {
        /// 4 pt — chips and small controls.
        public static let small: CGFloat = 4
        /// 6 pt — rows and fields.
        public static let medium: CGFloat = 6
        /// 10 pt — cards and popovers.
        public static let large: CGFloat = 10
    }

    public enum Size {
        /// The leading glyph column in a list row. Fixed, so titles align down the list even
        /// when their symbols differ in width.
        ///
        /// Twenty, not sixteen. A fixed frame narrower than the glyph inside it does not shrink the
        /// glyph — it centres it and lets it hang over both edges, where the row's own bounds cut it
        /// off. At sixteen the narrow symbols were fine and the wide ones were not: the speech
        /// bubbles on an interaction and the calendar on an event both lost a slice of their left
        /// side, and only in the modules that use them, which is why it read as those icons being
        /// broken rather than as the column being too narrow.
        ///
        /// Twenty clears the widest symbol the row vocabulary uses at the body text size.
        public static let rowGlyph: CGFloat = 20

        /// Minimum height of a list row. Comfortable to click without being airy.
        public static let rowHeight: CGFloat = 28

        /// Minimum height of a two-line list row.
        public static let rowHeightExpanded: CGFloat = 44

        public static let sidebarMinWidth: CGFloat = 190
        public static let sidebarIdealWidth: CGFloat = 224
        public static let sidebarMaxWidth: CGFloat = 320

        /// What to assume a window is before it has been measured.
        ///
        /// The size the app opens at — see `ElephruitApp`'s `.defaultSize`. A window of no width
        /// holds no columns, so assuming zero for one frame drops the editor and then puts it back.
        public static let assumedWindowWidth: CGFloat = 1180

        public static let listMinWidth: CGFloat = 260
        public static let listIdealWidth: CGFloat = 340

        public static let detailMinWidth: CGFloat = 420
        public static let inspectorWidth: CGFloat = 280

        /// The editor's measure. Long lines are hard to read; this caps them at roughly 80
        /// characters at the default size while leaving the window free to be any width.
        public static let editorMaxWidth: CGFloat = 720
    }
}

// MARK: - Typography

extension Theme {
    /// Text styles, all relative to the user's chosen size.
    ///
    /// Every style is built from a `Font.TextStyle`, never from a point size, so Dynamic Type
    /// and the system text-size setting are respected without special cases.
    public enum Text {
        /// A note or item title in the detail view.
        public static let title: Font = .system(.title2, design: .default, weight: .semibold)

        /// A section header in a sidebar or inspector.
        public static let sectionHeader: Font = .system(.caption, design: .default, weight: .semibold)

        /// A list row's primary line.
        public static let rowTitle: Font = .system(.body)

        /// A list row's primary line, when the item is unread or pinned.
        public static let rowTitleEmphasised: Font = .system(.body, design: .default, weight: .medium)

        /// A list row's secondary line.
        public static let rowSubtitle: Font = .system(.callout)

        /// Metadata: dates, counts, provenance.
        public static let metadata: Font = .system(.caption)

        /// A tag chip.
        public static let chip: Font = .system(.caption, design: .default, weight: .medium)

        /// A keyboard shortcut hint.
        public static let keyHint: Font = .system(.caption2, design: .rounded, weight: .medium)

        /// The note body editor.
        ///
        /// Proportional by default, because most notes are prose. The editor offers a
        /// monospaced alternative for those who prefer it; the choice is a preference, not a
        /// hard-coded assumption about what the user writes.
        public static let editorBody: Font = .system(.body)
        public static let editorBodyMonospaced: Font = .system(.body, design: .monospaced)
    }
}

// MARK: - Colour

extension Theme {
    /// Semantic colours.
    ///
    /// Built from the system's own semantic colours wherever one exists, so light mode, dark
    /// mode, Increase Contrast, and the user's accent colour are all handled by AppKit rather
    /// than approximated here. A hard-coded hex value would be wrong in at least one of those
    /// four conditions.
    public enum Colors {
        /// Primary reading text.
        public static let primaryText = Color.primary
        /// Supporting text: subtitles, metadata.
        public static let secondaryText = Color.secondary
        /// Text that is present but not currently relevant.
        public static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
        /// Placeholder text in an empty field or an untitled item.
        public static let placeholderText = Color(nsColor: .placeholderTextColor)

        /// The window's own background. Sidebars use a material instead.
        public static let windowBackground = Color(nsColor: .windowBackgroundColor)
        /// The background of a content list or editor.
        public static let contentBackground = Color(nsColor: .textBackgroundColor)
        /// A subtle fill for chips and grouped rows.
        public static let subtleFill = Color(nsColor: .quaternarySystemFill)
        /// A separator hairline.
        public static let separator = Color(nsColor: .separatorColor)

        /// Selection. Follows the user's accent colour.
        public static let selection = Color.accentColor

        /// The fill under whatever the pointer is over.
        ///
        /// Deliberately *not* ``selection``. Hover answers "what would I hit if I clicked here";
        /// selection answers "what am I looking at". Drawing hover in the accent colour conflates
        /// the two, so a pointer crossing a list leaves a wake of things that look chosen.
        ///
        /// `quaternarySystemFill` is AppKit's own token for exactly this — a small area tinted
        /// enough to be noticed and not enough to be read as state — and it resolves correctly in
        /// dark mode and under Increase Contrast, where a fixed grey would not.
        public static let hoverFill = Color(nsColor: .quaternarySystemFill)

        /// Something needs attention now — an overdue date.
        public static let overdue = Color(nsColor: .systemRed)
        /// Something needs attention today.
        public static let dueToday = Color(nsColor: .systemOrange)
        /// Completed.
        public static let completed = Color(nsColor: .systemGreen)
        /// A link that points at something.
        public static let link = Color.accentColor
        /// A link whose target does not exist yet.
        public static let unresolvedLink = Color(nsColor: .systemOrange)
        /// A destructive action.
        public static let destructive = Color(nsColor: .systemRed)

        /// Something the app could not interpret and has told the user about.
        ///
        /// Amber rather than red: an unreadable fragment of a search query is not a failure, it is
        /// a part of the request that was skipped. Red would overstate it.
        public static let warning = Color(nsColor: .systemOrange)

        /// A detail that belongs to somebody's private life — a home address, a personal email.
        ///
        /// Teal rather than green, which already means *completed*, and rather than blue, which is
        /// the default accent and so would be indistinguishable from selection on half the screen.
        public static let personalDetail = Color(nsColor: .systemTeal)

        /// Text or a glyph drawn on top of a filled, saturated swatch.
        ///
        /// Not `Color.white`, which is what this replaces in four places. White is legible on a
        /// saturated fill and wrong everywhere the fill is not saturated — under Increase Contrast,
        /// where AppKit lightens some fills, and on the pale end of an intensity scale, where white
        /// on near-white is invisible. `alternateSelectedControlTextColor` is AppKit's own token for
        /// exactly this question and answers it per appearance.
        public static let onAccent = Color(nsColor: .alternateSelectedControlTextColor)

        /// The accent for the capture surfaces — Quick Jot and the person capture sheets.
        ///
        /// Named rather than spelled `Color.purple` at nine call sites. The literal adapts between
        /// light and dark, so this is not a bug being fixed; it is nine independent decisions
        /// becoming one, so that changing the colour of capture is an edit rather than a search.
        public static let captureAccent = Color(nsColor: .systemPurple)

        /// The accent for a child's evolving details on a parent's profile.
        ///
        /// Distinct from ``personalDetail`` on purpose: a child's facts are the one part of a
        /// profile that is deliberately local to this app and never written to the address book, and
        /// the tint is part of how that reads as its own thing.
        public static let familyAccent = Color(nsColor: .systemPink)

        /// A detail that belongs to somebody's working life.
        ///
        /// Never the only signal that something is work: every place this appears also carries the
        /// word and a symbol, because roughly one man in twelve cannot use the colour.
        public static let workDetail = Color(nsColor: .systemIndigo)
    }

    /// The palette a user may pick from for projects, areas, tags, and collections.
    ///
    /// Named rather than stored as raw values, so a stored `colorName` renders correctly in
    /// every appearance and can be re-tuned later without a data migration. An unknown name
    /// resolves to the accent colour rather than failing.
    public enum Palette: String, CaseIterable, Sendable {
        case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, graphite

        public var color: Color {
            switch self {
            case .red: Color(nsColor: .systemRed)
            case .orange: Color(nsColor: .systemOrange)
            case .yellow: Color(nsColor: .systemYellow)
            case .green: Color(nsColor: .systemGreen)
            case .mint: Color(nsColor: .systemMint)
            case .teal: Color(nsColor: .systemTeal)
            case .cyan: Color(nsColor: .systemCyan)
            case .blue: Color(nsColor: .systemBlue)
            case .indigo: Color(nsColor: .systemIndigo)
            case .purple: Color(nsColor: .systemPurple)
            case .pink: Color(nsColor: .systemPink)
            case .brown: Color(nsColor: .systemBrown)
            case .graphite: Color(nsColor: .systemGray)
            }
        }

        public var displayName: String {
            rawValue.capitalized
        }

        /// Resolves a stored name, falling back to the accent colour.
        public static func color(named name: String?) -> Color {
            guard let name, let entry = Palette(rawValue: name) else { return Color.accentColor }
            return entry.color
        }
    }
}

// MARK: - Selection

extension Theme {
    /// How much a piece of text in a row matters, relative to the rest of that row.
    ///
    /// ### Why a row cannot simply name its colour
    /// A `List` row that is selected and focused paints the accent colour behind itself and sets the
    /// foreground style to the *selected content* colour — white — so that unstyled text stays
    /// legible. Naming a colour outright opts out of that: `Color.primary` is `labelColor`, which is
    /// near-black in light mode and stays near-black on top of the blue fill. That is the dark-on-blue
    /// row this type exists to prevent.
    ///
    /// The hierarchical styles — `.primary`, `.secondary`, `.tertiary` — are defined *relative to*
    /// whatever foreground style is in force, so they follow the selection automatically. They are
    /// also slightly less precise than the semantic label colours when nothing is selected, which is
    /// why both are kept and the choice is made per render.
    public enum Emphasis: Sendable, Hashable, CaseIterable {
        /// The row's own title.
        case primary
        /// A subtitle or a piece of metadata.
        case secondary
        /// Present but not currently relevant.
        case tertiary
        /// A title the user has not written yet.
        case placeholder

        /// The fixed colour to use, or `nil` when the system's own selected-content colour must win.
        ///
        /// Pure, so ``Emphasis`` can be asserted in a test rather than reviewed in a screenshot —
        /// which matters here more than usual, because the failure is invisible until somebody
        /// selects a row with the window focused.
        public func color(prominence: BackgroundProminence) -> Color? {
            guard prominence != .increased else { return nil }

            switch self {
            case .primary: return Theme.Colors.primaryText
            case .secondary: return Theme.Colors.secondaryText
            case .tertiary: return Theme.Colors.tertiaryText
            case .placeholder: return Theme.Colors.placeholderText
            }
        }

        /// The relative style used on a selected row, where the colour above would be wrong.
        fileprivate var hierarchicalStyle: AnyShapeStyle {
            switch self {
            case .primary: AnyShapeStyle(.primary)
            case .secondary: AnyShapeStyle(.secondary)
            case .tertiary, .placeholder: AnyShapeStyle(.tertiary)
            }
        }
    }
}

extension View {
    /// Colours text inside a list row so that selecting the row keeps it readable.
    ///
    /// Use this instead of `.foregroundStyle(Theme.Colors.…)` for anything that can appear inside a
    /// `List` row. Everywhere else — headers, detail panes, sheets — the tokens are correct as they
    /// are, because nothing paints an accent colour behind them.
    public func rowForeground(_ emphasis: Theme.Emphasis) -> some View {
        modifier(RowForegroundModifier(emphasis: emphasis))
    }

    /// Colours something whose colour carries meaning — an overdue date, a project's tint — and lets
    /// that meaning yield on a selected row.
    ///
    /// The colour is dropped rather than darkened when the row is selected, because red-on-blue is
    /// unreadable and a selected row is a transient state the user is looking straight at. What the
    /// colour *meant* is still carried by the symbol and the words beside it.
    public func rowTint(_ color: Color) -> some View {
        modifier(RowTintModifier(color: color))
    }
}

private struct RowForegroundModifier: ViewModifier {
    @Environment(\.backgroundProminence) private var prominence

    let emphasis: Theme.Emphasis

    func body(content: Content) -> some View {
        if let color = emphasis.color(prominence: prominence) {
            content.foregroundStyle(color)
        } else {
            content.foregroundStyle(emphasis.hierarchicalStyle)
        }
    }
}

private struct RowTintModifier: ViewModifier {
    @Environment(\.backgroundProminence) private var prominence

    let color: Color

    func body(content: Content) -> some View {
        if prominence == .increased {
            content.foregroundStyle(.primary)
        } else {
            content.foregroundStyle(color)
        }
    }
}

// MARK: - Motion

extension Theme {
    /// Animation, with Reduce Motion honoured in one place.
    ///
    /// Every animation in the app goes through these helpers. That is the only way to keep the
    /// accessibility promise: a single view animating directly would break it, and nothing
    /// would catch that in review.
    public enum Motion {
        /// A state change the user initiated and is watching — a disclosure, a selection.
        public static let standard: Animation = .easeOut(duration: 0.18)

        /// Something appearing or disappearing.
        public static let appearance: Animation = .easeOut(duration: 0.14)

        /// A list reordering or an item moving between sections.
        public static let reorder: Animation = .spring(response: 0.3, dampingFraction: 0.85)

        /// The animation to use, or `nil` when Reduce Motion is on.
        ///
        /// Returning `nil` rather than a zero duration matters: SwiftUI treats a `nil`
        /// animation as "apply the change immediately", which is exactly what the setting asks
        /// for, whereas a zero-duration animation still runs a transaction.
        public static func respectingReduceMotion(
            _ animation: Animation,
            reduceMotion: Bool
        ) -> Animation? {
            reduceMotion ? nil : animation
        }
    }
}

// MARK: - Environment

extension EnvironmentValues {
    /// Whether the user prefers a monospaced editor.
    ///
    /// In the environment rather than read from `UserDefaults` inside the editor, so previews
    /// can show both and tests need no defaults suite.
    @Entry public var prefersMonospacedEditor: Bool = false
}

extension View {
    /// Applies an animation unless Reduce Motion is on.
    ///
    /// Reads the accessibility setting itself, so no call site has to remember to.
    public func calmAnimation<Value: Equatable>(
        _ animation: Animation = Theme.Motion.standard,
        value: Value
    ) -> some View {
        modifier(CalmAnimationModifier(animation: animation, value: value))
    }
}

private struct CalmAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(
            Theme.Motion.respectingReduceMotion(animation, reduceMotion: reduceMotion),
            value: value
        )
    }
}
