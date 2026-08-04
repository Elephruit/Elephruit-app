import AppKit
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
    /// An eight-point grid with a four-point half-step.
    ///
    /// Eight is the default gap; four is the sanctioned half-step for the inside of a row, where
    /// this app's density genuinely needs it; two exists only as the gap between a glyph and its
    /// own label. Nothing below two, and nothing off the scale: the 1- and 3-point micro-paddings
    /// that accumulated in the feature views were not density, they were drift, and
    /// `SourceHygieneTests` now refuses them.
    public enum Spacing {
        /// 2 pt — between a glyph and its label, and nowhere else.
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
        /// 32 pt — page-level insets on roomy surfaces.
        public static let extraLarge: CGFloat = 32
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
        /// 16 pt — sheets and floating panels.
        ///
        /// The fourth and final step. The 12s, 15s and 18s that grew in the Person views were
        /// four spellings of "bigger than a card", and this is the one answer.
        public static let sheet: CGFloat = 16
    }

    /// Depth, in four steps, each a named claim about what a surface is.
    ///
    /// Before this there were nine hand-built shadows using five radii and six opacities — no two
    /// alike, and none of them a decision anybody could point to. A shadow is now a statement of
    /// *what kind of thing this is*, and the same kind always sits at the same height.
    public enum Elevation: Sendable, Hashable {
        /// Rows, chips, inline cards: no shadow at all. Fills and borders do the separating.
        case flat
        /// A card resting on the content — kanban at rest, a stat tile.
        case raised
        /// Something floating over the content — a popover, the floating timer, a dragged card.
        case floating
        /// A panel floating over the whole desktop — Quick Jot, Quick Log.
        case panel

        var shadowOpacity: Double {
            switch self {
            case .flat: 0
            case .raised: 0.08
            case .floating: 0.16
            case .panel: 0.22
            }
        }

        var shadowRadius: CGFloat {
            switch self {
            case .flat: 0
            case .raised: 3
            case .floating: 10
            case .panel: 20
            }
        }

        var shadowY: CGFloat {
            switch self {
            case .flat: 0
            case .raised: 1
            case .floating: 4
            case .panel: 8
            }
        }
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

        /// The editor's measure. Long lines are hard to read; this caps them at roughly 80
        /// characters at the default size while leaving the window free to be any width.
        public static let editorMaxWidth: CGFloat = 720

        /// The measure of a project's Home page: a document, wider than prose because its plan
        /// rows carry controls and dates, but still a page you read rather than a surface that
        /// stretches to whatever the window happens to be.
        public static let projectHomeMaxWidth: CGFloat = 800

        /// The measure of a page built from columns of rows rather than from prose.
        ///
        /// Wider than ``editorMaxWidth`` because the constraint is different: a paragraph is capped
        /// so the eye does not have to travel back across it, and a day's plan has no paragraphs —
        /// it has a date rail, a time gutter, titles, and metadata that need room to sit on one line
        /// rather than wrap. Capped all the same, because a briefing stretched across an ultrawide
        /// display puts a metre of glass between "2 overdue" and the work it is about.
        ///
        /// Sized for the two-column arrangement a day takes when there is room for it: the schedule
        /// and the work on the left, the people and the note on the right. At 1080 the second column
        /// had nowhere to go and the page was a narrow strip with half a window of nothing beside it.
        public static let todayContentWidth: CGFloat = 1240

        /// The trailing column of a day — people, the day's note — when the window is wide enough to
        /// hold one.
        ///
        /// A person's card is a name, a role, why they are here and when you last spoke. Below about
        /// 280 those wrap into a paragraph; above about 360 the whitespace inside the card starts
        /// reading as an alignment mistake.
        public static let todaySideColumnWidth: CGFloat = 320

        /// The window width below which a day is one column.
        ///
        /// Derived rather than picked: the day needs its date rail, a schedule column wide enough
        /// that a meeting title and its context sit on one line, and the side column above — below
        /// that, two columns means two cramped ones.
        public static let todayTwoColumnMinimum: CGFloat = 860

        /// The three sizes a glyph-in-a-tinted-square comes in — see `IconTile`.
        ///
        /// Fifteen distinct squares existed for this one idea; these are the three that survive.
        /// Small sits inside a row, medium anchors a card or a picker, large is an identity.
        public static let iconTileSmall: CGFloat = 24
        public static let iconTileMedium: CGFloat = 32
        public static let iconTileLarge: CGFloat = 44
    }
}

