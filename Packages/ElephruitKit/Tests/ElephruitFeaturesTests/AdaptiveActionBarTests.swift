import CoreGraphics
import ElephruitDesign
import Testing

/// What a row of actions gives up, and in what order, as the pane narrows.
///
/// `ViewThatFits` makes the real decision on screen, measuring real buttons at the user's real text
/// size, which is right and is also unassertable. ``ActionBarFit`` is the same rule expressed
/// arithmetically so the guarantees can be checked: the row never exceeds its width, the most
/// important action is the last to lose its word, and nothing leaves the row without landing in the
/// menu.
@Suite("Adaptive action bar")
struct AdaptiveActionBarTests {
    private let labelled: CGFloat = 92
    private let icon: CGFloat = 36
    private let overflow: CGFloat = 36
    private let spacing: CGFloat = 8

    private func fit(_ count: Int, in width: CGFloat) -> (labelled: Int, iconOnly: Int, overflow: Int) {
        ActionBarFit.arrangement(
            actionCount: count,
            labelledWidth: labelled,
            iconWidth: icon,
            overflowWidth: overflow,
            spacing: spacing,
            available: width
        )
    }

    /// The one guarantee that has to hold at every width, including the ones nobody thought to try.
    @Test("The row never exceeds the width it was given")
    func nothingEverClips() {
        for count in 1...12 {
            for width in stride(from: 40 as CGFloat, through: 1400, by: 13) {
                let arrangement = fit(count, in: width)
                let visible = arrangement.labelled + arrangement.iconOnly
                let hasMenu = arrangement.overflow > 0
                let items = visible + (hasMenu ? 1 : 0)

                guard items > 1 else { continue }

                let used = CGFloat(arrangement.labelled) * labelled
                    + CGFloat(arrangement.iconOnly) * icon
                    + (hasMenu ? overflow : 0)
                    + spacing * CGFloat(items - 1)

                // The all-in-the-menu arrangement is the floor; below that width there is nothing
                // left to give up, and a single menu button is the honest answer.
                guard visible > 0 else { continue }
                #expect(used <= width, "\(count) actions at \(width): \(arrangement)")
            }
        }
    }

    @Test("Nothing is dropped without landing in the menu")
    func everythingIsReachable() {
        for count in 1...12 {
            for width in stride(from: 40 as CGFloat, through: 1400, by: 29) {
                let arrangement = fit(count, in: width)
                #expect(
                    arrangement.labelled + arrangement.iconOnly + arrangement.overflow == count,
                    "\(count) actions at \(width) lost one"
                )
            }
        }
    }

    @Test("A wide pane labels everything and shows no menu")
    func wideShowsEverything() {
        let arrangement = fit(6, in: 1000)

        #expect(arrangement.labelled == 6)
        #expect(arrangement.overflow == 0)
        #expect(arrangement.iconOnly == 0)
    }

    /// Narrowing must shed the least important action first, never the most important.
    @Test("Labels are given up from the end of the row inwards")
    func labelsAreShedFromTheEnd() {
        var previous = Int.max

        for width in stride(from: 900 as CGFloat, through: 200, by: -20) {
            let arrangement = fit(8, in: width)
            #expect(arrangement.labelled <= previous, "the row grew as the pane shrank, at \(width)")
            previous = arrangement.labelled
        }
    }

    /// Icons are the last resort, not the first: solving the narrow case by making the wide case
    /// worse is the failure this whole component exists to avoid.
    @Test("Icons appear only when two labelled buttons will not fit")
    func iconsAreALastResort() {
        // Two labels, a menu and their gaps: 92 + 92 + 36 + 16 = 236.
        #expect(fit(8, in: 236).iconOnly == 0)
        #expect(fit(8, in: 236).labelled == 2)

        #expect(fit(8, in: 150).iconOnly > 0)
    }

    @Test("A pane too narrow for anything still offers the menu rather than clipping")
    func everythingCanEndUpInTheMenu() {
        let arrangement = fit(8, in: 30)

        #expect(arrangement.labelled == 0)
        #expect(arrangement.iconOnly == 0)
        #expect(arrangement.overflow == 8)
    }

    @Test("A single action needs no menu once it fits")
    func oneAction() {
        #expect(fit(1, in: 400) == (1, 0, 0))
    }

    @Test("No actions is not a crash")
    func noActions() {
        #expect(fit(0, in: 400) == (0, 0, 0))
    }

    /// The menu's own width has to be part of the sum, or the arrangement that *just* fits without
    /// it overflows the moment it appears.
    @Test("The menu button counts towards the width")
    func menuIsMeasured() {
        // Exactly three labelled buttons and their gaps: 92 * 3 + 8 * 2 = 292.
        #expect(fit(3, in: 292).labelled == 3, "three actions and no menu fit exactly")
        #expect(fit(4, in: 292).labelled < 3, "a fourth needs a menu, and the menu needs room")
    }

    // MARK: - Ranking

    @Test("Ranking puts the essential first and is stable within a band")
    func ranking() {
        let items = [
            ActionItem(id: "c", title: "C", symbolName: "c.circle", priority: .occasional) {},
            ActionItem(id: "a", title: "A", symbolName: "a.circle", priority: .essential) {},
            ActionItem(id: "d", title: "D", symbolName: "d.circle", priority: .common) {},
            ActionItem(id: "b", title: "B", symbolName: "b.circle", priority: .essential) {},
        ]

        #expect(items.rankedForDisplay().map(\.id) == ["a", "b", "d", "c"])
    }

    @Test("An action with a reason it cannot run is disabled whatever it was told")
    func reasonWins() {
        let item = ActionItem(
            id: "call",
            title: "Call",
            symbolName: "phone",
            isEnabled: true,
            unavailabilityReason: "No number recorded"
        ) {}

        #expect(!item.isEnabled)
    }

    /// A tooltip that spells the label back is a delay followed by nothing.
    @Test("A tooltip only carries what the label could not say")
    func tooltipsAddSomething() {
        let plain = ActionItem(id: "note", title: "Add Note", symbolName: "square.and.pencil") {}
        #expect(plain.tooltip == nil)

        let explained = ActionItem(
            id: "call",
            title: "Call",
            symbolName: "phone",
            unavailabilityReason: "No number recorded",
            shortcut: "⌘⇧C"
        ) {}
        #expect(explained.tooltip == "No number recorded · ⌘⇧C")
    }
}
