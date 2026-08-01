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

    @Test("The derived minimum accounts for every visible destination and every module")
    func minimumWidthCoversEveryTitle() {
        let titles = Set(SidebarRegistry.nonTruncatingTitles)
        let available = Set(SidebarRegistry.available.map(\.title))
        let modules = Set(AppModule.displayOrder.map(\.title))

        #expect(available.isSubset(of: titles), "A destination missing here could be cut off")
        // The module list is primary navigation now, so "Bookm…" would be exactly the ambiguity the
        // rule exists to prevent.
        #expect(modules.isSubset(of: titles), "A module name missing here could be cut off")
        #expect(SidebarMetrics.minimumWidth(fittingTitles: Array(titles)) >= SidebarMetrics.floorWidth)
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

    @Test("Calendar is the Calendar module's own front door, not a top-level row")
    func calendarIsAvailable() {
        // Declared with `isAvailable: false` from milestone 1 precisely so that the phase which
        // built it would flip one flag rather than edit the sidebar. This is that flag.
        let calendar = SidebarRegistry.allDeclared.first { $0.id == "calendar" }
        #expect(calendar?.isAvailable == true)

        // It was in the primary band while the sidebar showed everything at once. It is inside its
        // module now, which is the whole point: the top level names the module, and the module's
        // own sidebar names its destinations.
        #expect(calendar?.band == .module)
        #expect(calendar?.module == .calendar)
        #expect(!SidebarRegistry.destinations(in: .primary).contains { $0.id == "calendar" })
        #expect(SidebarRegistry.destinations(in: .calendar).contains { $0.id == "calendar" })
    }

    @Test("A module that navigates does not draw a row naming itself")
    func modulesWithNavigationDrawNoFrontDoorRow() {
        // The module header already reads `‹ 􀉉 Calendar ⌄`. A row called *Calendar* directly under
        // it was the front door of a module you were already standing in, drawn as somewhere to go —
        // and in Calendar's case it was the column's only selectable row, so the sidebar's one piece
        // of selection state was spent restating its own header.
        #expect(SidebarRegistry.sidebarRows(in: .calendar).isEmpty)
        #expect(SidebarRegistry.sidebarRows(in: .time).isEmpty)

        // Still declared, because `⌘6` has to reach Calendar whether or not Calendar spends a row
        // saying so — and a scene restored to `.calendar` still has to resolve.
        #expect(SidebarRegistry.destinations(in: .calendar).count == 1)
        #expect(SidebarRegistry.shortcutOrder.contains { $0.selection == .calendar })
        #expect(SidebarRegistry.shortcutOrder.contains { $0.selection == .time })
    }

    @Test("A module with nothing else in its sidebar keeps its one row")
    func singleDestinationModulesKeepTheirRow() {
        // The rule is about duplication, not about austerity. Bookmarks genuinely is one list, and a
        // module whose sidebar is empty is worse than one whose sidebar is a row.
        for module in [AppModule.bookmarks, .archive, .trash] {
            #expect(
                SidebarRegistry.sidebarRows(in: module) == SidebarRegistry.destinations(in: module),
                "\(module.title) lost the only row it had"
            )
        }

        // And a front door with a name of its own is a destination among peers rather than a second
        // name for the module: *All Notes* sits beside *Ideas*, *Reference* and *Daily Notes*.
        #expect(SidebarRegistry.sidebarRows(in: .notes).count > 1)
    }

    @Test("Every module either navigates or draws its front door")
    func noModuleHasAnEmptySidebar() {
        // The failure this guards against is a module declared with `hasNavigationOfItsOwn` and no
        // navigation to show for it, which would be a header over an empty column.
        for module in AppModule.displayOrder {
            #expect(
                module.hasNavigationOfItsOwn || !SidebarRegistry.sidebarRows(in: module).isEmpty,
                "\(module.title) would draw an empty sidebar"
            )
        }
    }

    @Test("The primary band is exactly the four global destinations, in reading order")
    func primaryBandIsGlobalOnly() {
        // The whole redesign in one assertion. Anything else at the top level is a feature's
        // navigation leaking back out of its module, which is what made the old sidebar an index.
        let ids = SidebarRegistry.destinations(in: .primary).map(\.id)
        #expect(ids == ["home", "today", "upcoming", "inbox"])

        for destination in SidebarRegistry.destinations(in: .primary) {
            #expect(destination.module == nil, "\(destination.title) claims a module")
            #expect(GlobalDestination.contains(destination.selection))
        }
    }

    @Test("Every module-band destination names the module it belongs to")
    func moduleDestinationsCarryTheirModule() {
        for destination in SidebarRegistry.allDeclared where destination.band == .module {
            #expect(destination.module != nil, "\(destination.title) is in no module")
        }
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

    @Test("Time is inside its own module")
    func timeIsAvailable() {
        let time = SidebarRegistry.allDeclared.first { $0.id == "time" }
        #expect(time?.isAvailable == true)
        #expect(time?.band == .module)
        #expect(time?.module == .time)
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
        // ⌘1 must select whatever is first, or the shortcut and the eye disagree. Global
        // destinations first, then one per module in module order — the sidebar's own order.
        let ordered = SidebarRegistry.shortcutOrder

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