extension View {
    /// Applies one of the four depths — the only way a shadow is drawn.
    ///
    /// A modifier rather than four call-site recipes, so that "how high is this" is a decision
    /// with a name, `SourceHygieneTests` can refuse a raw `.shadow(` anywhere else, and retuning
    /// a level is an edit rather than a search.
    public func elevation(_ level: Theme.Elevation) -> some View {
        shadow(
            color: Theme.Colors.shadow.opacity(level.shadowOpacity),
            radius: level.shadowRadius,
            y: level.shadowY
        )
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

        /// Letter spacing, for the two places it earns its keep.
        ///
        /// The system font is spaced for reading at body size. Large text set at that spacing looks
        /// slightly loose — tightening it is most of the difference between a title that looks set
        /// and one that looks typed. Small uppercase text has the opposite problem: capitals jam
        /// together and need opening up, which is why ``SectionHeader`` already kerns.
        ///
        /// Two values, not a scale. Anything more is a knob nobody can use consistently.
        public enum Tracking {
            /// Titles, set tighter.
            public static let title: CGFloat = -0.3
            /// Small uppercase labels, set looser.
            public static let caps: CGFloat = 0.4
        }

        /// A section header in a sidebar or inspector.
        public static let sectionHeader: Font = .system(.caption, design: .default, weight: .semibold)

        /// A list row's primary line.
        public static let rowTitle: Font = .system(.body)

        /// A list row's primary line, when the item is unread or pinned.
        public static let rowTitleEmphasised: Font = .system(.body, design: .default, weight: .medium)

        /// A list row's secondary line.
        ///
        /// `.subheadline`, not `.callout`. On macOS the text-style scale is compressed — body is 13
        /// points and callout is 12 — so a row's title and its subtitle were one point apart, and a
        /// difference of one point is not a hierarchy, it is a rounding error. A list of them reads
        /// as an undifferentiated block of grey text, which is most of why this app looked flat
        /// however carefully the rows were laid out.
        ///
        /// Subheadline is 11, which puts two points and a weight change between the two lines. Still
        /// a `Font.TextStyle` rather than a fixed size, so Dynamic Type keeps working.
        public static let rowSubtitle: Font = .system(.subheadline)

        /// Metadata: dates, counts, provenance.
        public static let metadata: Font = .system(.caption)

        /// A tag chip.
        public static let chip: Font = .system(.caption, design: .default, weight: .medium)

        /// A keyboard shortcut hint.
        public static let keyHint: Font = .system(.caption2, design: .rounded, weight: .medium)

        /// The floor: the smallest text the app is allowed to set, for the dense surfaces —
        /// calendar grids, month cells, hour rulers.
        ///
        /// `.caption2` is 10 points at the default size and still a `Font.TextStyle`, so it
        /// scales. The 7-, 8- and 9-point literals this replaces did not — text below ten points
        /// is not density, it is writing the interface off for anybody over forty, and a fixed
        /// size on top of that wrote it off for Dynamic Type too.
        public static let denseLabel: Font = .system(.caption2)

        /// The glyph over an empty state or an onboarding page.
        ///
        /// A text style rather than a fixed size, so the one image on the page grows with the
        /// user's text like everything under it. Light, because at this scale a regular stroke
        /// reads as a poster rather than an accent.
        public static let heroGlyph: Font = .system(.largeTitle, weight: .light)

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

        /// What is legible *on top of* ``selection`` — a filled button, a selected pill.
        ///
        /// Not white. White is right under a blue accent and poor under a yellow one, and this is
        /// the AppKit token that already knows which: it is the colour the system paints on its own
        /// prominent controls, and it tracks the accent, the appearance, and Increase Contrast.
        public static let onAccent = Color(nsColor: .alternateSelectedControlTextColor)

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
        /// A destructive action, and nothing else.
        ///
        /// Reserved for the moment something is about to be removed — a Move to Trash button, a
        /// Delete row. It shares a hue with ``overdue`` and ``recording``, but not a meaning, and
        /// the tokens stay separate so any of the three can be retuned without repainting the
        /// other two.
        public static let destructive = Color(nsColor: .systemRed)

        /// A timer that is running or paused — the live-recording signal.
        ///
        /// This used to be ``destructive`` at eight call sites, which made every running timer
        /// look like a deletion in progress. Red is still right — it is the platform's recording
        /// convention — but it is its own claim, made by its own token.
        public static let recording = Color(nsColor: .systemRed)

        /// A favourite's star and a flag.
        ///
        /// One token for the three surfaces that draw it, which previously split between
        /// ``dueToday`` and ``warning`` — the same orange from two different meanings, so a
        /// retune of either would have broken the pair.
        public static let favorite = Color(nsColor: .systemOrange)

        /// The umbra under a floating card or panel.
        ///
        /// The one place black is allowed to be black: a shadow is an absence of light in both
        /// appearances, and routing it through the palette would make it a colour. Callers apply
        /// their own opacity — the depth is the surface's decision, the hue is not.
        public static let shadow = Color.black

        /// The quiet accent fill behind a selected or current row, chip, or mode.
        ///
        /// One alpha, defined once. Before this token the same "this is where you are" fill was
        /// drawn at eight different opacities between 0.06 and 0.18, one per screen that needed
        /// it, which is how the selection read stronger in some lists than others for no reason
        /// anybody chose.
        public static var selectionFill: Color {
            adaptiveAlpha(of: selection, standard: 0.15, increasedContrast: 0.3)
        }

        /// A surface tinted by something's own colour — a chip's body, a callout, a selected pill.
        ///
        /// One alpha for every tinted fill in the app. The feature views had grown thirty
        /// distinct opacities between 0.025 and 0.8 for what was always the same two ideas: a
        /// wash of the thing's colour behind it, and a firmer line of the same colour around it.
        /// The hue adapts with the appearance because the *tint* does; only the strength is
        /// decided here — and it doubles under Increase Contrast, because a 12% wash is exactly
        /// the kind of distinction that setting exists to strengthen.
        public static func tintedFill(_ tint: Color) -> Color {
            adaptiveAlpha(of: tint, standard: 0.12, increasedContrast: 0.24)
        }

        /// The boundary that goes with ``tintedFill(_:)`` — strong enough to hold a chip's edge
        /// on the dark list background, where the fills alone were dissolving.
        public static func tintedStroke(_ tint: Color) -> Color {
            adaptiveAlpha(of: tint, standard: 0.25, increasedContrast: 0.55)
        }

        /// A translucent wash whose strength answers to Increase Contrast.
        ///
        /// The system's own semantic colours respond to the setting by themselves; the alphas this
        /// app lays over a tint do not, so before this every hand-tinted fill stayed a 12% wash
        /// for exactly the people who asked for more. A dynamic provider rather than an
        /// environment read, so a static token can stay a static token.
        ///
        /// Public for the few places — the calendar's event blocks — whose strengths are their
        /// own design decision but whose contrast behaviour must be this one.
        public static func adaptiveAlpha(
            of tint: Color,
            standard: CGFloat,
            increasedContrast: CGFloat
        ) -> Color {
            let base = NSColor(tint)
            return Color(nsColor: NSColor(name: nil) { appearance in
                let highContrastNames: [NSAppearance.Name] = [
                    .accessibilityHighContrastAqua,
                    .accessibilityHighContrastDarkAqua,
                    .accessibilityHighContrastVibrantLight,
                    .accessibilityHighContrastVibrantDark,
                ]
                let isHighContrast = highContrastNames.contains(appearance.name)
                return base.withAlphaComponent(isHighContrast ? increasedContrast : standard)
            })
        }

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

        /// The accent for the capture surfaces — Quick Jot and the person capture sheets.
        ///
        /// Named rather than spelled `Color.purple` at nine call sites. The literal adapts between
        /// light and dark, so this is not a bug being fixed; it is nine independent decisions
        /// becoming one, so that changing the colour of capture is an edit rather than a search.
        public static let captureAccent = Color(nsColor: .systemPurple)

        // There was a `familyAccent` here — pink, for a child's evolving details on a parent's
        // profile — and the argument for it was that those facts are deliberately local to this app
        // and the tint was part of how that read as its own thing.
        //
        // It is gone, and the argument was wrong twice. Pink and red in this palette mean
        // ``warning``, ``overdue`` and ``destructive``, so a profile whose only coloured elements
        // were the children read as several things having gone wrong; and "local to this app" is a
        // fact about *provenance*, which the lock glyph on the card already states in words anybody
        // can read, in the one condition where it is news. A hue cannot say "never written to your
        // address book" to somebody who has not been told what the hue means, and the people who
        // most need to know are the ones being told least.
        //
        // Nothing replaced it. A relationship card carries the person's own avatar tint and no other
        // colour — see `RelationshipCard`.

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
        ///
        /// The accent fallback suits the places where "uncolored" should still read as alive — a
        /// calendar with no recorded colour. For a glyph beside content, prefer
        /// ``color(named:neutral:)``: an accent fallback there makes an *unchosen* colour
        /// indistinguishable from a *selected* row.
        public static func color(named name: String?) -> Color {
            guard let name, let entry = Palette(rawValue: name) else { return Color.accentColor }
            return entry.color
        }

        /// Resolves a stored name, falling back to the neutral the caller sits in.
        ///
        /// This is the helper seven call sites had privately reimplemented — the same
        /// guard-let-else-grey, once per file — because the accent-fallback variant above was the
        /// only one offered.
        public static func color(named name: String?, neutral: Color) -> Color {
            guard let name, let entry = Palette(rawValue: name) else { return neutral }
            return entry.color
        }

        /// The palette entry as AppKit sees it, for the note editor's drawing.
        ///
        /// Defined here beside ``color`` — and nowhere else — so the two resolutions cannot
        /// drift apart, and so the hygiene scan keeps treating any other file that spells out
        /// colour names as a second palette.
        public var nsColor: NSColor {
            switch self {
            case .red: .systemRed
            case .orange: .systemOrange
            case .yellow: .systemYellow
            case .green: .systemGreen
            case .mint: .systemMint
            case .teal: .systemTeal
            case .cyan: .systemCyan
            case .blue: .systemBlue
            case .indigo: .systemIndigo
            case .purple: .systemPurple
            case .pink: .systemPink
            case .brown: .systemBrown
            case .graphite: .systemGray
            }
        }

        /// Resolves a stored name for an AppKit caller, falling back to the neutral it sits in —
        /// the counterpart of ``color(named:neutral:)``, for the same reason it exists.
        public static func nsColor(named name: String?, neutral: NSColor) -> NSColor {
            guard let name, let entry = Palette(rawValue: name) else { return neutral }
            return entry.nsColor
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
