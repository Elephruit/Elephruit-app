import ElephruitCore
import ElephruitDesign
import ElephruitFeatures
import Foundation
import Testing

/// **Criteria A1-4 and A1-5** — the sidebar's truncation policy, and the rule that a destination the
/// build cannot reach is never shown anywhere.
///
/// What is asserted here is the *policy*: which rows may be cut, which may not, and which exist at
/// all. The rendering half — `.truncationMode(.tail)` and the tooltip on a derived row — is a view
/// modifier, verified by reading rather than by test, and that limit is stated rather than papered
/// over.
@MainActor
@Suite("Sidebar registry")
struct SidebarRegistryTests {
    @Test("No primary navigation row may be truncated")
    func destinationsNeverTruncate() {
        // An ambiguous "Proj…" costs more than a wider sidebar does. Every declared destination opts
        // out of truncation, which is what makes the derived minimum width meaningful — the sidebar
        // grows to fit them rather than cutting them to fit it.
        for destination in SidebarRegistry.allDeclared {
            #expect(
                destination.mayTruncate == false,
                "\(destination.title) would be allowed to truncate"
            )
        }
    }

    @Test("The derived minimum accounts for every visible destination")
    func minimumWidthCoversEveryTitle() {
        let titles = SidebarRegistry.nonTruncatingTitles
        let available = SidebarRegistry.available.map(\.title)

        #expect(Set(titles) == Set(available), "A destination missing here could be cut off")
        #expect(SidebarMetrics.minimumWidth(fittingTitles: titles) >= SidebarMetrics.floorWidth)
    }

    @Test("Unavailable destinations are enumerated nowhere")
    func unavailableDestinationsAreInvisible() {
        // A roadmap should not leak into the interface as a row that leads nowhere — not in the
        // sidebar, not in a customisation screen, not in a menu.
        let declared = Set(SidebarRegistry.allDeclared.map(\.id))
        let available = Set(SidebarRegistry.available.map(\.id))

        #expect(declared.count > available.count, "Some destinations are declared for later phases")

        for destination in SidebarRegistry.allDeclared where !destination.isAvailable {
            #expect(!available.contains(destination.id), "\(destination.title) should be invisible")

            for band in SidebarDestination.Band.allCases {
                #expect(!SidebarRegistry.destinations(in: band).contains { $0.id == destination.id })
            }
        }
    }

    @Test("Calendar is declared but not yet shown")
    func laterDestinationsAreDeclared() {
        // Declared now so the phase that builds it flips a flag rather than editing the sidebar.
        // Events already appear in Today and Upcoming; a dedicated calendar grid is what is missing.
        let calendar = SidebarRegistry.allDeclared.first { $0.id == "calendar" }
        #expect(calendar != nil)
        #expect(calendar?.isAvailable == false)
    }

    @Test("Home became available in Phase E, first in the primary band")
    func homeIsAvailable() {
        let home = SidebarRegistry.allDeclared.first { $0.id == "home" }
        #expect(home?.isAvailable == true)
        #expect(home?.band == .primary)

        // First, because it answers the question you have on opening the app rather than one you go
        // looking for.
        #expect(SidebarRegistry.destinations(in: .primary).first?.id == "home")
    }

    @Test("Time became available in Phase C, in the Library band")
    func timeIsAvailable() {
        let time = SidebarRegistry.allDeclared.first { $0.id == "time" }
        #expect(time?.isAvailable == true)

        // The Library band, not the top one, by decision: the top band is for what you are doing
        // now, and time is something you look back at.
        #expect(time?.band == .library)
        #expect(SidebarRegistry.available.contains { $0.id == "time" })
    }

    @Test("Only Today and Inbox carry a count")
    func onlyTwoRowsShowCounts() {
        // A count is a prompt to act. A count of every note ever written is decoration.
        let counted = SidebarRegistry.available.filter(\.showsCount).map(\.id)
        #expect(Set(counted) == ["today", "inbox"])
    }

    @Test("Numeric shortcuts follow the order rows are shown in")
    func shortcutsMatchVisibleOrder() {
        // ⌘1 must select whatever is first, or the shortcut and the eye disagree.
        let ordered = SidebarRegistry.destinations(in: .primary)
            + SidebarRegistry.destinations(in: .library)

        for (index, destination) in ordered.enumerated() {
            #expect(SidebarRegistry.destination(forShortcutIndex: index + 1)?.id == destination.id)
        }

        #expect(SidebarRegistry.destination(forShortcutIndex: 0) == nil)
        #expect(SidebarRegistry.destination(forShortcutIndex: ordered.count + 1) == nil)
    }

    /// The tooltip content, which is the half of "hover, then explain" that can be checked.
    ///
    /// The hover fill and the delay before the tooltip appears are a view modifier and a system
    /// setting respectively, and neither is assertable here. What *is* assertable is that every row
    /// has something worth waiting for — a hint that says what the destination holds rather than
    /// spelling its own name back.
    @Test("Every destination explains what it holds, in words its label does not already use")
    func everyDestinationHasAHint() {
        for destination in SidebarRegistry.allDeclared {
            #expect(!destination.hint.isEmpty, "\(destination.title) has no tooltip")

            #expect(
                destination.hint.caseInsensitiveCompare(destination.title) != .orderedSame,
                "\(destination.title)'s tooltip repeats the label, which is a delay followed by nothing"
            )

            #expect(
                destination.hint.count > destination.title.count,
                "\(destination.title)'s tooltip should describe the rule, not restate the row"
            )
        }
    }

    @Test("Every People scope explains the rule that decides who appears in it")
    func everyPeopleScopeHasAHint() {
        let scopes: [PeopleScope] = [
            .all, .recentlyViewed, .favorites, .celebrations, .needsFollowUp,
            .group(id: UUID()), .duplicates, .fromContacts,
        ]

        for scope in scopes {
            #expect(!scope.hint.isEmpty, "\(scope.title) has no tooltip")
            #expect(
                scope.hint.caseInsensitiveCompare(scope.title) != .orderedSame,
                "\(scope.title)'s tooltip repeats the label"
            )
        }
    }

    @Test("A derived row keeps its full title, so a truncated one still has a tooltip")
    func derivedRowsCarryTheirFullTitle() {
        // The row may be cut in the view; the value it was built from is not, which is what the
        // tooltip and the accessibility label read.
        let long = "A pinned project with a name far too long for a 180 point sidebar"
        let row = SidebarDerivedRow(
            id: "pin.test",
            selection: .today,
            title: long,
            symbolName: "square.stack.3d.up"
        )

        #expect(row.title == long)
    }
}
