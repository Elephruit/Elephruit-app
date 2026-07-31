import SwiftUI

/// Lays subviews out left to right, wrapping when the next one will not fit.
///
/// ### Why this exists rather than an `HStack`
/// An `HStack` given more than fits does not wrap — it compresses, and then truncates. That is the
/// right answer for a list row, where a fixed height is what makes a long list scannable, and the
/// wrong answer everywhere the content is a *set* rather than a summary: a row of tags, a row of
/// grammar hints, a row of actions. In those places the number of items is the user's, not the
/// designer's, and squeezing them until they are unreadable hides the very thing that was added.
///
/// ### Why not `.fixedSize()` plus a `ScrollView`
/// A horizontal scroller inside a vertically scrolling panel is two directions of scrolling in one
/// place, and the second one is invisible until somebody finds it. Wrapping costs a line of height
/// and hides nothing.
///
/// Sizes are asked for once per subview per pass and cached in the layout cache, so the cost is
/// linear in the number of subviews rather than in the number of lines they end up on.
public struct FlowLayout: Layout {
    public struct Cache {
        var sizes: [CGSize] = []
    }

    /// Between items on the same line.
    private let spacing: CGFloat
    /// Between lines.
    private let lineSpacing: CGFloat
    /// How each line sits within the width it was given.
    private let alignment: HorizontalAlignment

    public init(
        spacing: CGFloat = Theme.Spacing.small,
        lineSpacing: CGFloat = Theme.Spacing.small,
        alignment: HorizontalAlignment = .leading
    ) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.alignment = alignment
    }

    public func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    public func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    }

    public func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        // An unspecified width means "how wide would you like to be", and the honest answer for a
        // wrapping layout is one line: it is the caller who decides where to break it.
        let width = proposal.width ?? .infinity
        let lines = lines(within: width, sizes: cache.sizes)

        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, lines.count - 1))
        let widest = lines.map(\.width).max() ?? 0
        return CGSize(width: min(widest, width), height: height)
    }

    public func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let lines = lines(within: bounds.width, sizes: cache.sizes)
        var y = bounds.minY

        for line in lines {
            var x = bounds.minX + leadingInset(for: line.width, in: bounds.width)

            for index in line.indices {
                let size = cache.sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }

            y += line.height + lineSpacing
        }
    }

    // MARK: - Breaking

    /// One line's worth of subviews and the box they occupy.
    public struct Line: Sendable, Hashable {
        public var indices: [Int] = []
        public var width: CGFloat = 0
        public var height: CGFloat = 0
    }

    private func lines(within width: CGFloat, sizes: [CGSize]) -> [Line] {
        Self.lines(of: sizes, within: width, spacing: spacing)
    }

    /// Where the breaks fall.
    ///
    /// Static and pure so it can be asserted directly. Everything that can be wrong about a wrapping
    /// layout — an item lost at a boundary, a line one item too long because the spacing was
    /// forgotten, an infinite loop on something wider than the container — is wrong here and nowhere
    /// else, and none of it is visible in a screenshot until the window is a particular width.
    public static func lines(of sizes: [CGSize], within width: CGFloat, spacing: CGFloat) -> [Line] {
        var lines: [Line] = []
        var current = Line()

        for (index, size) in sizes.enumerated() {
            let candidate = current.indices.isEmpty ? size.width : current.width + spacing + size.width

            // An item wider than the whole line still goes on a line of its own rather than being
            // dropped; it will be truncated by its own view, which is the only place that knows how.
            if !current.indices.isEmpty, candidate > width {
                lines.append(current)
                current = Line()
            }

            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }

        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }

    private func leadingInset(for lineWidth: CGFloat, in available: CGFloat) -> CGFloat {
        switch alignment {
        case .center: max(0, (available - lineWidth) / 2)
        case .trailing: max(0, available - lineWidth)
        default: 0
        }
    }
}
