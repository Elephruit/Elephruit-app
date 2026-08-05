import ElephruitDesign
import SwiftUI

/// A day drawn as one continuous thread rather than as a stack of cards.
///
/// ### Why a rail and not sections
/// A day *is* one thing. Grouping it into inset cards — meetings here, work there, people below —
/// makes the reader assemble the day themselves from four separate reports, and the seams fall in
/// exactly the places where the interesting joins are: the gap between two meetings, the task that
/// belongs to the one at eleven. A single line down the page says the opposite, that this is one
/// sequence you are moving through, and it lets a gap be drawn as *a gap in the line* rather than as
/// a row that happens to say "free".
///
/// ### The three columns, and what each is for
/// Every row has the same skeleton, and the skeleton is the whole reason the page reads as one
/// thing:
///
/// - **Leading** — *when, or who.* A time, a completion circle, a face. Never a title.
/// - **The rail** — *what kind of thing this is,* as one badge sitting on the line.
/// - **Content** — everything else.
///
/// A row that breaks the skeleton breaks the page, which is why the geometry is here as constants
/// and not as numbers typed into each row.
enum Timeline {
    /// The column that holds a time or a face. Trailing-aligned, so times form a straight edge
    /// against the rail however wide they are.
    ///
    /// ### Why every user of this scales it
    /// 64 points is what "10:00 AM" needs in monospaced caption digits at the standard text size,
    /// and the number is not a guess: 56 was tried, it fit "9:30 AM", and it split every
    /// double-digit hour onto two lines — which the first live screenshot of this page caught. So
    /// the column is a *seed* for a `@ScaledMetric` in each view that draws it, never a fixed width,
    /// or the same wrap comes back the moment somebody raises their text size.
    static let leadingWidth: CGFloat = 64

    /// The rail's own column. The line runs down its centre and badges are centred on the line.
    static let railWidth: CGFloat = 40

    /// The margin before the leading column starts.
    ///
    /// Without it a nine-thirty sits three points off the edge of the screen. The first screenshot
    /// of the rail had every time in the day pressed against the bezel, which reads as text that
    /// escaped rather than a column that was placed.
    static let leadingInset: CGFloat = Theme.Spacing.large

    static let badgeSize: CGFloat = 26
    static let lineWidth: CGFloat = 1

    /// How far down a row the badge's centre sits — the top padding plus half the badge.
    ///
    /// Named because the closing row's rail has to stop *exactly* there. A line that stops short
    /// leaves the last badge hanging off the end of the thread; one that overshoots pokes out below
    /// it. Either reads as a rendering fault rather than as an ending.
    static let badgeCentreY: CGFloat = Theme.Spacing.small + badgeSize / 2

    /// How the line is drawn through a row.
    enum RailStyle {
        /// Committed time, or simply the thread continuing.
        case solid
        /// Time with nothing in it. The line goes dashed, so free time is legible as a gap in the
        /// day at a glance rather than as another row to read.
        case dashed
        /// The last entry: the line runs in from above and stops at the badge.
        ///
        /// A thread that runs on past its final row promises something below it that is not there,
        /// and the reader scrolls to find out. Stopping on the badge is what makes the end look
        /// decided rather than cut off.
        case tail
        /// No line at all — for a row that is not part of the day, like a failure.
        case none
    }

    /// What sits on the line: a symbol in a filled circle, ringed in the page's own colour so the
    /// line appears to pass behind it rather than through it.
    struct Badge: View {
        let symbolName: String
        var tint: Color = Theme.Colors.secondaryText
        /// A hollow badge for something that is not an entry — the marker for now, an empty slot.
        var isHollow: Bool = false

        var body: some View {
            ZStack {
                Circle()
                    .fill(Theme.Colors.contentBackground)
                    .frame(width: Timeline.badgeSize + Theme.Spacing.tight)

                if isHollow {
                    Circle()
                        .strokeBorder(tint, lineWidth: Timeline.lineWidth * 2)
                        .frame(width: Timeline.badgeSize)
                } else {
                    Circle()
                        .fill(tint)
                        .frame(width: Timeline.badgeSize)
                    Image(systemName: symbolName)
                        .font(Theme.Text.denseLabel)
                        .foregroundStyle(Theme.Colors.onAccent)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// One entry on the thread.
///
/// The rail is drawn to the row's full height and the padding lives on the columns beside it, so
/// consecutive rows join into an unbroken line with nothing to align by hand.
struct TimelineRow<Leading: View, Content: View>: View {
    var railStyle: Timeline.RailStyle = .solid
    var badge: Timeline.Badge?
    /// Whether a hairline closes the row off. The last row of the day does not need one.
    var showsDivider: Bool = true
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var content: () -> Content

    /// Widens with the text it holds rather than wrapping a time mid-digit. See
    /// ``Timeline/leadingWidth`` for why this is scaled everywhere and fixed nowhere.
    @ScaledMetric(relativeTo: .caption) private var leadingWidth: CGFloat = Timeline.leadingWidth

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            leading()
                .frame(width: leadingWidth, alignment: .trailing)
                .padding(.leading, Timeline.leadingInset)
                .padding(.top, Theme.Spacing.medium)

            ZStack(alignment: .top) {
                rail
                if let badge {
                    badge.padding(.top, Theme.Spacing.small)
                }
            }
            .frame(width: Timeline.railWidth)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Theme.Spacing.medium)
                .padding(.bottom, Theme.Spacing.medium)
                .padding(.trailing, Theme.Spacing.large)
                .overlay(alignment: .bottom) {
                    if showsDivider {
                        Rectangle()
                            .fill(Theme.Colors.separator)
                            .frame(height: Timeline.lineWidth)
                    }
                }
        }
        .background(Theme.Colors.contentBackground)
    }

    @ViewBuilder
    private var rail: some View {
        switch railStyle {
        case .none:
            Color.clear.frame(width: Timeline.lineWidth)
        case .solid:
            TimelineLine()
                .stroke(
                    Theme.Colors.separator,
                    style: StrokeStyle(lineWidth: Timeline.lineWidth)
                )
                .frame(maxHeight: .infinity)
        case .dashed:
            TimelineLine()
                .stroke(
                    Theme.Colors.separator,
                    style: StrokeStyle(lineWidth: Timeline.lineWidth, dash: [3, 4])
                )
                .frame(maxHeight: .infinity)
        case .tail:
            TimelineLine(stoppingAt: Timeline.badgeCentreY)
                .stroke(
                    Theme.Colors.separator,
                    style: StrokeStyle(lineWidth: Timeline.lineWidth)
                )
                .frame(maxHeight: .infinity)
        }
    }
}

/// The rail itself: a line down the middle of whatever it is given.
///
/// A `Shape` rather than a filled `Rectangle` because the dashed variant needs a stroke, and
/// `strokeBorder` on a one-point-wide rectangle insets itself out of existence. Drawing both
/// variants from the same path is also what guarantees the solid and dashed rails sit on exactly
/// the same axis — a half-point of drift between them would read as a kink in the thread.
private struct TimelineLine: Shape {
    /// How far down to draw. `nil` runs the whole height.
    var stoppingAt: CGFloat?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: stoppingAt.map { rect.minY + $0 } ?? rect.maxY))
        return path
    }
}

/// A row with nothing to say in the leading column — an all-day entry, a note.
///
/// ### Why the placeholder is `Color.clear` and not `EmptyView`
/// `EmptyView` renders nothing *and takes no part in layout*, so a `.frame(width:)` on it is
/// discarded and the leading column silently collapses. The first screenshot of this page caught it
/// exactly: the awareness rows sat fifty points left of their own header, with two rails down the
/// page instead of one. `Color.clear` is a real view that honours a frame, which is the whole
/// difference between an empty column and no column.
extension TimelineRow where Leading == Color {
    init(
        railStyle: Timeline.RailStyle = .solid,
        badge: Timeline.Badge? = nil,
        showsDivider: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            railStyle: railStyle,
            badge: badge,
            showsDivider: showsDivider,
            leading: { Color.clear },
            content: content
        )
    }
}

/// A named turn in the day — "Awareness", "To do" — with the thread running on behind it.
///
/// Deliberately small and deliberately not a card header. It is a label on a continuous thing, not
/// the lid of a box, and the moment it looks like a lid the page is four reports again.
struct TimelineHeader<Trailing: View>: View {
    let title: String
    /// Named on the *title text*, never on the row. A container that owns an identifier hides its
    /// children, and the row is exactly where a control would be hiding.
    var identifier: String?
    @ViewBuilder var trailing: () -> Trailing

    /// The same scaled column as the rows, so a header's rail sits on the rows' rail at every text
    /// size. A fixed width here and a scaled one there is a thread with a kink in it.
    @ScaledMetric(relativeTo: .caption) private var leadingWidth: CGFloat = Timeline.leadingWidth

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Color.clear
                .frame(width: leadingWidth)
                .padding(.leading, Timeline.leadingInset)

            TimelineLine()
                .stroke(Theme.Colors.separator, style: StrokeStyle(lineWidth: Timeline.lineWidth))
                .frame(width: Timeline.railWidth)

            HStack {
                Text(title)
                    .font(Theme.Text.sectionHeader)
                    .kerning(Theme.Text.Tracking.caps)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .accessibilityIdentifier(identifier ?? "")
                Spacer()
                trailing()
            }
            .padding(.top, Theme.Spacing.large)
            .padding(.bottom, Theme.Spacing.small)
            .padding(.trailing, Theme.Spacing.large)
        }
        .background(Theme.Colors.contentBackground)
    }
}

extension TimelineHeader where Trailing == EmptyView {
    init(_ title: String, identifier: String? = nil) {
        self.init(title: title, identifier: identifier, trailing: { EmptyView() })
    }
}

extension View {
    /// Strips a `List` row back to nothing, so the timeline draws every pixel of it.
    ///
    /// The rows stay in a `List` rather than a `LazyVStack` because swipe actions, pull to refresh
    /// and row recycling all come from it and none of them are worth reimplementing. What is not
    /// worth keeping is its decoration: the insets, the separators and the row background all fight
    /// a continuous rail, and each one has to be turned off explicitly.
    func onTimeline() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
